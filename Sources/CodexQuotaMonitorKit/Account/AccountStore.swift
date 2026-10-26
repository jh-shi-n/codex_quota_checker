// 목적: 계정별 한도 상태 및 비동기 조회 세대 관리
// 이용처: 앱 한도 새로고침 및 초기화 시각 갱신
// 사용방법: refreshAll 또는 refresh(accountID:forceFresh:) 호출
import Combine
import Foundation

/// The asynchronous seam used by `AccountStore` to load one account snapshot.
/// Production callers use `CodexQuotaService.state(for:)`; tests can inject a
/// deterministic loader without touching authentication files or processes.
public typealias AccountStateLoader = @Sendable (AccountConfig) async throws -> AccountState

/// Main-actor observable state for the four independent Codex accounts.
///
/// Each account has an independent generation plus a configuration revision.
/// Results from an older account refresh or reconfiguration are ignored,
/// preventing a slow request from replacing newer UI state for that account or
/// its siblings.
@MainActor
public final class AccountStore: ObservableObject {
    /// 서버 조회 성공과 화면 반영 담당 여부의 분리
    public enum RefreshOutcome: Equatable, Sendable {
        case succeeded(applied: Bool)
        case failed
        case superseded
        case notConfigured

        public var isSuccess: Bool {
            if case .succeeded = self { return true }
            return false
        }
    }

    public static let stableAccountIDs = ["C1", "C2", "C3", "C4"]

    @Published public private(set) var configs: [AccountConfig]
    @Published public private(set) var states: [AccountState]

    /// 최신 정상 결과에서 감지한 조기 리셋 전달; 동일 결과 재조회 시 재통지 제외
    public var onEarlyQuotaReset: (@MainActor (EarlyQuotaReset) -> Void)?

    /// 일반 한도 조회 시작 시 공용 서비스 상태 갱신 요청; 계정별 결과 대기와 분리
    public var onQuotaRefreshStarted: (@MainActor () -> Void)?

    /// 계정 설정 변경에 따른 비동기 결과 격리용 버전
    public var configurationRevision: Int { configRevision }

    private let preferencesStore: PreferencesStore
    private let stateLoader: AccountStateLoader
    /// 관측 시계 주입용 내부 경계; 기본값은 현재 시각과 시스템 가동 시간
    var observationNow: @MainActor () -> Date = { Date() }
    var observationUptime: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var configRevision = 0
    private var accountGenerations: [String: Int] = [:]
    private var inFlightFetches: [FetchKey: FetchHandle] = [:]
    private var activeFetches: [UUID: FetchHandle] = [:]
    private var shuttingDown = false
    private var appliedRequestIDs: [String: UUID] = [:]
    private var latestRequestIDs: [String: UUID] = [:]
    private var resetHistories: [String: ResetHistory] = [:]
    /// 실제 실행 중 수집한 정상 응답만 초기화 감지 기준으로 사용
    private var resetBaselines: [String: AccountState] = [:]

    /// 동일 슬롯의 계정·구독 변경 시 관측 이력을 분리하는 식별 정보
    private struct ResetHistory {
        let email: String?
        let planType: String?
        var primary = ResetTimeTracker()
        var secondary = ResetTimeTracker()
        var lastUptime: TimeInterval?
        var lastObservedAt: Date?
    }

    public init(
        configs: [AccountConfig] = AccountConfig.defaultAccounts(),
        preferencesStore: PreferencesStore? = nil,
        stateLoader: @escaping AccountStateLoader = { config in
            await CodexQuotaService().state(for: config)
        }
    ) {
        let normalized = Self.normalizeConfigs(configs)
        let resolvedPreferencesStore = preferencesStore ?? PreferencesStore()
        self.configs = normalized
        self.preferencesStore = resolvedPreferencesStore
        self.states = normalized.map { config in
            Self.initialState(for: config, preferencesStore: resolvedPreferencesStore)
        }
        self.stateLoader = stateLoader
        resolvedPreferencesStore.onQuotaSnapshotsRestored = { [weak self, weak resolvedPreferencesStore] in
            guard let self, let resolvedPreferencesStore else { return }
            self.states = self.states.map { state in
                guard state.isWaitingForRefresh, !state.isRefreshing,
                      let config = self.configs.first(where: { $0.id == state.id }) else { return state }
                return Self.initialState(for: config, preferencesStore: resolvedPreferencesStore)
            }
        }
    }

