import Foundation

/// A lifecycle transition suitable for a future toast/notification queue.
/// The monitor keeps raw relation IDs internal; this value contains only the
/// privacy-filtered display fields needed by a host.
public struct SessionActivityTransition: Equatable, Sendable, Identifiable {
    public let accountID: String
    public let side: AccountPosition
    public let sessionID: String?
    public let sessionTitle: String?
    public let turnID: String?
    public let agentLabel: String?
    public let taskName: String?
    public let status: SessionActivityStatus

    public var id: String {
        var fields = [
            accountID,
            side.rawValue,
            sessionID ?? "",
            agentLabel ?? "",
            taskName ?? "",
            status.rawValue,
        ]
        if let turnID { fields.append(turnID) }
        return fields.joined(separator: "|")
    }

    public init(
        accountID: String,
        side: AccountPosition,
        sessionID: String?,
        agentLabel: String?,
        taskName: String?,
        status: SessionActivityStatus,
        sessionTitle: String? = nil,
        turnID: String? = nil
    ) {
        self.accountID = accountID
        self.side = side
        self.sessionID = sessionID
        self.turnID = turnID
        self.sessionTitle = SessionActivityMetadataSanitizer.text(sessionTitle)
        self.agentLabel = agentLabel
        self.taskName = taskName
        self.status = status
    }
}

public typealias SessionActivityTransitionHandler = @MainActor @Sendable (SessionActivityTransition) -> Void

