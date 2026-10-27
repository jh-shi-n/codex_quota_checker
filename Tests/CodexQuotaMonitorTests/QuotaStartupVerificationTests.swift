// 목적: 시작 캐시 분기·3초 간격 재조회·큰 일정 변경·주기 조회 설정 검증
// 이용처: 사용자 계정 요청 없는 시작·수동·주기 조회 회귀 테스트
// 사용방법: swift test --filter QuotaStartupVerificationTests
import XCTest
@testable import CodexQuotaMonitorKit

/// 가상 시계와 임시 SQLite에서 수행하는 조회 횟수·엄격 비교 검증
@MainActor
final class QuotaStartupVerificationTests: XCTestCase {
    /// 주기 조회 OFF 이후 만료 캐시로 재개할 때도 새 구간 두 번 확인 검증
    func testExpiredCacheIsRecheckedDuringPeriodicRefresh() async {
        let fixture = StartupFixture()
        defer { fixture.cleanup() }
        fixture.cache(reset: fixture.start.addingTimeInterval(-1))
        let reset = fixture.start.addingTimeInterval(18_000)
        let result = await fixture.run(resets: [reset, reset], startup: false)
        XCTAssertEqual(result.calls, 2)
        XCTAssertEqual(fixture.delays, [3])
        XCTAssertEqual(result.state?.primaryResetObservation, .stableObserved)
    }

    /// 유효 캐시와 1초 다른 첫 조회를 한 번으로 고정 유지 검증
    func testUnexpiredCacheChangingSecondsReadsOnce() async {
        let fixture = StartupFixture()
        defer { fixture.cleanup() }
        let reset = fixture.start.addingTimeInterval(18_000)
        fixture.cache(reset: reset)
        let result = await fixture.run(resets: [reset.addingTimeInterval(1)], startup: true)
        XCTAssertEqual(result.calls, 1)
        XCTAssertEqual(result.state?.primaryResetObservation, .stableObserved)
        XCTAssertNotNil(result.state?.primaryResetEvidence)
    }

    /// 시작 검증 뒤 즉시 추가 조회 없이 주기 시작, 설정 OFF로 실제 타이머 정지 검증
    func testStartupDoesNotDuplicateFirstPeriodicReadAndToggleStopsTimer() async {
        let fixture = StartupFixture()
        defer { fixture.cleanup() }
        let reset = fixture.start.addingTimeInterval(18_000)
        fixture.cache(reset: reset)
        let source = MonitoringCountSource(reset: reset)
        let store = AccountStore(configs: fixture.configs, preferencesStore: fixture.preferences) { _ in await source.read() }
        let controller = QuotaMonitoringController(store: store, preferences: fixture.preferences)
        fixture.preferences.onAutomaticRefreshChanged = { controller.setEnabled($0) }
        controller.launch()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while controller.isStarting && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(controller.isStarting)
        XCTAssertTrue(controller.refreshService.isRunning)
        try? await Task.sleep(for: .milliseconds(20))
        let calls = await source.calls
        XCTAssertEqual(calls, 1)
        fixture.preferences.updateAutomaticRefresh(false)
        XCTAssertFalse(controller.refreshService.isRunning)
        controller.stop()
    }

    /// 캐시 없음과 만료 시 정확히 두 번 조회 및 3초 대기 검증
    func testMissingOrExpiredCacheReadsTwice() async throws {
        for expired in [false, true] {
            let fixture = StartupFixture()
            defer { fixture.cleanup() }
            if expired { fixture.cache(reset: fixture.start.addingTimeInterval(-1)) }
            let reset = fixture.start.addingTimeInterval(18_000)
            let result = await fixture.run(resets: [reset, reset], startup: true)
            XCTAssertEqual(result.calls, 2)
            XCTAssertEqual(fixture.delays, [3])
            XCTAssertEqual(result.state?.primaryResetObservation, .stableObserved)
            XCTAssertNotNil(result.state?.primaryResetEvidence)
        }
    }

