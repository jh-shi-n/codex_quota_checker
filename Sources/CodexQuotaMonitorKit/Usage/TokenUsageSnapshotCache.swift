import Foundation

/// 목적: 계정별 토큰 사용량 스냅샷 캐시
/// 이용처: 앱 대시보드의 마지막 성공 조회 결과
/// 사용방법: 계정 홈을 설정하고 명시적 업데이트 또는 캐시 조회 호출
public actor TokenUsageSnapshotCache {
    /// 성공 스냅샷 보존 기간(초)
    public static let snapshotLifetime: TimeInterval = 14 * 24 * 60 * 60

    /// 앱 전용 Application Support 저장소 경로
    public static var defaultDatabaseURL: URL {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return supportDirectory
            .appendingPathComponent("CodexQuotaMonitor", isDirectory: true)
            .appendingPathComponent("token-usage.sqlite", isDirectory: false)
            .standardizedFileURL
    }

    /// 정리 실패의 호출자 조회 경계; 다음 주기의 성공 시 해제
    public var hasCleanupFailure: Bool { persistence?.hasCleanupFailure ?? false }

    private let sharedHomeResolver: SharedCodexHomeResolver
    private let provider: any TokenUsageProvider
    private let todayProvider: (any TokenUsageTodayProvider)?
    private var automaticRefreshes: Set<String> = []
    private var manualRefreshes: [String: Int] = [:]
    private let invalidationState: InvalidationState
    private let persistence: SQLiteTokenUsageSnapshotStore?
    private let history: SQLiteTokenUsageHistoryStore?
    private var historyOptions: TokenUsageOptions
    private var historyPolicyRevision = 0
    public private(set) var historyError: String?
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private var accountHomes: [String: URL]
    private var snapshots: [String: Entry] = [:]

    /// 메모리 캐시 행과 만료 정보
    private struct Entry: Sendable {
        let token: InvalidationState.Token
        let snapshot: TokenUsageSnapshot
        let updatedAt: Date
        let expiresAt: Date
        let homeIdentity: String?
    }

    /// 캐시 저장소와 현재 계정 홈 초기화
    public init(
        provider: any TokenUsageProvider = LocalTokenUsageProvider(),
        databaseURL: URL? = nil,
        accountHomes: [String: URL] = [:],
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .autoupdatingCurrent,
        historyDatabaseURL: URL? = nil,
        retentionMonths: Int = 12,
        todayProvider: (any TokenUsageTodayProvider)? = nil,
        sharedHomeResolver: SharedCodexHomeResolver = SharedCodexHomeResolver()
    ) {
        self.sharedHomeResolver = sharedHomeResolver
        self.provider = provider
        self.todayProvider = todayProvider
        self.invalidationState = InvalidationState()
        self.persistence = databaseURL.map { SQLiteTokenUsageSnapshotStore(databaseURL: $0) }
        self.history = historyDatabaseURL.map { SQLiteTokenUsageHistoryStore(databaseURL: $0) }
        self.historyOptions = TokenUsageOptions(retentionMonths: retentionMonths)
        self.now = now
        self.calendar = calendar
        self.accountHomes = Self.normalizedHomes(accountHomes)
    }

    /// 현재 계정의 유효한 스냅샷 조회와 저장소 복원
    public func cachedSnapshot(for accountID: String) -> TokenUsageSnapshot? {
        let referenceDate = now()
        purgeExpired(at: referenceDate)
        let token = invalidationState.current(for: accountID)
        let expectedIdentity = accountHomes[accountID].map(self.sourceIdentity)

        if let entry = snapshots[accountID],
           entry.token == token,
           entry.expiresAt > referenceDate,
           expectedIdentity == nil || entry.homeIdentity == expectedIdentity {
            return history == nil ? entry.snapshot.rebased(to: referenceDate, calendar: calendar)
                : entry.snapshot.retained(months: historyOptions.retentionMonths, at: referenceDate, calendar: calendar)
        }
        snapshots.removeValue(forKey: accountID)

        if let history, let expectedIdentity {
            do {
                if let archived = try invalidationState.optionalValueIfCurrent(token, accountID: accountID, {
                    try history.load(accountID: accountID, homeIdentity: expectedIdentity,
                        options: historyOptions, now: referenceDate, calendar: calendar)
                }) {
                    historyError = nil
                    return archived
                }
            } catch { historyError = "토큰 일별 집계를 복원하지 못했습니다. 저장소 접근 권한을 확인해 주세요." }
        }

        guard let expectedIdentity,
              let record = invalidationState.optionalValueIfCurrent(token, accountID: accountID, {
                  persistence?.load(
                      accountID: accountID,
                      homeIdentity: expectedIdentity,
                      referenceDate: referenceDate
                  )
              }) ?? nil,
              let snapshot = try? TokenUsageSnapshotPayload.decode(record.payload) else {
            return nil
        }

        let restored: TokenUsageSnapshot
        if let history {
            do {
                restored = try invalidationState.valueIfCurrent(token, accountID: accountID) {
                    try history.merge(snapshot, accountID: accountID, homeIdentity: expectedIdentity,
                        options: historyOptions, now: referenceDate, calendar: calendar)
                } ?? snapshot
            } catch { historyError = "기존 토큰 캐시를 일별 집계로 이관하지 못했습니다."; return nil }
        } else { restored = snapshot }
        snapshots[accountID] = Entry(
            token: token,
            snapshot: restored,
            updatedAt: record.updatedAt,
            expiresAt: record.expiresAt,
            homeIdentity: expectedIdentity
        )
        return restored.rebased(to: referenceDate, calendar: calendar)
    }

    /// 호출자가 보유한 스냅샷의 메모리 교체
    public func replace(_ snapshot: TokenUsageSnapshot, for accountID: String) {
        let completedAt = now()
        let token = invalidationState.beginRefresh(accountID: accountID)
        snapshots[accountID] = Entry(
            token: token,
            snapshot: snapshot,
            updatedAt: completedAt,
            expiresAt: completedAt.addingTimeInterval(Self.snapshotLifetime),
            homeIdentity: accountHomes[accountID].map(self.sourceIdentity)
        )
    }

    /// 명시적 조회 결과의 성공 교체와 영속 저장
    public func refresh(accountID: String, home: URL) async -> TokenUsageSnapshot {
        manualRefreshes[accountID, default: 0] += 1
        defer { manualRefreshes[accountID, default: 1] -= 1 }
        let homeIdentity = self.sourceIdentity(home)

        if let configuredHome = accountHomes[accountID],
           self.sourceIdentity(configuredHome) != homeIdentity {
            return await provider.snapshot(home: home)
        }

        if let entry = snapshots[accountID], entry.homeIdentity != homeIdentity {
            invalidationState.invalidate(accountID: accountID) {
                self.persistence?.remove(accountID: accountID)
            }
            snapshots.removeValue(forKey: accountID)
        }

        let requestDate = now()
        purgeExpired(at: requestDate)
        let token = invalidationState.beginRefresh(accountID: accountID)
        if let entry = snapshots[accountID],
           entry.homeIdentity == homeIdentity,
           entry.expiresAt > requestDate {
            snapshots[accountID] = Entry(
                token: token,
                snapshot: entry.snapshot,
                updatedAt: entry.updatedAt,
                expiresAt: entry.expiresAt,
                homeIdentity: entry.homeIdentity
            )
        }

        let policyRevision = historyPolicyRevision
        var snapshot: TokenUsageSnapshot
        if let local = provider as? LocalTokenUsageProvider {
            let cutoff = historyOptions.cutoff(at: requestDate, calendar: calendar)
            let count = history == nil ? TokenUsageSnapshot.historyDayCount
                : (calendar.dateComponents([.day], from: cutoff, to: calendar.startOfDay(for: requestDate)).day ?? 0) + 1
            snapshot = await LocalTokenUsageProvider(calendar: local.calendar, now: { requestDate },
                maxFileCount: local.maxFileCount, maxLineBytes: local.maxLineBytes, maxReadBytes: local.maxReadBytes,
                historyDayCount: count).snapshot(homes: sourceHomes(home))
        } else if history != nil, let ranged = provider as? any TokenUsageRangeProvider {
            let cutoff = historyOptions.cutoff(at: requestDate, calendar: calendar)
            let count = (calendar.dateComponents([.day], from: cutoff, to: calendar.startOfDay(for: requestDate)).day ?? 0) + 1
            snapshot = await ranged.snapshot(home: home, historyDayCount: count)
        } else { snapshot = await provider.snapshot(home: home) }
        guard homeIdentity == sourceIdentity(home), policyRevision == historyPolicyRevision else {
            return cachedSnapshot(for: accountID) ?? Self.supersededSnapshot(generatedAt: now())
        }
        guard invalidationState.current(for: accountID) == token else {
            return cachedSnapshot(for: accountID)
                ?? Self.supersededSnapshot(generatedAt: now())
        }
        guard snapshot.availability == .available else {
            return snapshot
        }

        return commitSnapshot(snapshot, accountID: accountID, homeIdentity: homeIdentity, token: token)
    }

    /// 검증된 전체·당일 집계의 공통 저장 경계
    private func commitSnapshot(_ initial: TokenUsageSnapshot, accountID: String, homeIdentity: String,
                                token: InvalidationState.Token) -> TokenUsageSnapshot {
        var snapshot = initial
        if let history {
            do {
                guard let archived = try invalidationState.valueIfCurrent(token, accountID: accountID, {
                    try history.merge(snapshot, accountID: accountID, homeIdentity: homeIdentity,
                        options: historyOptions, now: now(), calendar: calendar)
                }) else { return cachedSnapshot(for: accountID) ?? Self.supersededSnapshot(generatedAt: now()) }
                snapshot = archived
                historyError = nil
            } catch {
                historyError = "토큰 일별 집계를 저장하지 못했습니다. 저장 공간과 접근 권한을 확인해 주세요."
                return Self.storageUnavailableSnapshot(from: snapshot, generatedAt: now())
            }
        }

        let completedAt = now()
        let expiresAt = completedAt.addingTimeInterval(Self.snapshotLifetime)
        let payload: Data?
        if persistence != nil {
            payload = try? TokenUsageSnapshotPayload(snapshot: snapshot).encode()
        } else {
            payload = nil
        }
        guard let saved = invalidationState.valueIfCurrent(token, accountID: accountID, {
            guard let persistence = self.persistence else { return true }
            guard let payload else { return false }
            persistence.purgeExpired(beforeOrAt: completedAt)
            return persistence.save(
                payload: payload,
                accountID: accountID,
                homeIdentity: homeIdentity,
                updatedAt: completedAt,
                expiresAt: expiresAt
            )
        }) else {
            return cachedSnapshot(for: accountID)
                ?? Self.supersededSnapshot(generatedAt: now())
        }
        guard saved else {
            return Self.storageUnavailableSnapshot(from: snapshot, generatedAt: completedAt)
        }

        snapshots[accountID] = Entry(
            token: token,
            snapshot: snapshot,
            updatedAt: completedAt,
            expiresAt: expiresAt,
            homeIdentity: homeIdentity
        )
        return snapshot
    }

    /// 당일 추가 기록만 반영하며 전체 집계·계정 변경·수집 실패 시 기존 캐시 유지
    public func refreshToday(accountID: String, home: URL) async -> TokenUsageSnapshot? {
        guard let todayProvider, !Task.isCancelled,
              manualRefreshes[accountID, default: 0] == 0,
              !automaticRefreshes.contains(accountID),
              accountHomes[accountID].map(self.sourceIdentity) == self.sourceIdentity(home)
        else { return cachedSnapshot(for: accountID) }
        automaticRefreshes.insert(accountID)
        defer { automaticRefreshes.remove(accountID) }
        let token = invalidationState.current(for: accountID)
        let identity = sourceIdentity(home)
        let policy = historyPolicyRevision
        let collected: TokenUsageSnapshot?
        if let local = todayProvider as? TodayTokenUsageProvider {
            collected = await local.todaySnapshot(homes: sourceHomes(home))
        } else { collected = await todayProvider.todaySnapshot(home: home) }
        guard let collected,
              collected.availability == .available, !Task.isCancelled,
              identity == sourceIdentity(home), token == invalidationState.current(for: accountID), policy == historyPolicyRevision,
              calendar.isDate(collected.generatedAt, inSameDayAs: now())
        else { return cachedSnapshot(for: accountID) }
        let previous = cachedSnapshot(for: accountID)
        let today = calendar.startOfDay(for: now())
        guard let incoming = collected.dailyPoints.first(where: { calendar.isDate($0.date, inSameDayAs: today) })
        else { return previous }
        let old = previous?.dailyPoints.first(where: { calendar.isDate($0.date, inSameDayAs: today) })
        let cached = [old?.cachedInputTokens, incoming.cachedInputTokens].compactMap { $0 }.max()
        let point = TokenUsageDailyPoint(date: today,
            inputTokens: max(old?.inputTokens ?? 0, incoming.inputTokens),
            outputTokens: max(old?.outputTokens ?? 0, incoming.outputTokens),
            cachedInputTokens: cached, sessionCount: max(old?.sessionCount ?? 0, incoming.sessionCount))
        if old == point, previous?.recordedDates?.contains(today) == true { return previous }
        let points = history == nil
            ? (previous?.dailyPoints.filter { !calendar.isDate($0.date, inSameDayAs: today) } ?? []) + [point]
            : [point]
        let count = history == nil ? max(previous?.dailyPoints.count ?? 0, TokenUsageSnapshot.historyDayCount) : 1
        let combined = TokenUsageAggregator(calendar: calendar, dayCount: count).aggregate(dailyPoints: points, generatedAt: collected.generatedAt)
        let coverage = history == nil ? Set((previous?.recordedDates ?? previous?.dailyPoints.map(\.date) ?? []) + [today]).sorted() : [today]
        let source = TokenUsageSnapshot(generatedAt: collected.generatedAt, dailyPoints: combined.dailyPoints,
            today: combined.today, last7Days: combined.last7Days, last30Days: combined.last30Days,
            totalSessions: combined.totalSessions, averageTokensPerSession: combined.averageTokensPerSession,
            recordedDates: coverage)
        let saved = commitSnapshot(source, accountID: accountID, homeIdentity: self.sourceIdentity(home), token: token)
        return saved.availability == .available ? saved : previous
    }

    /// 계정 캐시와 영속 스냅샷 제거
    public func remove(accountID: String) {
        invalidationState.invalidate(accountID: accountID) {
            self.persistence?.remove(accountID: accountID)
            try? self.history?.remove(accountID: accountID)
        }
        snapshots.removeValue(forKey: accountID)
    }

    /// 계정 경로 변경 전에 진행 중 조회와 해당 계정의 영속 기록 무효화
    public nonisolated func invalidate(accountID: String) {
        invalidationState.invalidate(accountID: accountID) {
            self.persistence?.remove(accountID: accountID)
            try? self.history?.remove(accountID: accountID)
        }
        Task { await self.purgeExpired() }
    }

    /// 모든 메모리·영속 스냅샷 제거
    public func removeAll() {
        invalidateAll()
        snapshots.removeAll()
    }

    /// 모든 기존 조회를 무효화하고 오래된 영속 행 제거
    public nonisolated func invalidateAll() {
        let generation = invalidationState.invalidateAll {
            self.persistence?.removeAll()
            try? self.history?.removeAll()
        }
        Task { await self.removeEntries(olderThan: generation) }
    }

    /// 변경·제거된 계정의 캐시만 격리하고 다른 계정의 보관 기한 유지
    public func configureAccountHomes(_ homes: [String: URL]) {
        let normalized = Self.normalizedHomes(homes)
        guard Self.homeIdentities(accountHomes) != Self.homeIdentities(normalized) else {
            accountHomes = normalized
            return
        }
        let oldIdentities = Self.homeIdentities(accountHomes)
        let newIdentities = Self.homeIdentities(normalized)
        for accountID in Set(oldIdentities.keys).union(newIdentities.keys) {
            if oldIdentities[accountID] != newIdentities[accountID] {
                remove(accountID: accountID)
            }
        }
        accountHomes = normalized
    }

    /// 만료된 메모리·SQLite 스냅샷 정리
    public func purgeExpired() {
        purgeExpired(at: now())
    }

    /// 기간 변경 전 진행 중 집계 무효화와 오래된 기록·스냅샷 정리
    @discardableResult
    public func setHistoryRetention(months: Int) -> Bool {
        historyOptions = TokenUsageOptions(retentionMonths: months)
        historyPolicyRevision += 1
        snapshots.removeAll()
        do {
            try invalidationState.perform {
                try history?.prune(options: historyOptions, now: now(), calendar: calendar)
                persistence?.removeAll()
            }
            historyError = nil
            return true
        } catch {
            historyError = "보관 기간이 지난 토큰 집계를 정리하지 못했습니다. 다시 시도해 주세요."
            return false
        }
    }

    /// 기준 시각까지 만료된 메모리·SQLite 행 제거
    private func purgeExpired(at referenceDate: Date) {
        snapshots = snapshots.filter { accountID, entry in
            entry.expiresAt > referenceDate
                && entry.token == invalidationState.current(for: accountID)
        }
        invalidationState.perform {
            persistence?.purgeExpired(beforeOrAt: referenceDate)
            do { try history?.prune(options: historyOptions, now: referenceDate, calendar: calendar) }
            catch { historyError = "보관 기간이 지난 토큰 집계를 정리하지 못했습니다." }
        }
    }

    /// 무효화 이전 세대의 메모리 행 제거
    private func removeEntries(olderThan generation: UInt64) {
        snapshots = snapshots.filter { _, entry in
            entry.token.generation >= generation
        }
    }

    /// 현재 슬롯 목록의 공유 홈 귀속 판정 구성
    private var sourceAccounts: [AccountConfig] {
        accountHomes.sorted { $0.key < $1.key }.map { AccountConfig(id: $0.key, home: $0.value, position: .left) }
    }

    /// 등록 홈에만 유일하게 인증된 공유 소스 추가
    private func sourceHomes(_ home: URL) -> [URL] {
        let accounts = sourceAccounts
        guard let account = accounts.first(where: { Self.homeIdentity($0.home) == Self.homeIdentity(home) }) else { return [home] }
        return sharedHomeResolver.homes(for: account, accounts: accounts)
    }

    /// 인증·추가 소스 변경 전후의 메모리·영속 캐시 격리 키
    private func sourceIdentity(_ home: URL) -> String {
        let accounts = sourceAccounts
        guard let account = accounts.first(where: { Self.homeIdentity($0.home) == Self.homeIdentity(home) }),
              account.provider == .codex else { return Self.homeIdentity(home) }
        return Self.homeIdentity(home) + "#" + sharedHomeResolver.signature(for: account, accounts: accounts)
    }

    /// 계정 홈 URL의 경로 정규화
    private static func normalizedHomes(_ homes: [String: URL]) -> [String: URL] {
        homes.mapValues { home in
            home.isFileURL
                ? home.resolvingSymlinksInPath().standardizedFileURL
                : home.standardizedFileURL
        }
    }

    /// 계정별 정규화 홈 식별자 생성
    private static func homeIdentities(_ homes: [String: URL]) -> [String: String] {
        homes.mapValues(homeIdentity)
    }

    /// 홈 경로의 안정적인 비교 키 생성
    private static func homeIdentity(_ home: URL) -> String {
        let normalized = home.isFileURL
            ? home.resolvingSymlinksInPath().standardizedFileURL
            : home.standardizedFileURL
        return normalized.isFileURL ? normalized.path : normalized.absoluteString
    }

    /// 영속 저장 실패를 조회 불가 결과로 표현
    private static func storageUnavailableSnapshot(
        from snapshot: TokenUsageSnapshot,
        generatedAt: Date
    ) -> TokenUsageSnapshot {
        TokenUsageSnapshot(
            generatedAt: generatedAt,
            dailyPoints: snapshot.dailyPoints.map { TokenUsageDailyPoint(date: $0.date) },
            today: .zero,
            last7Days: .zero,
            last30Days: .zero,
            totalSessions: 0,
            averageTokensPerSession: 0,
            availability: .unavailable,
            error: .storageUnavailable
        )
    }

    /// 최신 계정 요청으로 대체된 응답의 무효 결과
    private static func supersededSnapshot(generatedAt: Date) -> TokenUsageSnapshot {
        TokenUsageSnapshot(
            generatedAt: generatedAt,
            dailyPoints: [],
            availability: .unavailable,
            error: .superseded
        )
    }
}