/// One shared account poll loop. It establishes a baseline first, then emits
/// only session/agent lifecycle changes; source/timestamp-only changes are
/// intentionally ignored.
public actor SessionActivityMonitor {
    public static let defaultPollInterval: TimeInterval = 2

    public private(set) var accounts: [AccountConfig]
    public private(set) var currentSnapshots: [String: SessionActivitySnapshot] = [:]
    public private(set) var isRunning = false

    private let sharedHomeResolver: SharedCodexHomeResolver
    private let provider: any SessionActivityProvider
    private let pollInterval: TimeInterval
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let now: @Sendable () -> Date
    private let onTransition: SessionActivityTransitionHandler

    private var configurationRevision = 0
    private var loopToken = 0
    /// Monotonically identifies every poll generation. Stop/restart advances
    /// it before cancelling the old task so no late result or callback can be
    /// accepted by a newer loop.
    private var pollGeneration = 0
    private var loopTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var pollTaskGeneration: Int?

    /// `currentSnapshots` is the latest provider state for presentation. The
    /// comparison snapshot is kept separately so an unavailable read cannot
    /// be interpreted as a confirmed session end.
    /// 계정별 이전 정상 결과와 수집 시작 시각을 함께 보관하는 알림 기준
    private struct Comparison {
        let snapshot: SessionActivitySnapshot
        let polledAt: Date
    }
    private var comparisonSnapshots: [String: Comparison] = [:]
    private var needsRecoveryBaseline: Set<String> = []

    public init(
        accounts: [AccountConfig],
        provider: any SessionActivityProvider,
        pollInterval: TimeInterval = SessionActivityMonitor.defaultPollInterval,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        now: @escaping @Sendable () -> Date = { Date() },
        onTransition: @escaping SessionActivityTransitionHandler = { _ in },
        sharedHomeResolver: SharedCodexHomeResolver = SharedCodexHomeResolver()
    ) {
        self.sharedHomeResolver = sharedHomeResolver
        self.accounts = Self.normalizedAccounts(accounts)
        self.provider = provider
        self.pollInterval = max(0, pollInterval)
        self.sleep = sleep
        self.onTransition = onTransition
        self.now = now
    }

    /// Starts the single shared loop. Repeated starts are idempotent.
    public func start() {
        guard loopTask == nil else { return }
        loopToken += 1
        let token = loopToken
        isRunning = true
        loopTask = Task { [weak self] in
            guard let self else { return }
            await self.runLoop(token: token)
        }
    }

    /// Cancels the loop and any in-flight poll. A subsequent start begins a
    /// fresh baseline rather than emitting transitions from stale snapshots.
    public func stop() {
        loopToken += 1
        loopTask?.cancel()
        loopTask = nil
        isRunning = false

        pollGeneration += 1
        pollTask?.cancel()
        currentSnapshots.removeAll()
        comparisonSnapshots.removeAll()
        needsRecoveryBaseline.removeAll()
    }

    /// Replaces configured homes while retaining baselines only for accounts
    /// whose standardized home is unchanged. In-flight old results are
    /// discarded by the configuration revision check.
    public func reconfigure(accounts newAccounts: [AccountConfig]) {
        configurationRevision += 1
        let oldByID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let normalized = Self.normalizedAccounts(newAccounts)
        let newByID = Dictionary(normalized.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var preservedSnapshots: [String: SessionActivitySnapshot] = [:]
        var preservedComparisons: [String: Comparison] = [:]
        for (id, snapshot) in currentSnapshots {
            guard let oldConfig = oldByID[id],
                  let newConfig = newByID[id],
                  oldConfig.home == newConfig.home else {
                continue
            }
            preservedSnapshots[id] = snapshot
        }

        for (id, snapshot) in comparisonSnapshots {
            guard let oldConfig = oldByID[id],
                  let newConfig = newByID[id],
                  oldConfig.home == newConfig.home else {
                continue
            }
            preservedComparisons[id] = snapshot
        }

        accounts = normalized
        currentSnapshots = preservedSnapshots
        comparisonSnapshots = preservedComparisons
        needsRecoveryBaseline = needsRecoveryBaseline.filter { preservedSnapshots[$0] != nil }
    }

    /// Performs one coalesced poll immediately. This is used by deterministic
    /// tests and by lifecycle hosts that want a wake/reconfiguration refresh.
    public func pollNow() async {
        let loopToken = self.loopToken
        await pollNow(forLoopToken: loopToken)
    }

    public func snapshot(for accountID: String) -> SessionActivitySnapshot? {
        currentSnapshots[accountID]
    }

    private func runLoop(token: Int) async {
        defer {
            if loopToken == token {
                loopTask = nil
                isRunning = false
            }
        }

        while !Task.isCancelled && loopToken == token {
            await pollNow(forLoopToken: token)
            guard !Task.isCancelled, loopToken == token else { break }
            await sleep(pollInterval)
        }
    }

    /// Awaits any older generation before creating a new one. This is
    /// deliberately a loop: stop/restart changes `pollGeneration` while the
    /// old non-cooperative provider is still running, so the new loop must
    /// retry after that task has actually completed.
    private func pollNow(forLoopToken requestedLoopToken: Int) async {
        while true {
            guard loopToken == requestedLoopToken else { return }

            if let existing = pollTask,
               let existingGeneration = pollTaskGeneration {
                await existing.value
                if pollTaskGeneration == existingGeneration {
                    pollTask = nil
                    pollTaskGeneration = nil
                }
                guard loopToken == requestedLoopToken else { return }
                if existingGeneration == pollGeneration {
                    return
                }
                continue
            }

            pollGeneration += 1
            let generation = pollGeneration
            let revision = configurationRevision
            let accountsSnapshot = accounts
            let task = Task { [weak self] in
                guard let self else { return }
                await self.performPoll(
                    accounts: accountsSnapshot,
                    revision: revision,
                    generation: generation
                )
            }
            pollTask = task
            pollTaskGeneration = generation
            await task.value
            if pollTaskGeneration == generation {
                pollTask = nil
                pollTaskGeneration = nil
            }
            return
        }
    }

    private func performPoll(
        accounts: [AccountConfig],
        revision: Int,
        generation: Int
    ) async {
        let provider = self.provider
        let resolver = sharedHomeResolver
        let polledAt = now()
        var results: [PollResult] = []
        await withTaskGroup(of: PollResult.self) { group in
            for account in accounts {
                guard account.isConfigured else { continue }
                group.addTask {
                    let snapshot = await SharedCodexSessionActivity.snapshot(
                        account: account, accounts: accounts, provider: provider, resolver: resolver)
                    return PollResult(account: account, snapshot: snapshot)
                }
            }

            for await result in group {
                results.append(result)
            }
        }

        guard isGenerationCurrent(generation, revision: revision) else { return }
        let order = Dictionary(
            uniqueKeysWithValues: accounts.enumerated().map { ($1.id, $0) }
        )
        for result in results.sorted(by: { lhs, rhs in
            order[lhs.account.id, default: Int.max]
                < order[rhs.account.id, default: Int.max]
        }) {
            guard isGenerationCurrent(generation, revision: revision) else { return }
            guard let current = self.accounts.first(where: { $0.id == result.account.id }),
                  current.home == result.account.home,
                  result.snapshot.accountID == current.id else { continue }
            await apply(
                result.snapshot,
                account: current,
                generation: generation,
                revision: revision,
                polledAt: polledAt
            )
        }
    }

    private func apply(
        _ snapshot: SessionActivitySnapshot,
        account: AccountConfig,
        generation: Int,
        revision: Int,
        polledAt: Date
    ) async {
        guard isGenerationCurrent(generation, revision: revision) else { return }
        currentSnapshots[account.id] = snapshot

        if snapshot.state == .unavailable {
            needsRecoveryBaseline.insert(account.id)
            return
        }

        let previous = comparisonSnapshots[account.id]
        let isRecovery = needsRecoveryBaseline.remove(account.id) != nil
        comparisonSnapshots[account.id] = Comparison(snapshot: snapshot, polledAt: polledAt)
        guard let previous, !isRecovery else { return }

        for transition in Self.transitions(
            from: previous.snapshot,
            to: snapshot,
            account: account,
            since: previous.polledAt
        ) {
            guard isGenerationCurrent(generation, revision: revision),
                  !Task.isCancelled else { return }
            await onTransition(transition)
        }
    }

    private func isGenerationCurrent(_ generation: Int, revision: Int) -> Bool {
        !Task.isCancelled
            && pollGeneration == generation
            && configurationRevision == revision
    }

    private static func transitions(
        from previous: SessionActivitySnapshot,
        to current: SessionActivitySnapshot,
        account: AccountConfig,
        since previousPollAt: Date
    ) -> [SessionActivityTransition] {
        var transitions: [SessionActivityTransition] = []

        let previousSessions = previous.state == .available ? previous.sessions : []
        let currentSessions = current.state == .available ? current.sessions : []
        let previousByID = Dictionary(
            previousSessions.map { ($0.threadID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let currentByID = Dictionary(
            currentSessions.map { ($0.threadID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for session in currentSessions {
            // 늦게 발견한 과거 완료·중단 기록을 신규 응답 알림으로 재생하지 않도록 제한
            let isTerminal = [.completed, .stopped, .error].contains(session.status)
            let isNewTerminalEvent = !isTerminal || session.turnID == nil
                || (session.turnEventAt.map { $0 > previousPollAt } ?? false)
            guard let old = previousByID[session.threadID] else {
                guard isNewTerminalEvent else { continue }
                transitions.append(
                    sessionTransition(
                        account: account,
                        sessionID: session.threadID,
                        sessionTitle: session.title,
                        status: session.status,
                        turnID: session.turnID
                    )
                )
                continue
            }

            if isNewTerminalEvent && (old.status != session.status || old.isActive != session.isActive || old.turnID != session.turnID) {
                transitions.append(
                    sessionTransition(
                        account: account,
                        sessionID: session.threadID,
                        sessionTitle: session.title,
                        status: session.status,
                        turnID: session.turnID
                    )
                )
            }

            transitions.append(contentsOf: agentTransitions(
                previous: old.agents,
                current: session.agents,
                account: account,
                sessionID: session.threadID,
                sessionTitle: session.title
            ))
        }

        for session in previousSessions where currentByID[session.threadID] == nil {
            transitions.append(
                sessionTransition(
                    account: account,
                    sessionID: session.threadID,
                    sessionTitle: session.title,
                    status: .unknown
                )
            )
        }

        return transitions
    }

    /// 세션 상태 변화와 검증된 제목을 알림 전달 모델로 변환
    private static func sessionTransition(
        account: AccountConfig,
        sessionID: String?,
        sessionTitle: String?,
        status: SessionActivityStatus,
        turnID: String? = nil
    ) -> SessionActivityTransition {
        SessionActivityTransition(
            accountID: account.id,
            side: account.position,
            sessionID: sessionID,
            agentLabel: nil,
            taskName: nil,
            status: status,
            sessionTitle: sessionTitle,
            turnID: turnID
        )
    }

    /// 에이전트 상태 변화에 부모 세션 제목을 결합한 알림 목록 구성
    private static func agentTransitions(
        previous: [SessionActivityAgent],
        current: [SessionActivityAgent],
        account: AccountConfig,
        sessionID: String?,
        sessionTitle: String?
    ) -> [SessionActivityTransition] {
        let previousByID = Dictionary(previous.map { ($0.threadID, $0) }, uniquingKeysWith: { first, _ in first })
        let currentByID = Dictionary(current.map { ($0.threadID, $0) }, uniquingKeysWith: { first, _ in first })
        var transitions: [SessionActivityTransition] = []

        for agent in current {
            guard let old = previousByID[agent.threadID],
                  old.status == agent.status,
                  old.displayName == agent.displayName,
                  old.taskName == agent.taskName else {
                transitions.append(
                    agentTransition(
                        account: account,
                        sessionID: sessionID,
                        sessionTitle: sessionTitle,
                        agentLabel: agent.displayName,
                        taskName: agent.taskName,
                        status: agent.status
                    )
                )
                continue
            }
        }

        for agent in previous where currentByID[agent.threadID] == nil {
            transitions.append(
                agentTransition(
                    account: account,
                    sessionID: sessionID,
                    sessionTitle: sessionTitle,
                    agentLabel: agent.displayName,
                    taskName: agent.taskName,
                    status: .unknown
                )
            )
        }
        return transitions
    }

    /// 원본 대화 없이 에이전트의 제목·작업·상태만 전달
    private static func agentTransition(
        account: AccountConfig,
        sessionID: String?,
        sessionTitle: String?,
        agentLabel: String,
        taskName: String,
        status: SessionActivityStatus
    ) -> SessionActivityTransition {
        SessionActivityTransition(
            accountID: account.id,
            side: account.position,
            sessionID: sessionID,
            agentLabel: agentLabel,
            taskName: taskName,
            status: status,
            sessionTitle: sessionTitle
        )
    }

    private static func normalizedAccounts(_ input: [AccountConfig]) -> [AccountConfig] {
        let stableIDs = ["C1", "C2", "C3", "C4"]
        let byID = Dictionary(input.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let stable = stableIDs.compactMap { byID[$0] }
        let knownIDs = Set(stableIDs)
        let extras = byID.values
            .filter { !knownIDs.contains($0.id) }
            .sorted { $0.id < $1.id }
        return stable + extras
    }

    private struct PollResult: Sendable {
        let account: AccountConfig
        let snapshot: SessionActivitySnapshot
    }
}