    /// 유효 캐시의 동일 초기화 시각은 한 번의 새 조회로 확인 검증
    func testUnexpiredCacheReadsOnce() async {
        let fixture = StartupFixture()
        defer { fixture.cleanup() }
        let reset = fixture.start.addingTimeInterval(18_000)
        fixture.cache(reset: reset)
        let result = await fixture.run(resets: [reset], startup: true)
        XCTAssertEqual(result.calls, 1)
        XCTAssertEqual(fixture.delays, [])
        XCTAssertEqual(result.state?.primaryResetObservation, .stableObserved)
    }

    /// 첫 두 정상 조회의 1초 잡음으로 고정 관측이 해제되지 않는지 검증
    func testStartupOneSecondJitterRemainsFixed() async {
        let fixture = StartupFixture()
        defer { fixture.cleanup() }
        let reset = fixture.start.addingTimeInterval(18_000)
        let result = await fixture.run(resets: [reset, reset.addingTimeInterval(1)], startup: true)
        XCTAssertEqual(result.calls, 2)
        XCTAssertEqual(result.state?.primaryResetObservation, .stableObserved)
        XCTAssertNotNil(result.state?.primaryResetEvidence)
    }

    /// 저장된 고정 근거는 양방향 3초까지 유지, 단발 초과 보정은 미확인 유지 검증
    func testKnownFixedTimeToleratesThreeSecondsButNotMore() async {
        for delta in [-3.001, -3.0, -2, -1, 1, 2, 3, 3.001] {
            let fixture = StartupFixture()
            defer { fixture.cleanup() }
            let reset = fixture.start.addingTimeInterval(18_000)
            fixture.cache(reset: reset, evidence: true)
            let result = await fixture.run(resets: [reset.addingTimeInterval(delta)], startup: true)
            XCTAssertEqual(result.calls, 1)
            XCTAssertEqual(result.state?.primaryResetObservation, abs(delta) <= 3 ? .stableObserved : .checking)
            XCTAssertEqual(result.state?.primaryResetEvidence != nil, abs(delta) <= 3)
        }
    }

    /// 3초 간격으로 3초씩 밀리는 미확인 시각은 허용 오차로 고정 처리하지 않는지 검증
    func testThreeSecondRollingWindowRemainsMoving() async {
        let fixture = StartupFixture()
        defer { fixture.cleanup() }
        let reset = fixture.start.addingTimeInterval(18_000)
        let result = await fixture.run(resets: [reset, reset.addingTimeInterval(3)], startup: true)
        XCTAssertEqual(result.calls, 2)
        XCTAssertEqual(result.state?.primaryResetObservation, .movingObserved)
        XCTAssertNil(result.state?.primaryResetEvidence)
    }

    /// c1처럼 경과 시간에 비례한 이동은 큰 변경 재조회 없이 미고정 유지 검증
    func testRollingUnexpiredCacheReadsOnceAndRemainsMoving() async {
        let fixture = StartupFixture()
        defer { fixture.cleanup() }
        let reset = fixture.start.addingTimeInterval(18_000)
        fixture.cache(reset: reset.addingTimeInterval(-30))
        let result = await fixture.run(resets: [reset], startup: true)
        XCTAssertEqual(result.calls, 1)
        XCTAssertEqual(result.state?.primaryResetObservation, .movingObserved)
        XCTAssertNil(result.state?.primaryResetEvidence)
    }

    /// 시작·주기 조회의 갑작스러운 큰 변경은 새 시각을 두 번째 조회로 검증
    func testLargeChangeIsRecheckedForStartupAndPeriodicRefresh() async {
        for startup in [false, true] {
            let fixture = StartupFixture()
            defer { fixture.cleanup() }
            fixture.cache(reset: fixture.start.addingTimeInterval(18_000))
            let reset = fixture.start.addingTimeInterval(7_200)
            let result = await fixture.run(resets: [reset, reset], startup: startup)
            XCTAssertEqual(result.calls, 2)
            XCTAssertEqual(fixture.delays, [3])
            XCTAssertEqual(result.state?.primaryResetEvidence?.resetAt, reset)
        }
    }