/// 세대 상태의 짧은 잠금과 디스크 작업의 직렬 큐를 분리한 캐시 격리 경계
private final class InvalidationState: @unchecked Sendable {
    /// 전체·계정 무효화 버전 조합
    struct Token: Equatable, Sendable {
        let generation: UInt64
        let accountRevision: UInt64
    }

    private let stateLock = NSLock()
    private let queue = DispatchQueue(label: "CodexQuotaMonitor.TokenUsageCachePersistence")
    private var generation: UInt64 = 0
    private var accountRevisions: [String: UInt64] = [:]

    /// 디스크 작업을 기다리지 않는 현재 세대 조회
    func current(for accountID: String) -> Token {
        stateLock.withLock {
            Token(generation: generation, accountRevision: accountRevisions[accountID, default: 0])
        }
    }

    /// 새 계정 갱신 요청의 이전 응답 무효화
    func beginRefresh(accountID: String) -> Token {
        stateLock.withLock {
            accountRevisions[accountID, default: 0] &+= 1
            return Token(generation: generation, accountRevision: accountRevisions[accountID, default: 0])
        }
    }

    /// 무효화 전후의 동일 세대에서만 디스크 조회 결과 반환
    func optionalValueIfCurrent<T>(
        _ token: Token,
        accountID: String,
        _ body: () throws -> T?
    ) rethrows -> T? {
        try queue.sync {
            guard current(for: accountID) == token else { return nil }
            let result = try body()
            return current(for: accountID) == token ? result : nil
        }
    }

    /// 저장 중 발생한 무효화의 결과 반영 차단; 후속 정리는 동일 큐에서 실행
    func valueIfCurrent<T>(
        _ token: Token,
        accountID: String,
        _ body: () throws -> T
    ) rethrows -> T? {
        try queue.sync {
            guard current(for: accountID) == token else { return nil }
            let result = try body()
            return current(for: accountID) == token ? result : nil
        }
    }

    /// 저장소 정리와 동시 접근 직렬화
    func perform<T>(_ body: () throws -> T) rethrows -> T {
        try queue.sync(execute: body)
    }

    /// 즉시 세대 변경과 후속 갱신보다 앞선 비동기 디스크 정리 예약
    func invalidate(accountID: String, _ body: @escaping @Sendable () -> Void) {
        stateLock.withLock {
            accountRevisions[accountID, default: 0] &+= 1
            queue.async(execute: body)
        }
    }

    /// 전체 세대 변경과 비동기 삭제 예약의 원자적 순서
    func invalidateAll(_ body: @escaping @Sendable () -> Void) -> UInt64 {
        stateLock.withLock {
            generation &+= 1
            accountRevisions.removeAll(keepingCapacity: true)
            queue.async(execute: body)
            return generation
        }
    }
}
