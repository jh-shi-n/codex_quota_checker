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

    /// 저장된 고정 근거는 양방향 3초까지 유지, 초과 변경은 폐기 검증
    func testKnownFixedTimeToleratesThreeSecondsButNotMore() async {
        for delta in [-3.001, -3.0, -2, -1, 1, 2, 3, 3.001] {
            let fixture = StartupFixture()
            defer { fixture.cleanup() }
            let reset = fixture.start.addingTimeInterval(18_000)
            fixture.cache(reset: reset, evidence: true)
            let result = await fixture.run(resets: [reset.addingTimeInterval(delta)], startup: true)
            XCTAssertEqual(result.calls, 1)
            XCTAssertEqual(result.state?.primaryResetObservation, abs(delta) <= 3 ? .stableObserved : .movingObserved)
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