    /// 유효한 5시간 일정과 주간 일정의 최초 수신이 함께 확인되는지 검증
    func testNewSecondaryScheduleIsRecheckedWithValidPrimaryCache() async {
        for startup in [false, true] {
            let fixture = StartupFixture()
            defer { fixture.cleanup() }
            let primary = fixture.start.addingTimeInterval(18_000)
            let secondary = fixture.start.addingTimeInterval(604_800)
            fixture.cache(reset: primary)
            let result = await fixture.runSchedules(primary: [primary, primary], secondary: [secondary, secondary], startup: startup)
            XCTAssertEqual(result.calls, 2)
            XCTAssertEqual(fixture.delays, [3])
            XCTAssertEqual(result.state?.secondaryResetObservation, .stableObserved)
            XCTAssertNotNil(result.state?.secondaryResetEvidence)
            XCTAssertEqual(AccountDashboardFormatting.observedResetDate(
                result.state?.secondaryResetAt, observation: result.state?.secondaryResetObservation ?? .checking,
                status: result.state?.status ?? .error, now: fixture.start), secondary)
        }
    }

    /// 5시간 일정이 없어도 만료된 주간 일정의 갱신 재확인 검증
    func testExpiredSecondaryScheduleIsRechecked() async {
        let fixture = StartupFixture()
        defer { fixture.cleanup() }
        let expired = fixture.start.addingTimeInterval(-1)
        let refreshed = fixture.start.addingTimeInterval(604_800)
        fixture.cacheSecondary(reset: expired)
        let result = await fixture.runSchedules(primary: [nil, nil], secondary: [refreshed, refreshed], startup: false)
        XCTAssertEqual(result.calls, 2)
        XCTAssertEqual(fixture.delays, [3])
    }

    /// 유효 primary와 변경 없는 만료 secondary의 독립 재확인 검증
    func testExpiredSecondaryRechecksEvenWhenFirstResponseIsUnchanged() async {
        let fixture = StartupFixture()
        defer { fixture.cleanup() }
        let primary = fixture.start.addingTimeInterval(18_000)
        let expired = fixture.start.addingTimeInterval(-1)
        fixture.cacheSchedules(primary: primary, secondary: expired, lastUpdated: fixture.start.addingTimeInterval(-30))
        let result = await fixture.runSchedules(primary: [primary, primary], secondary: [expired, expired], startup: false)
        XCTAssertEqual(result.calls, 2)
        XCTAssertEqual(fixture.delays, [3])
    }

    /// reset 시각은 남았지만 timestamp 없는 캐시도 새 응답으로 재검증 확인
    func testScheduleWithMissingCacheTimestampIsRechecked() async {
        let fixture = StartupFixture()
        defer { fixture.cleanup() }
        let primary = fixture.start.addingTimeInterval(18_000)
        fixture.cacheSchedules(primary: primary, secondary: nil, lastUpdated: nil)
        let result = await fixture.runSchedules(primary: [primary, primary], secondary: [nil, nil], startup: false)
        XCTAssertEqual(result.calls, 2)
        XCTAssertEqual(fixture.delays, [3])
    }

    /// primary만 바뀔 때 secondary 날짜·근거·재확인 예약 유지 검증
    func testPrimaryOnlyVerificationPreservesSecondaryEvidenceAndReminder() async throws {
        let fixture = StartupFixture()
        defer { fixture.cleanup() }
        let primary = fixture.start.addingTimeInterval(18_000)
        let changedPrimary = primary.addingTimeInterval(1_800)
        let secondary = fixture.start.addingTimeInterval(604_800)
        fixture.cacheSchedules(primary: primary, secondary: secondary, evidence: true)
        var duringVerification: AccountState?
        var alerts: [QuotaResetAlert] = []
        let scheduler = QuotaResetScheduler(refresh: { _ in nil }, notify: { alerts.append($0) })
        let result = await fixture.runSchedules(primary: [changedPrimary, changedPrimary], secondary: [secondary, secondary],
            startup: false, duringSleep: { _, state in
                duringVerification = state
                scheduler.reconcile(states: [state], reminderMinutes: 5, now: fixture.start)
            })
        let interim = try XCTUnwrap(duringVerification)
        XCTAssertTrue(interim.isPrimaryResetVerificationPending)
        XCTAssertFalse(interim.isSecondaryResetVerificationPending)
        XCTAssertEqual(interim.primaryResetObservation, .checking)
        XCTAssertNil(interim.primaryResetEvidence)
        XCTAssertEqual(interim.secondaryResetObservation, .stableObserved)
        XCTAssertEqual(interim.secondaryResetEvidence?.resetAt, secondary)
        XCTAssertEqual(interim.secondaryResetAt, secondary)
        let state = try XCTUnwrap(result.state)
        XCTAssertEqual(state.secondaryResetObservation, .stableObserved)
        XCTAssertEqual(state.secondaryResetEvidence?.resetAt, secondary)
        XCTAssertEqual(AccountDashboardFormatting.observedResetDate(
            state.secondaryResetAt, observation: state.secondaryResetObservation, status: state.status, now: fixture.start
        ), secondary)
        XCTAssertEqual(state.secondaryResetSegmentID, interim.secondaryResetSegmentID)
        scheduler.reconcile(states: [state], reminderMinutes: 5, now: fixture.start)
        await scheduler.tick(now: secondary.addingTimeInterval(-5 * 60))
        let weeklyAlerts = alerts.filter { $0.body.contains("7일 할당량") }
        XCTAssertEqual(weeklyAlerts.count, 1)
    }