    /// Compatibility alias for hosts that call the published snapshots
    /// account states.
    public var accountStates: [AccountState] { states }

    /// 큰 일정 변경 직후 이전 고정 근거 제거 및 재확인 상태 저장
    public func beginResetVerification(expected: AccountState) {
        guard let index = verificationIndex(expected) else { return }
        var state = states[index]
        state.isResetVerificationPending = true
        state.primaryResetObservation = .checking
        state.secondaryResetObservation = .checking
        state.primaryResetEvidence = nil
        state.secondaryResetEvidence = nil
        states[index] = state
        saveVerifiedSnapshot(state)
    }

    /// 취소·실패 후 진행 중 안내 해제; 이전 고정 근거의 부활 제외
    public func endResetVerification(expected: AccountState) {
        guard let index = verificationIndex(expected) else { return }
        states[index].isResetVerificationPending = false
    }

    /// 최대 3초 오차 유지 및 조회 경과에 비례한 이동의 고정 오인 차단
    public func finishResetVerification(expected: AccountState, comparedTo previous: AccountState) {
        guard let index = verificationIndex(expected), previous.acceptsIdentity(of: expected),
              let updated = expected.lastUpdated,
              previous.lastUpdated.map({ updated > $0 }) == true else { return }
        var state = states[index]
        let now = observationNow()
        for primary in [true, false] {
            let reset = primary ? state.primaryResetAt : state.secondaryResetAt
            let old = primary ? previous.primaryResetAt : previous.secondaryResetAt
            let priorEvidence = primary ? previous.primaryResetEvidence : previous.secondaryResetEvidence
            let valid = reset.map { $0.timeIntervalSince1970.isFinite && $0 > now } == true
            let delta = reset.flatMap { value in old.map { value.timeIntervalSince($0) } }
            let elapsed = updated.timeIntervalSince(previous.lastUpdated!)
            let followsClock = delta.map { $0 > 0 && abs($0 - elapsed) <= 1 } ?? false
            let trusted = priorEvidence?.matches(reset, now: now) == true
            let stable = valid && delta.map({ abs($0) <= ResetTimeTracker.resetTolerance }) == true
                && (trusted || !followsClock)
            let observation: ResetTimeObservation = stable ? .stableObserved : (valid && old != nil ? .movingObserved : .checking)
            let evidence = stable ? ResetTimeEvidence(resetAt: reset!, observedAt: updated) : nil
            if primary { state.primaryResetObservation = observation; state.primaryResetEvidence = evidence }
            else { state.secondaryResetObservation = observation; state.secondaryResetEvidence = evidence }
        }
        state.isResetVerificationPending = false
        states[index] = state
        recordObservation(state, previous: previous)
        saveVerifiedSnapshot(state)
    }

    /// 대기 중 새 요청·계정 변경으로 교체된 스냅샷의 덮어쓰기 차단
    private func verificationIndex(_ expected: AccountState) -> Int? {
        states.firstIndex { $0.status == .normal && $0.id == expected.id && $0.acceptsIdentity(of: expected)
            && $0.lastUpdated == expected.lastUpdated && $0.primaryResetAt == expected.primaryResetAt
            && $0.secondaryResetAt == expected.secondaryResetAt }
    }

    /// 검증 결과와 계정 식별 정보를 같은 경로 캐시에 저장
    private func saveVerifiedSnapshot(_ state: AccountState) {
        guard let config = configs.first(where: { $0.id == state.id }), state.status == .normal else { return }
        preferencesStore.updateQuotaSnapshot(for: config.home, snapshot: .init(
            usedPercent: state.primaryUsedPercent, remainingPercent: state.primaryRemainingPercent,
            resetAt: state.primaryResetAt, secondaryUsedPercent: state.secondaryUsedPercent,
            secondaryRemainingPercent: state.secondaryRemainingPercent, secondaryResetAt: state.secondaryResetAt,
            resetCredits: state.resetCredits, lastUpdated: state.lastUpdated, email: state.email, planType: state.planType,
            primaryResetEvidence: state.primaryResetEvidence, secondaryResetEvidence: state.secondaryResetEvidence))
    }

