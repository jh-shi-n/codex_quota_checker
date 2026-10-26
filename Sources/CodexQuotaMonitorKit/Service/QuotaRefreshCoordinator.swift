// 목적: 캐시 유효성에 따른 시작 조회 횟수와 큰 일정 변경의 재확인
// 이용처: 앱 시작·주기 조회·수동 새로고침의 공통 할당량 조회
// 사용방법: refreshAll(startup:) 또는 refresh(accountID:startup:) 호출
import Foundation

/// 토큰 생성 없이 할당량 조회만 사용하는 캐시 비교·3초 간격 확인
@MainActor
public final class QuotaRefreshCoordinator {
    private let store: AccountStore
    private let now: () -> Date
    private let sleep: (TimeInterval) async throws -> Void
    private var running: Set<String> = []

    /// 실제 저장소와 테스트 가능한 시계·대기 연결
    public init(store: AccountStore, now: @escaping () -> Date = { Date() },
                sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.store = store
        self.now = now
        self.sleep = sleep
    }

    /// 등록 계정별 확인을 병행하되 동일 계정의 중복 확인 차단
    public func refreshAll(startup: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            for config in store.configs where config.isConfigured {
                let id = config.id
                group.addTask { await self.refresh(accountID: id, startup: startup) }
            }
        }
    }

    /// 캐시 없음·만료는 두 번, 유효 캐시는 한 번 비교, 큰 변경은 추가 확인
    public func refresh(accountID: String, startup: Bool = false) async {
        guard !Task.isCancelled, running.insert(accountID).inserted else { return }
        defer { running.remove(accountID) }
        let previous = store.state(for: accountID)
        guard await store.refresh(accountID: accountID, forceFresh: true), !Task.isCancelled,
              let first = store.state(for: accountID), first.status == .normal,
              let firstUpdated = first.lastUpdated, abs(firstUpdated.timeIntervalSince(now())) <= 30 else { return }
        let expired = previous?.lastUpdated == nil || (previous?.primaryResetAt.map { !$0.timeIntervalSince1970.isFinite || $0 <= now() } ?? true)
        let changed = Self.hasLargeChange(previous: previous, current: first)
        if changed, var baseline = previous {
            baseline.status = .normal
            for change in QuotaResetChange.detect(previous: baseline, current: first, now: now()) {
                DiagnosticLogContext.record(.quotaResetDetected, accountID: accountID, fields: [
                    .reason: .identifier("cached_schedule_changed"), .window: .identifier(change.window.rawValue),
                    .cause: .identifier(change.cause.rawValue)
                ])
            }
        }
        if expired || changed || (startup && previous?.acceptsIdentity(of: first) == false) {
            store.beginResetVerification(expected: first)
            do { try await sleep(3) } catch { store.endResetVerification(expected: first); return }
            guard !Task.isCancelled, let active = store.state(for: accountID),
                  active.lastUpdated == first.lastUpdated, active.acceptsIdentity(of: first),
                  await store.refresh(accountID: accountID, forceFresh: true),
                  let second = store.state(for: accountID),
                  second.lastUpdated.map({ $0 > firstUpdated }) == true else {
                store.endResetVerification(expected: first)
                return
            }
            store.finishResetVerification(expected: second, comparedTo: first)
        } else if startup, let previous {
            store.finishResetVerification(expected: first, comparedTo: previous)
        }
    }

    /// 조회 경과에 비례한 이동을 제외한 1분 초과의 갑작스러운 일정 변경 판별
    public static func hasLargeChange(previous: AccountState?, current: AccountState) -> Bool {
        guard let previous, previous.acceptsIdentity(of: current) else { return false }
        let elapsed = current.lastUpdated.flatMap { latest in previous.lastUpdated.map { latest.timeIntervalSince($0) } }
        for (old, new) in [(previous.primaryResetAt, current.primaryResetAt),
                           (previous.secondaryResetAt, current.secondaryResetAt)] {
            guard let old, let new else { continue }
            let delta = new.timeIntervalSince(old)
            if abs(delta) > 60 && (elapsed.map({ abs(delta - $0) > 60 }) ?? true) { return true }
        }
        return false
    }
}

/// 시작 검증과 저장된 주기 조회 선택에 따른 타이머 수명 관리
@MainActor
public final class QuotaMonitoringController {
    public let checks: QuotaRefreshCoordinator
    public let refreshService: RefreshService
    public private(set) var isStarting = false
    public var onStartupFinished: (() -> Void)?
    private let preferences: PreferencesStore
    private var startupTask: Task<Void, Never>?

    /// 시작 확인과 일반 주기 조회를 같은 계정별 확인기로 연결
    public init(store: AccountStore, preferences: PreferencesStore) {
        let checks = QuotaRefreshCoordinator(store: store)
        self.checks = checks
        self.preferences = preferences
        refreshService = RefreshService(intervalMinutes: preferences.refreshIntervalMinutes,
            refresh: { await checks.refreshAll() })
    }

    /// 주기 조회 선택과 무관한 시작 검증 후 첫 주기까지 대기
    public func launch() {
        guard startupTask == nil else { return }
        isStarting = true
        startupTask = Task {
            await checks.refreshAll(startup: true)
            isStarting = false
            startupTask = nil
            guard !Task.isCancelled else { return }
            onStartupFinished?()
            if preferences.automaticRefreshEnabled { refreshService.start(skipImmediate: true) }
        }
    }

    /// 설정 ON의 즉시 조회·주기 시작 또는 OFF의 타이머 종료
    public func setEnabled(_ enabled: Bool) {
        if enabled && !isStarting { refreshService.start() }
        else { refreshService.stop() }
    }

    /// OFF 상태를 유지하며 설정 간격 변경 반영
    public func restart(minutes: Int) {
        refreshService.updateInterval(minutes: minutes)
        if preferences.automaticRefreshEnabled && !isStarting { refreshService.restart(intervalMinutes: minutes) }
    }

    /// 시작 대기·실행 중 조회·주기 타이머 종료
    public func stop() {
        startupTask?.cancel()
        startupTask = nil
        refreshService.stop()
    }
}