    /// secondary만 바뀔 때 primary 날짜·근거 및 양쪽 변경 시 대상 범위 검증
    func testSecondaryOnlyAndBothWindowVerificationsUseIndependentTargets() async throws {
        do {
            let fixture = StartupFixture()
            defer { fixture.cleanup() }
            let primary = fixture.start.addingTimeInterval(18_000)
            let secondary = fixture.start.addingTimeInterval(604_800)
            let changed = secondary.addingTimeInterval(3_600)
            fixture.cacheSchedules(primary: primary, secondary: secondary, evidence: true)
            var duringVerification: AccountState?
            let result = await fixture.runSchedules(primary: [primary, primary], secondary: [changed, changed],
                startup: false, duringSleep: { _, state in duringVerification = state })
            let interim = try XCTUnwrap(duringVerification)
            XCTAssertFalse(interim.isPrimaryResetVerificationPending)
            XCTAssertTrue(interim.isSecondaryResetVerificationPending)
            XCTAssertEqual(interim.primaryResetObservation, .stableObserved)
            XCTAssertEqual(interim.primaryResetEvidence?.resetAt, primary)
            XCTAssertEqual(result.state?.primaryResetAt, primary)
            XCTAssertEqual(result.state?.primaryResetEvidence?.resetAt, primary)
        }
        do {
            let fixture = StartupFixture()
            defer { fixture.cleanup() }
            let primary = fixture.start.addingTimeInterval(18_000)
            let secondary = fixture.start.addingTimeInterval(604_800)
            fixture.cacheSchedules(primary: primary, secondary: secondary, evidence: true)
            var duringVerification: AccountState?
            let result = await fixture.runSchedules(primary: [primary.addingTimeInterval(1_800), primary.addingTimeInterval(1_800)],
                secondary: [secondary.addingTimeInterval(3_600), secondary.addingTimeInterval(3_600)],
                startup: false, duringSleep: { _, state in duringVerification = state })
            let interim = try XCTUnwrap(duringVerification)
            XCTAssertTrue(interim.isPrimaryResetVerificationPending)
            XCTAssertTrue(interim.isSecondaryResetVerificationPending)
            XCTAssertEqual(interim.primaryResetObservation, .checking)
            XCTAssertEqual(interim.secondaryResetObservation, .checking)
            XCTAssertEqual(result.state?.primaryResetObservation, .stableObserved)
            XCTAssertEqual(result.state?.secondaryResetObservation, .stableObserved)
        }
    }

    /// primary 재확인 2차 실패 후 secondary 고정 근거와 진행 상태 유지 검증
    func testPrimaryVerificationFailurePreservesSecondaryEvidence() async {
        let fixture = StartupFixture()
        defer { fixture.cleanup() }
        let primary = fixture.start.addingTimeInterval(18_000)
        let changed = primary.addingTimeInterval(1_800)
        let secondary = fixture.start.addingTimeInterval(604_800)
        fixture.cacheSchedules(primary: primary, secondary: secondary, evidence: true)
        let result = await fixture.runSchedules(primary: [changed, changed], secondary: [secondary, secondary],
            startup: false, statuses: [.normal, .timeout])
        XCTAssertEqual(result.calls, 2)
        XCTAssertEqual(result.state?.status, .timeout)
        XCTAssertFalse(result.state?.isPrimaryResetVerificationPending ?? true)
        XCTAssertFalse(result.state?.isSecondaryResetVerificationPending ?? true)
        XCTAssertNil(result.state?.primaryResetEvidence)
        XCTAssertEqual(result.state?.secondaryResetObservation, .stableObserved)
        XCTAssertEqual(result.state?.secondaryResetEvidence?.resetAt, secondary)
    }