    /// Stable left-side C1/C2 snapshots for the notch layout.
    public var leftStates: [AccountState] {
        Self.split(states, side: .left)
    }

    /// Stable right-side C3/C4 snapshots for the notch layout.
    public var rightStates: [AccountState] {
        Self.split(states, side: .right)
    }

    /// Returns the current snapshot for one stable account identifier.
    public func state(for id: String) -> AccountState? {
        states.first(where: { $0.id == id })
    }

    /// Refreshes all accounts concurrently. Every account result is applied as
    /// soon as its task finishes, and an individual failure becomes an error
    /// state without cancelling sibling tasks.
    public func refreshAll() async {
        if configs.contains(where: \.isConfigured) { onQuotaRefreshStarted?() }
        let configsSnapshot = configs
        let previousStates = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0) })
        var generations: [String: Int] = [:]
        for config in configsSnapshot {
            let generation = (accountGenerations[config.id] ?? 0) + 1
            accountGenerations[config.id] = generation
            generations[config.id] = generation
        }

        states = configsSnapshot.map { config in
            Self.loadingState(for: config, previous: previousStates[config.id])
        }

        let loader = stateLoader
        await withTaskGroup(of: AccountFetchResult.self) { group in
            for config in configsSnapshot {
                guard config.isConfigured else { continue }
                let previous = previousStates[config.id]
                group.addTask {
                    await self.fetchResult(
                        config: config,
                        previous: previous,
                        loader: loader,
                        revision: previous?.configurationGeneration ?? 0
                    )
                }
            }

            for await result in group {
                guard configs.first(where: { $0.id == result.config.id }) == result.config,
                      state(for: result.config.id)?.configurationGeneration == previousStates[result.config.id]?.configurationGeneration,
                      latestRequestIDs[result.config.id] == result.requestID,
                      accountGenerations[result.config.id] == generations[result.config.id]
                else {
                    logQuotaResult(.quotaResultDiscarded, result: result, reason: "superseded")
                    continue
                }
                apply(result)
            }
        }
    }

    /// 단일 계정 갱신 및 최신 정상 결과 반영 여부 반환; forceFresh 지정 시 이전 조회 재사용 방지
    @discardableResult
    public func refresh(accountID id: String, forceFresh: Bool = false) async -> Bool {
        await refreshOutcome(accountID: id, forceFresh: forceFresh).isSuccess
    }

    /// 같은 조회를 공유한 호출은 화면 적용 세대가 달라도 성공 결과 공유
    public func refreshOutcome(accountID id: String, forceFresh: Bool = false) async -> RefreshOutcome {
        guard let config = configs.first(where: { $0.id == id }) else { return .notConfigured }

        guard config.isConfigured else {
            states = states.map { state in
                guard state.id == id else { return state }
                var initial = Self.initialState(for: config, preferencesStore: preferencesStore)
                initial.configurationGeneration = state.configurationGeneration
                return initial
            }
            return .notConfigured
        }

        onQuotaRefreshStarted?()
        let revision = state(for: id)?.configurationGeneration ?? 0
        accountGenerations[id, default: 0] += 1
        let previous = state(for: id)
        states = states.map { state in
            guard state.id == id else { return state }
            return Self.loadingState(for: config, previous: previous)
        }

        let result = await fetchResult(
            config: config,
            previous: previous,
            loader: stateLoader,
            revision: revision,
            forceFresh: forceFresh
        )
        guard configs.first(where: { $0.id == id }) == config,
              state(for: id)?.configurationGeneration == revision,
              latestRequestIDs[id] == result.requestID else {
            logQuotaResult(.quotaResultDiscarded, result: result, reason: "superseded")
            return .superseded
        }
        let shouldApply = appliedRequestIDs[id] != result.requestID
        if shouldApply { apply(result) }
        return result.state.status == .normal ? .succeeded(applied: shouldApply) : .failed
    }

    /// Convenience spelling for callers holding an account configuration.
    public func refresh(_ config: AccountConfig) async {
        await refresh(accountID: config.id)
    }

    /// Replaces account paths/configuration without allowing in-flight results
    /// for the old configuration to overwrite the new one. The four stable IDs
    /// and their left/right order are always retained; omitted IDs fall back to
    /// the default account configuration.
    public func reconfigure(_ newConfigs: [AccountConfig]) {
        configRevision += 1
        let oldStates = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0) })
        let oldConfigs = Dictionary(uniqueKeysWithValues: configs.map { ($0.id, $0) })
        let normalized = Self.normalizeConfigs(newConfigs)
        for config in normalized where oldConfigs[config.id] != config {
            DiagnosticLogContext.record(.accountReconfigured, accountID: config.id,
                                        fields: [.generation: .integer(configRevision)])
        }
        configs = normalized
        states = normalized.map { config in
            if let previous = oldStates[config.id], oldConfigs[config.id] == config {
                return previous
            }
            for (key, handle) in inFlightFetches where key.id == config.id {
                handle.task.cancel()
                inFlightFetches[key] = nil
            }
            latestRequestIDs[config.id] = nil
            resetHistories[config.id] = nil
            resetBaselines[config.id] = nil
            var initial = Self.initialState(for: config, preferencesStore: preferencesStore)
            initial.configurationGeneration = (oldStates[config.id]?.configurationGeneration ?? 0) + 1
            return initial
        }
    }

    /// Reconfigures the four homes while preserving the stable side mapping.
    public func reconfigure(paths: [URL]) {
        let defaults = AccountConfig.defaultAccounts()
        let configs = Self.stableAccountIDs.enumerated().map { index, id in
            let home = paths.indices.contains(index) ? paths[index] : defaults[index].home
            let position: AccountPosition = index < 2 ? .left : .right
            return AccountConfig(id: id, home: home, position: position)
        }
        reconfigure(configs)
    }

    /// Reconfigures account homes directly from persisted path strings. This
    /// overload preserves empty slots instead of first converting them to a
    /// current-working-directory URL.
    public func reconfigure(pathStrings: [String]) {
        reconfigure(AccountConfig.accounts(for: pathStrings))
    }

    public static func split(_ states: [AccountState], side: AccountPosition) -> [AccountState] {
        let allowedIDs: Set<String> = side == .left ? ["C1", "C2"] : ["C3", "C4"]
        return states
            .filter { allowedIDs.contains($0.id) }
            .sorted { stableIndex(for: $0.id) < stableIndex(for: $1.id) }
    }

    private struct AccountFetchResult: Sendable {
        let config: AccountConfig
        let state: AccountState
        var requestID = UUID()
        /// 자동·수동 조회가 같은 요청을 공유해도 원래 작업 문맥 유지
        var operationID: UUID?
    }

    private struct FetchKey: Hashable, Sendable {
        let id: String
        let homePath: String
        let revision: Int
    }

    private final class FetchHandle: @unchecked Sendable {
        let task: Task<AccountFetchResult, Never>
        let requestID: UUID
        private let lock = NSLock()
        private var waiters = Set<UUID>()

        /// 공유 조회 소비자의 독립 취소를 위한 참조 등록
        func addWaiter(_ id: UUID) { lock.lock(); waiters.insert(id); lock.unlock() }

        /// 마지막 소비자 취소 시에만 실제 조회 취소
        func removeWaiter(_ id: UUID) {
            lock.lock()
            let removed = waiters.remove(id) != nil
            let cancel = removed && waiters.isEmpty
            lock.unlock()
            if cancel { task.cancel() }
        }

        /// 비동기 조회 작업과 요청 식별자 연결
        init(task: Task<AccountFetchResult, Never>, requestID: UUID) {
            self.task = task
            self.requestID = requestID
        }
    }

    /// 계정별 조회 병합 및 필요 시 새로운 조회 생성
    private func fetchResult(
        config: AccountConfig,
        previous: AccountState?,
        loader: @escaping AccountStateLoader,
        revision: Int,
        forceFresh: Bool = false
    ) async -> AccountFetchResult {
        guard !shuttingDown, !Task.isCancelled, configs.first(where: { $0.id == config.id }) == config,
              state(for: config.id)?.configurationGeneration == revision else {
            return AccountFetchResult(config: config, state: AccountState(id: config.id, status: .error))
        }
        let key = FetchKey(id: config.id, homePath: config.home.path, revision: revision)
        let handle: FetchHandle
        if !forceFresh, let existing = inFlightFetches[key], !existing.task.isCancelled {
            handle = existing
        } else {
            let requestID = UUID()
            let operationID = DiagnosticLogContext.operationID ?? requestID
            let logger = DiagnosticLogContext.logger ?? .shared
            let task = Task.detached(priority: nil) {
                let started = ProcessInfo.processInfo.systemUptime
                logger.record(.quotaRefreshStarted, operationID: operationID, accountID: config.id,
                              fields: [.requestID: .identifier(requestID.uuidString),
                                       .generation: .integer(revision), .forceFresh: .boolean(forceFresh)])
                var result = await Self.fetch(config: config, previous: previous, loader: loader)
                result.requestID = requestID
                result.operationID = operationID
                var fields = DiagnosticLogContext.resetFields(before: previous, after: result.state)
                fields[.requestID] = .identifier(requestID.uuidString)
                fields[.status] = .identifier(result.state.status.rawValue)
                fields[.durationMS] = DiagnosticLogContext.elapsedMS(since: started)
                logger.record(.quotaRefreshFinished, level: result.state.status == .normal ? .notice : .error,
                              operationID: operationID, accountID: config.id, fields: fields)
                return result
            }
            let created = FetchHandle(task: task, requestID: requestID)
            inFlightFetches[key] = created
            activeFetches[requestID] = created
            handle = created
        }

        latestRequestIDs[config.id] = handle.requestID
        let waiterID = UUID()
        handle.addWaiter(waiterID)
        let result = await withTaskCancellationHandler {
            await handle.task.value
        } onCancel: {
            handle.removeWaiter(waiterID)
        }
        handle.removeWaiter(waiterID)
        activeFetches[handle.requestID] = nil
        if inFlightFetches[key] === handle {
            inFlightFetches[key] = nil
        }
        return result
    }

    /// 앱 종료 시 덮어쓴 이전 조회까지 취소하고 제한시간 내 자식 종료 대기
    public func shutdown(timeout: TimeInterval = 2) async {
        shuttingDown = true
        let handles = Array(activeFetches.values)
        for handle in handles { handle.task.cancel() }
        let deadline = Date().addingTimeInterval(timeout)
        while !activeFetches.isEmpty && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    nonisolated private static func fetch(
        config: AccountConfig,
        previous: AccountState?,
        loader: AccountStateLoader
    ) async -> AccountFetchResult {
        guard config.isConfigured else {
            return AccountFetchResult(
                config: config,
                state: AccountState.notConfigured(id: config.id)
            )
        }
        do {
            var state = try await loader(config)
            if state.id != config.id {
                state = AccountState(
                    id: config.id,
                    email: state.email,
                    planType: state.planType,
                    primaryUsedPercent: state.primaryUsedPercent,
                    secondaryUsedPercent: state.secondaryUsedPercent,
                    primaryResetAt: state.primaryResetAt,
                    secondaryResetAt: state.secondaryResetAt,
                    resetCredits: state.resetCredits,
                    lastUpdated: state.lastUpdated,
                    status: state.status,
                    errorMessage: state.errorMessage
                )
            }
            if Self.shouldPreservePreviousSnapshot(for: state.status) {
                state = Self.mergedNonNormalState(state, previous: previous, id: config.id)
            }
            return AccountFetchResult(config: config, state: state)
        } catch {
            return AccountFetchResult(
                config: config,
                state: Self.errorState(
                    for: config,
                    previous: previous,
                    message: String(describing: error)
                )
            )
        }
    }

    /// Timeout and generic app-server/process failures can recover on a later
    /// refresh, so retain the last successful quota for their presentation.
    /// Login-required and missing-executable states are intentionally kept
    /// distinct and must not display stale quota values.
    nonisolated private static func shouldPreservePreviousSnapshot(for status: AccountStatus) -> Bool {
        switch status {
        case .timeout, .error:
            return true
        case .notConfigured, .normal, .loading, .loginRequired, .codexNotFound:
            return false
        }
    }

    nonisolated private static func mergedNonNormalState(
        _ returned: AccountState,
        previous: AccountState?,
        id: String
    ) -> AccountState {
        guard let previous else { return returned }
        return AccountState(
            id: id,
            email: previous.email ?? returned.email,
            planType: previous.planType ?? returned.planType,
            primaryUsedPercent: previous.primaryUsedPercent ?? returned.primaryUsedPercent,
            secondaryUsedPercent: previous.secondaryUsedPercent ?? returned.secondaryUsedPercent,
            primaryResetAt: previous.primaryResetAt ?? returned.primaryResetAt,
            secondaryResetAt: previous.secondaryResetAt ?? returned.secondaryResetAt,
            resetCredits: previous.resetCredits ?? returned.resetCredits,
            lastUpdated: previous.lastUpdated ?? returned.lastUpdated,
            status: returned.status,
            errorMessage: returned.errorMessage
        )
    }

    /// 최신 상태 및 정상 스냅샷 저장 후 조기 리셋 이벤트 전달
    private func apply(_ result: AccountFetchResult) {
        guard appliedRequestIDs[result.config.id] != result.requestID else { return }
        appliedRequestIDs[result.config.id] = result.requestID
        guard let index = states.firstIndex(where: { $0.id == result.config.id }) else { return }
        var state = result.state
        state.configurationGeneration = states[index].configurationGeneration
        var changes: [QuotaResetChange] = []
        if state.status == .normal {
            var history = resetHistories[state.id]
            if history?.email != state.email || history?.planType != state.planType {
                history = nil
            }
            var current = history ?? ResetHistory(email: state.email, planType: state.planType)
            let now = observationNow()
            let uptime = observationUptime()
            let maximumGap = max(900, Double(preferencesStore.refreshIntervalMinutes) * 120 + 30)
            if let updated = state.lastUpdated,
               abs(updated.timeIntervalSince(now)) <= 30 {
                let clockChanged: Bool
                if let wall = current.lastObservedAt, let monotonic = current.lastUptime {
                    clockChanged = uptime < monotonic || abs(now.timeIntervalSince(wall) - (uptime - monotonic)) > ResetTimeTracker.tolerance
                } else { clockChanged = false }
                if clockChanged {
                    current.primary.restart()
                    current.secondary.restart()
                }
                if let previous = resetBaselines[state.id], let previousUpdated = previous.lastUpdated,
                   previous.configurationGeneration == state.configurationGeneration,
                   previous.email == state.email, previous.planType == state.planType {
                    guard updated > previousUpdated || clockChanged else {
                        var preserved = states[index]
                        preserved.status = .normal
                        states[index] = preserved
                        logQuotaResult(.quotaResultDiscarded, result: result, reason: "stale_snapshot")
                        return
                    }
                    let elapsed = updated.timeIntervalSince(previousUpdated)
                    let clockConsistent = current.lastUptime.map { abs((uptime - $0) - elapsed) <= ResetTimeTracker.tolerance } ?? true
                    if elapsed > 0, elapsed <= maximumGap, clockConsistent, !clockChanged {
                        changes = QuotaResetChange.detect(previous: previous, current: state, now: now)
                    }
                }
                for change in changes {
                    if change.window == .primary { current.primary.restart() }
                    else { current.secondary.restart() }
                    DiagnosticLogContext.record(.quotaResetDetected, accountID: state.id, fields: [
                        .window: .identifier(change.window.rawValue), .cause: .identifier(change.cause.rawValue),
                        .reason: .identifier(change.kind.rawValue),
                        .segmentID: .identifier((change.window == .primary ? current.primary.segmentID : current.secondary.segmentID).uuidString)
                    ])
                }
                state.primaryResetObservation = current.primary.observe(
                    resetAt: state.primaryResetAt, observedAt: updated,
                    uptime: uptime, maximumGap: maximumGap
                )
                state.secondaryResetObservation = current.secondary.observe(
                    resetAt: state.secondaryResetAt, observedAt: updated,
                    uptime: uptime, maximumGap: maximumGap
                )
                let previous = states[index]
                let retainEvidence = !clockChanged && previous.acceptsIdentity(of: state)
                state.primaryResetEvidence = Self.resetEvidence(
                    resetAt: state.primaryResetAt, observation: &state.primaryResetObservation,
                    previous: retainEvidence && !changes.contains(where: { $0.window == .primary }) ? previous.primaryResetEvidence : nil,
                    observedAt: updated, now: now
                )
                state.secondaryResetEvidence = Self.resetEvidence(
                    resetAt: state.secondaryResetAt, observation: &state.secondaryResetObservation,
                    previous: retainEvidence && !changes.contains(where: { $0.window == .secondary }) ? previous.secondaryResetEvidence : nil,
                    observedAt: updated, now: now
                )
                state.primaryResetSegmentID = state.primaryResetAt.map { $0.timeIntervalSince1970.isFinite && $0 > now } == true ? current.primary.segmentID : nil
                state.secondaryResetSegmentID = state.secondaryResetAt.map { $0.timeIntervalSince1970.isFinite && $0 > now } == true ? current.secondary.segmentID : nil
                state.resetChanges = changes
                current.lastUptime = uptime
                current.lastObservedAt = now
                recordObservation(state, previous: resetBaselines[state.id])
                resetHistories[state.id] = current
                resetBaselines[state.id] = state
            } else {
                resetHistories[state.id] = nil
            }
        } else {
            if Self.shouldPreservePreviousSnapshot(for: state.status) {
                if var retained = resetHistories[state.id] {
                    retained.primary.restart()
                    retained.secondary.restart()
                    resetHistories[state.id] = retained
                }
                state.primaryResetObservation = states[index].primaryResetObservation
                state.secondaryResetObservation = states[index].secondaryResetObservation
                state.primaryResetSegmentID = states[index].primaryResetSegmentID
                state.secondaryResetSegmentID = states[index].secondaryResetSegmentID
                state.primaryResetEvidence = states[index].primaryResetEvidence
                state.secondaryResetEvidence = states[index].secondaryResetEvidence
            } else {
                resetHistories[state.id] = nil
                resetBaselines[state.id] = nil
            }
        }
        states[index] = state
        logQuotaResult(.quotaResultApplied, result: result)
        guard result.config.isConfigured, result.state.status == .normal else { return }
        let earlyWindows = changes.filter { $0.kind == .reset && $0.previousReset > observationNow() }.map(\.window)
        preferencesStore.updateQuotaSnapshot(
            for: result.config.home,
            snapshot: PreferencesStore.QuotaSnapshot(
                usedPercent: result.state.usedPercent,
                remainingPercent: result.state.remainingPercent,
                resetAt: result.state.resetAt,
                secondaryUsedPercent: result.state.secondaryUsedPercent,
                secondaryRemainingPercent: result.state.secondaryRemainingPercent,
                secondaryResetAt: result.state.secondaryResetAt,
                resetCredits: result.state.resetCredits,
                lastUpdated: result.state.lastUpdated,
                email: state.email, planType: state.planType,
                primaryResetEvidence: state.primaryResetEvidence,
                secondaryResetEvidence: state.secondaryResetEvidence
            )
        )
        if !earlyWindows.isEmpty {
            onEarlyQuotaReset?(EarlyQuotaReset(accountID: state.id, windows: earlyWindows))
        }
    }

    /// 같은 계정·미래 시각의 이전 근거 유지 및 새 고정 관측 보관
    private static func resetEvidence(
        resetAt: Date?, observation: inout ResetTimeObservation,
        previous: ResetTimeEvidence?, observedAt: Date, now: Date
    ) -> ResetTimeEvidence? {
        if observation == .stableObserved, let resetAt {
            return ResetTimeEvidence(resetAt: resetAt, observedAt: observedAt)
        }
        if observation == .checking, let previous, previous.matches(resetAt, now: now) {
            observation = .stableObserved
            return previous
        }
        return nil
    }

    /// 민감 정보 없이 한도별 관측 구간·상태·간격·전후 시각 기록
    private func recordObservation(_ current: AccountState, previous: AccountState?) {
        for window: EarlyQuotaReset.Window in [.primary, .secondary] {
            let primary = window == .primary
            let segment = primary ? current.primaryResetSegmentID : current.secondaryResetSegmentID
            var fields = DiagnosticLogContext.resetFields(before: previous, after: current)
            fields[.window] = .identifier(window.rawValue)
            fields[.observation] = .identifier((primary ? current.primaryResetObservation : current.secondaryResetObservation).rawValue)
            if let segment { fields[.segmentID] = .identifier(segment.uuidString) }
            if let previousUpdated = previous?.lastUpdated, let updated = current.lastUpdated {
                fields[.durationMS] = .integer(Int(max(0, updated.timeIntervalSince(previousUpdated)) * 1000))
            }
            DiagnosticLogContext.record(.resetObservationUpdated, accountID: current.id, fields: fields)
        }
    }

    /// 조회 식별자와 세대로 화면 반영·무시 결과의 연결 기록
    private func logQuotaResult(_ event: DiagnosticEvent, result: AccountFetchResult, reason: String? = nil) {
        var fields: [DiagnosticField: DiagnosticValue] = [
            .requestID: .identifier(result.requestID.uuidString),
            .status: .identifier(result.state.status.rawValue),
            .generation: .integer(state(for: result.config.id)?.configurationGeneration ?? 0),
        ]
        if let reason { fields[.reason] = .identifier(reason) }
        (DiagnosticLogContext.logger ?? .shared).record(
            event, operationID: result.operationID ?? DiagnosticLogContext.operationID ?? result.requestID,
            accountID: result.config.id, fields: fields
        )
    }

    private static func initialState(
        for config: AccountConfig,
        preferencesStore: PreferencesStore
    ) -> AccountState {
        guard config.isConfigured else {
            return AccountState.notConfigured(id: config.id)
        }
        guard let snapshot = preferencesStore.quotaSnapshot(for: config.home) else {
            var state = AccountState.loading(id: config.id)
            state.isWaitingForRefresh = true
            return state
        }
        var state = AccountState(
            id: config.id,
            email: snapshot.email,
            planType: snapshot.planType,
            primaryUsedPercent: snapshot.primaryUsedPercent,
            secondaryUsedPercent: snapshot.secondaryUsedPercent,
            primaryRemainingPercent: snapshot.primaryRemainingPercent,
            secondaryRemainingPercent: snapshot.secondaryRemainingPercent,
            primaryResetAt: snapshot.primaryResetAt,
            secondaryResetAt: snapshot.secondaryResetAt,
            resetCredits: snapshot.resetCredits,
            lastUpdated: snapshot.lastUpdated,
            status: .loading
        )
        state.isWaitingForRefresh = true
        if let evidence = snapshot.primaryResetEvidence, evidence.matches(state.primaryResetAt) {
            state.primaryResetEvidence = evidence
            state.primaryResetObservation = .stableObserved
        }
        if let evidence = snapshot.secondaryResetEvidence, evidence.matches(state.secondaryResetAt) {
            state.secondaryResetEvidence = evidence
            state.secondaryResetObservation = .stableObserved
        }
        return state
    }

    /// 직전 경로 세대를 유지한 로딩 상태 구성 및 이전 오류 해제
    private static func loadingState(for config: AccountConfig, previous: AccountState?) -> AccountState {
        guard config.isConfigured else {
            var state = AccountState.notConfigured(id: config.id)
            state.configurationGeneration = previous?.configurationGeneration ?? 0
            return state
        }
        guard let previous else { return AccountState.loading(id: config.id) }
        var state = previous
        state.status = .loading
        state.isWaitingForRefresh = false
        state.errorMessage = nil
        return state
    }

    nonisolated private static func errorState(
        for config: AccountConfig,
        previous: AccountState?,
        message: String
    ) -> AccountState {
        guard let previous else {
            return AccountState(id: config.id, status: .error, errorMessage: message)
        }
        return AccountState(
            id: config.id,
            email: previous.email,
            planType: previous.planType,
            primaryUsedPercent: previous.primaryUsedPercent,
            secondaryUsedPercent: previous.secondaryUsedPercent,
            primaryResetAt: previous.primaryResetAt,
            secondaryResetAt: previous.secondaryResetAt,
            resetCredits: previous.resetCredits,
            lastUpdated: previous.lastUpdated,
            status: .error,
            errorMessage: message
        )
    }

    private static func normalizeConfigs(_ input: [AccountConfig]) -> [AccountConfig] {
        let defaults = AccountConfig.defaultAccounts()
        let byID = Dictionary(input.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return stableAccountIDs.enumerated().map { index, id in
            byID[id] ?? defaults[index]
        }
    }

    private static func stableIndex(for id: String) -> Int {
        stableAccountIDs.firstIndex(of: id) ?? stableAccountIDs.count
    }
}