    /// primary 범위 완료가 2차 조회에서 변한 secondary 근거를 덮지 않는지 검증
    func testPrimaryFinishLeavesUnrequestedSecondaryChangesUntouched() async throws {
        let fixture = StartupFixture()
        defer { fixture.cleanup() }
        let primary = fixture.start.addingTimeInterval(18_000)
        let firstPrimary = primary.addingTimeInterval(1_800)
        let secondary = fixture.start.addingTimeInterval(604_800)
        let secondSecondary = secondary.addingTimeInterval(3_600)
        fixture.cacheSchedules(primary: primary, secondary: secondary, evidence: true)
        let source = StartupSource(states: [
            AccountState(id: "C1", email: "fixture@example.invalid", planType: "plus",
                primaryResetAt: firstPrimary, secondaryResetAt: secondary,
                lastUpdated: fixture.start, status: .normal),
            AccountState(id: "C1", email: "fixture@example.invalid", planType: "plus",
                primaryResetAt: firstPrimary, secondaryResetAt: secondSecondary,
                lastUpdated: fixture.start.addingTimeInterval(3), status: .normal)
        ])
        let store = AccountStore(configs: fixture.configs, preferencesStore: fixture.preferences) { _ in await source.read() }
        store.observationNow = { fixture.start }
        store.observationUptime = { fixture.elapsed }
        _ = await store.refreshOutcome(accountID: "C1", forceFresh: true)
        let first = try XCTUnwrap(store.state(for: "C1"))
        store.beginResetVerification(expected: first, windows: [.primary])
        _ = await store.refreshOutcome(accountID: "C1", forceFresh: true)
        let second = try XCTUnwrap(store.state(for: "C1"))
        let secondaryStateBeforeFinish = (
            second.secondaryResetAt, second.secondaryResetObservation, second.secondaryResetEvidence,
            second.secondaryResetSegmentID,
            AccountDashboardFormatting.observedResetDate(second.secondaryResetAt,
                observation: second.secondaryResetObservation, status: second.status, now: fixture.start)
        )
        store.finishResetVerification(expected: second, comparedTo: first, windows: [.primary])
        let finished = try XCTUnwrap(store.state(for: "C1"))
        XCTAssertEqual(finished.secondaryResetAt, secondaryStateBeforeFinish.0)
        XCTAssertEqual(finished.secondaryResetObservation, secondaryStateBeforeFinish.1)
        XCTAssertEqual(finished.secondaryResetEvidence, secondaryStateBeforeFinish.2)
        XCTAssertEqual(finished.secondaryResetSegmentID, secondaryStateBeforeFinish.3)
        XCTAssertEqual(AccountDashboardFormatting.observedResetDate(finished.secondaryResetAt,
            observation: finished.secondaryResetObservation, status: finished.status, now: fixture.start), secondaryStateBeforeFinish.4)
    }

    /// primary 재확인 대기 취소 후 secondary의 날짜와 근거 유지 검증
    func testCancellingPrimaryVerificationPreservesSecondaryEvidence() async throws {
        let fixture = StartupFixture()
        defer { fixture.cleanup() }
        let primary = fixture.start.addingTimeInterval(18_000)
        let changed = primary.addingTimeInterval(1_800)
        let secondary = fixture.start.addingTimeInterval(604_800)
        fixture.cacheSchedules(primary: primary, secondary: secondary, evidence: true)
        var sleeping = false
        var duringVerification: AccountState?
        let task = Task {
            await fixture.runSchedules(primary: [changed, changed], secondary: [secondary, secondary],
                startup: false, duringSleep: { _, state in duringVerification = state }, sleep: { _ in
                    sleeping = true
                    try await Task.sleep(for: .seconds(60))
                })
        }
        for _ in 0..<10_000 where !sleeping { await Task.yield() }
        XCTAssertTrue(sleeping)
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.calls, 1)
        let interim = try XCTUnwrap(duringVerification)
        XCTAssertTrue(interim.isPrimaryResetVerificationPending)
        XCTAssertEqual(interim.secondaryResetObservation, .stableObserved)
        XCTAssertEqual(interim.secondaryResetEvidence?.resetAt, secondary)
        XCTAssertFalse(result.state?.isPrimaryResetVerificationPending ?? true)
        XCTAssertEqual(result.state?.secondaryResetEvidence?.resetAt, secondary)
    }

    /// 재확인 대기 중 계정 경로 교체 시 이전 계정 pending 상태 미반영 검증
    func testAccountReplacementDuringVerificationDoesNotMutateNewSlot() async throws {
        let fixture = StartupFixture()
        defer { fixture.cleanup() }
        let primary = fixture.start.addingTimeInterval(18_000)
        let changed = primary.addingTimeInterval(1_800)
        let secondary = fixture.start.addingTimeInterval(604_800)
        fixture.cacheSchedules(primary: primary, secondary: secondary, evidence: true)
        var replacement: AccountState?
        let result = await fixture.runSchedules(primary: [changed, changed], secondary: [secondary, secondary],
            startup: false, duringSleep: { store, _ in
                var configs = fixture.configs
                configs[0] = AccountConfig(id: "C1", home: fixture.root.appendingPathComponent("new-c1"), position: .left)
                store.reconfigure(configs)
                replacement = store.state(for: "C1")
            })
        XCTAssertEqual(result.calls, 1)
        let state = try XCTUnwrap(replacement)
        XCTAssertEqual(state.configurationGeneration, 1)
        XCTAssertFalse(state.isResetVerificationPending)
        XCTAssertTrue(state.isWaitingForRefresh)
    }

    /// 재확인 중 별도 정상 조회가 새 스냅샷을 적용하면 이전 pending 미이월 검증
    func testSuccessfulConcurrentRefreshDoesNotInheritStaleVerificationPending() async {
        let fixture = StartupFixture()
        defer { fixture.cleanup() }
        let primary = fixture.start.addingTimeInterval(18_000)
        let changed = primary.addingTimeInterval(1_800)
        let secondary = fixture.start.addingTimeInterval(604_800)
        fixture.cacheSchedules(primary: primary, secondary: secondary, evidence: true)
        let source = StartupSource(states: [
            AccountState(id: "C1", email: "fixture@example.invalid", planType: "plus",
                primaryResetAt: changed, secondaryResetAt: secondary,
                lastUpdated: fixture.start, status: .normal),
            AccountState(id: "C1", email: "fixture@example.invalid", planType: "plus",
                primaryResetAt: changed, secondaryResetAt: secondary,
                lastUpdated: fixture.start.addingTimeInterval(3), status: .normal)
        ])
        let store = AccountStore(configs: fixture.configs, preferencesStore: fixture.preferences) { _ in await source.read() }
        store.observationNow = { fixture.start.addingTimeInterval(fixture.elapsed) }
        store.observationUptime = { fixture.elapsed }
        var concurrentResult: AccountStore.RefreshOutcome?
        let coordinator = QuotaRefreshCoordinator(store: store, now: { fixture.start.addingTimeInterval(fixture.elapsed) },
            sleep: { seconds in
                fixture.elapsed += seconds
                concurrentResult = await store.refreshOutcome(accountID: "C1", forceFresh: true)
            })
        await coordinator.refresh(accountID: "C1")
        XCTAssertTrue(concurrentResult?.isSuccess == true)
        let state = store.state(for: "C1")
        XCTAssertEqual(state?.lastUpdated, fixture.start.addingTimeInterval(3))
        XCTAssertFalse(state?.isResetVerificationPending ?? true)
    }

    /// 한도별 단독 제공과 양쪽 누락에서 불필요한 반복 재확인 제외 검증
    func testSingleWindowCachesAndMissingWindowsDoNotCauseRepeatedReads() async {
        let primary = Date().addingTimeInterval(18_000)
        let secondary = Date().addingTimeInterval(604_800)
        do {
            let fixture = StartupFixture()
            defer { fixture.cleanup() }
            fixture.cacheSecondary(reset: secondary)
            let result = await fixture.runSchedules(primary: [nil], secondary: [secondary], startup: false)
            XCTAssertEqual(result.calls, 1)
            XCTAssertEqual(fixture.delays, [])
        }
        do {
            let fixture = StartupFixture()
            defer { fixture.cleanup() }
            fixture.cache(reset: primary)
            let result = await fixture.runSchedules(primary: [primary], secondary: [nil], startup: false)
            XCTAssertEqual(result.calls, 1)
            XCTAssertEqual(fixture.delays, [])
        }
        do {
            let fixture = StartupFixture()
            defer { fixture.cleanup() }
            let result = await fixture.runSchedules(primary: [nil], secondary: [nil], startup: false)
            XCTAssertEqual(result.calls, 1)
            XCTAssertEqual(fixture.delays, [])
        }
    }

    /// OFF 선택 저장·재실행 복원과 ON 복구의 콜백 연결 검증
    func testAutomaticRefreshChoicePersistsAndNotifies() {
        let fixture = StartupFixture()
        defer { fixture.cleanup() }
        var changes: [Bool] = []
        fixture.preferences.onAutomaticRefreshChanged = { changes.append($0) }
        XCTAssertTrue(fixture.preferences.automaticRefreshEnabled)
        fixture.preferences.updateAutomaticRefresh(false)
        let reloaded = PreferencesStore(userDefaults: fixture.defaults,
            defaultPaths: fixture.configs.map { $0.home.path }, quotaDatabaseURL: fixture.database)
        XCTAssertFalse(reloaded.automaticRefreshEnabled)
        fixture.preferences.updateAutomaticRefresh(true)
        XCTAssertEqual(changes, [false, true])
    }
}

/// 주기 서비스에서 발생한 실제 모의 조회 횟수 기록
private actor MonitoringCountSource {
    let reset: Date
    private(set) var calls = 0

    /// 고정된 서버 초기화 시각 지정
    init(reset: Date) { self.reset = reset }

    /// 네트워크 없이 최신 정상 시각 반환
    func read() -> AccountState {
        calls += 1
        return AccountState(id: "C1", email: "fixture@example.invalid", planType: "plus",
            primaryResetAt: reset, lastUpdated: Date(), status: .normal)
    }
}

/// 캐시의 생성 시점과 실제 조회 시점 차이를 보장하는 테스트 경계
@MainActor
private final class StartupFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let start = Date().addingTimeInterval(-60)
    let defaults = UserDefaults(suiteName: "CodexQuotaMonitorTests.\(UUID().uuidString)")!
    var delays: [TimeInterval] = []
    var elapsed: TimeInterval = 0
    var database: URL { root.appendingPathComponent("quota.sqlite") }
    lazy var configs = AccountConfig.accounts(for: [root.appendingPathComponent("c1").path, "", "", ""])
    lazy var preferences = PreferencesStore(userDefaults: defaults, defaultPaths: configs.map { $0.home.path }, quotaDatabaseURL: database)

    /// 조회보다 30초 전의 이전 정상 캐시 생성
    func cache(reset: Date, evidence: Bool = false) {
        preferences.updateQuotaSnapshot(for: configs[0].home, snapshot: .init(
            usedPercent: 0, resetAt: reset, lastUpdated: start.addingTimeInterval(-30),
            email: "fixture@example.invalid", planType: "plus",
            primaryResetEvidence: evidence ? ResetTimeEvidence(resetAt: reset, observedAt: start.addingTimeInterval(-30)) : nil))
    }

    /// 주간 일정만 포함한 캐시 생성
    func cacheSecondary(reset: Date) {
        preferences.updateQuotaSnapshot(for: configs[0].home, snapshot: .init(
            secondaryUsedPercent: 20, secondaryResetAt: reset,
            lastUpdated: start.addingTimeInterval(-30), email: "fixture@example.invalid", planType: "plus"))
    }

    /// 선택된 한도 시각과 캐시 갱신 시각 생성
    func cacheSchedules(primary: Date?, secondary: Date?, lastUpdated: Date?) {
        preferences.updateQuotaSnapshot(for: configs[0].home, snapshot: .init(
            resetAt: primary, secondaryResetAt: secondary,
            lastUpdated: lastUpdated,
            email: "fixture@example.invalid", planType: "plus"))
    }

    /// 양쪽 고정 근거가 포함된 캐시 생성
    func cacheSchedules(primary: Date?, secondary: Date?, evidence: Bool) {
        let observedAt = start.addingTimeInterval(-30)
        preferences.updateQuotaSnapshot(for: configs[0].home, snapshot: .init(
            resetAt: primary, secondaryResetAt: secondary, lastUpdated: observedAt,
            email: "fixture@example.invalid", planType: "plus",
            primaryResetEvidence: evidence ? primary.map { ResetTimeEvidence(resetAt: $0, observedAt: observedAt) } : nil,
            secondaryResetEvidence: evidence ? secondary.map { ResetTimeEvidence(resetAt: $0, observedAt: observedAt) } : nil))
    }

    /// 지정 시각을 반환하는 모의 계정 조회와 3초 가상 대기 수행
    func run(resets: [Date], startup: Bool) async -> (calls: Int, state: AccountState?) {
        let states = resets.enumerated().map { index, reset in
            AccountState(id: "C1", email: "fixture@example.invalid", planType: "plus", primaryResetAt: reset,
                lastUpdated: start.addingTimeInterval(Double(index) * 3), status: .normal)
        }
        let source = StartupSource(states: states)
        let store = AccountStore(configs: configs, preferencesStore: preferences) { _ in await source.read() }
        store.observationNow = { self.start.addingTimeInterval(self.elapsed) }
        store.observationUptime = { self.elapsed }
        let coordinator = QuotaRefreshCoordinator(store: store,
            now: { self.start.addingTimeInterval(self.elapsed) }, sleep: { seconds in
                self.delays.append(seconds)
                self.elapsed += seconds
            })
        await coordinator.refresh(accountID: "C1", startup: startup)
        return (await source.calls, store.state(for: "C1"))
    }

    /// 두 한도의 시각 응답과 가상 3초 대기 수행
    func runSchedules(
        primary: [Date?], secondary: [Date?], startup: Bool,
        statuses: [AccountStatus]? = nil,
        duringSleep: ((AccountStore, AccountState) -> Void)? = nil,
        sleep: ((TimeInterval) async throws -> Void)? = nil
    ) async -> (calls: Int, state: AccountState?) {
        let states = primary.indices.map { index in
            AccountState(id: "C1", email: "fixture@example.invalid", planType: "plus",
                primaryResetAt: primary[index], secondaryResetAt: secondary[index],
                lastUpdated: start.addingTimeInterval(Double(index) * 3), status: statuses?[index] ?? .normal)
        }
        let source = StartupSource(states: states)
        let store = AccountStore(configs: configs, preferencesStore: preferences) { _ in await source.read() }
        store.observationNow = { self.start.addingTimeInterval(self.elapsed) }
        store.observationUptime = { self.elapsed }
        let coordinator = QuotaRefreshCoordinator(store: store,
            now: { self.start.addingTimeInterval(self.elapsed) }, sleep: { seconds in
                self.delays.append(seconds)
                if let state = store.state(for: "C1") { duringSleep?(store, state) }
                if let sleep { try await sleep(seconds) }
                else { self.elapsed += seconds }
            })
        await coordinator.refresh(accountID: "C1", startup: startup)
        return (await source.calls, store.state(for: "C1"))
    }

    /// 임시 캐시 파일 정리
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

/// 실계정 조회를 대체하는 순차 응답과 호출 횟수 기록
private actor StartupSource {
    private var states: [AccountState]
    private(set) var calls = 0

    /// 정상 조회 응답 지정
    init(states: [AccountState]) { self.states = states }

    /// 다음 응답 반환 및 예기치 않은 추가 조회 검출
    func read() -> AccountState {
        calls += 1
        guard !states.isEmpty else { XCTFail("예상 횟수 초과 조회"); return AccountState(id: "C1", status: .error) }
        return states.removeFirst()
    }
}
