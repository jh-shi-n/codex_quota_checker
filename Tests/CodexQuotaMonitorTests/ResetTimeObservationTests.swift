// 목적: 초기화 시각 관측과 계정 상태 반영의 회귀 검증
// 이용처: Swift 테스트 통합 실행
// 사용방법: swift test
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 추가 서버 조회 없이 수행하는 관측 판정과 표시 검증
@MainActor
final class ResetTimeObservationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// 60초 이내 이동 후 고정 응답이 기존 변동 판정을 해제하는지 검증
    func testMovingObservationSettlesWithinTenSeconds() {
        var tracker = ResetTimeTracker()
        for elapsed in [0.0, 10, 20] {
            _ = tracker.observe(resetAt: start.addingTimeInterval(18_000 + elapsed),
                                observedAt: start.addingTimeInterval(elapsed), uptime: elapsed)
        }
        XCTAssertEqual(tracker.observation, .movingObserved)
        XCTAssertEqual(tracker.observe(resetAt: start.addingTimeInterval(18_020),
            observedAt: start.addingTimeInterval(30), uptime: 30), .stableObserved)
    }

    /// 최소 간격·허용 오차 경계와 큰 변경의 구간 재설정 검증
    func testMinimumIntervalAndToleranceBoundaries() {
        for delta in [2.0, 2.001] {
            var tracker = ResetTimeTracker()
            let segment = tracker.segmentID
            XCTAssertEqual(tracker.observe(resetAt: start.addingTimeInterval(18_000), observedAt: start, uptime: 0), .checking)
            XCTAssertEqual(tracker.observe(resetAt: start.addingTimeInterval(18_000),
                observedAt: start.addingTimeInterval(9.999), uptime: 9.999), .checking)
            XCTAssertEqual(tracker.observe(resetAt: start.addingTimeInterval(18_000 + delta),
                observedAt: start.addingTimeInterval(10), uptime: 10), delta == 2 ? .stableObserved : .checking)
            XCTAssertEqual(tracker.segmentID == segment, delta == 2)
        }
    }

    /// 1초 잡음이 있는 고정 시각과 이동 시각의 독립 판정 검증
    func testFirstReadingAcceptsResetAndLaterReadingsDetectMovement() {
        var stable = ResetTimeTracker()
        var moving = ResetTimeTracker()
        for (index, elapsed) in [0.0, 300, 600].enumerated() {
            let expected: ResetTimeObservation = index == 0 ? .checking : .stableObserved
            XCTAssertEqual(stable.observe(
                resetAt: start.addingTimeInterval(18_000 + (index == 1 ? 1 : 0)),
                observedAt: start.addingTimeInterval(elapsed), uptime: elapsed
            ), expected)
            XCTAssertEqual(moving.observe(
                resetAt: start.addingTimeInterval(604_800 + elapsed),
                observedAt: start.addingTimeInterval(elapsed), uptime: elapsed
            ), index == 2 ? .movingObserved : .checking)
        }
    }

    /// 연속 수동 조회와 작은 시각 변경의 즉시 반영 검증
    func testRapidReadsAndSmallChangesAcceptLatestReset() {
        var tracker = ResetTimeTracker()
        for elapsed in [0.0, 1, 2, 3] {
            XCTAssertEqual(tracker.observe(
                resetAt: start.addingTimeInterval(18_000),
                observedAt: start.addingTimeInterval(elapsed), uptime: elapsed
            ), .checking)
        }
        tracker = ResetTimeTracker()
        for index in 0..<3 {
            XCTAssertEqual(tracker.observe(
                resetAt: start.addingTimeInterval(18_000 + Double(index * 2)),
                observedAt: start.addingTimeInterval(Double(index * 300)), uptime: Double(index * 300)
            ), index == 0 ? .checking : .stableObserved)
        }
    }

    /// 누락·만료 제외 및 시계 변경·긴 공백 이후 첫 유효 시각 반영 검증
    func testInvalidBoundariesAndClockChangesRestartObservation() {
        let cases: [(Date?, Double, Double, ResetTimeObservation)] = [
            (nil, 900, 900, .checking),
            (start.addingTimeInterval(900), 900, 900, .checking),
            (start.addingTimeInterval(18_000), 900, 905, .checking),
            (start.addingTimeInterval(18_000), 2_000, 2_000, .checking),
            (start.addingTimeInterval(18_000), 600, 900, .stableObserved),
            (Date(timeIntervalSince1970: .infinity), 900, 900, .checking),
        ]
        for (reset, elapsed, uptime, expected) in cases {
            var tracker = stableTracker()
            XCTAssertEqual(tracker.observe(
                resetAt: reset, observedAt: start.addingTimeInterval(elapsed), uptime: uptime
            ), expected)
        }
        var tracker = stableTracker()
        XCTAssertEqual(tracker.observe(
            resetAt: start.addingTimeInterval(25_000),
            observedAt: start.addingTimeInterval(900), uptime: 900
        ), .checking)
    }

    /// 이동 이후 첫 고정 시각 조회로 표시 복귀 검증
    func testMovingToStableAcceptsFirstFixedReading() {
        var tracker = ResetTimeTracker()
        for elapsed in [0.0, 300, 600] {
            _ = tracker.observe(resetAt: start.addingTimeInterval(18_000 + elapsed),
                                observedAt: start.addingTimeInterval(elapsed), uptime: elapsed)
        }
        XCTAssertEqual(tracker.observation, .movingObserved)
        for elapsed in [900.0, 1_200] {
            let result = tracker.observe(resetAt: start.addingTimeInterval(18_600),
                                         observedAt: start.addingTimeInterval(elapsed), uptime: elapsed)
            XCTAssertEqual(result, .stableObserved)
        }
    }

    /// 계정별·구간별 분리, 실패 표시 보존, 재관측 및 계정·경로 변경 검증
    func testAccountStoreSeparatesWindowsAndRestartsAfterFailureOrIdentityChange() async {
        let suite = "ResetTimeObservationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = ResetObservationTestClock(now: start)
        let source = ResetObservationSource()
        let configs = AccountConfig.accounts(for: ["/tmp/reset-observation-c1", "", "", ""])
        let store = AccountStore(
            configs: configs, preferencesStore: PreferencesStore(userDefaults: defaults),
            stateLoader: { config in await source.read(id: config.id) }
        )
        store.observationNow = { clock.now }
        store.observationUptime = { clock.uptime }
        for elapsed in [0.0, 300, 600] {
            clock.now = start.addingTimeInterval(elapsed)
            clock.uptime = elapsed
            await source.set(AccountState(
                id: "C1", email: "first@example.test", planType: "plus",
                primaryResetAt: start.addingTimeInterval(18_000),
                secondaryResetAt: clock.now.addingTimeInterval(604_800), lastUpdated: clock.now, status: .normal
            ))
            await store.refresh(accountID: "C1")
            XCTAssertEqual(store.state(for: "C1")?.primaryResetObservation, elapsed == 0 ? .checking : .stableObserved)
            if elapsed == 0 {
                XCTAssertEqual(store.state(for: "C1")?.secondaryResetObservation, .checking)
                XCTAssertNil(AccountDashboardFormatting.fiveHourResetNotice(for: store.state(for: "C1")!, now: clock.now))
            }
        }
        XCTAssertEqual(store.state(for: "C1")?.primaryResetObservation, .stableObserved)
        XCTAssertEqual(store.state(for: "C1")?.secondaryResetObservation, .movingObserved)
        XCTAssertEqual(store.state(for: "C2")?.primaryResetObservation, .checking)

        await source.set(AccountState(id: "C1", status: .timeout))
        await store.refresh(accountID: "C1")
        XCTAssertEqual(store.state(for: "C1")?.primaryResetObservation, .stableObserved)
        XCTAssertEqual(store.state(for: "C1")?.lastUpdated, clock.now)
        clock.now = start.addingTimeInterval(900)
        clock.uptime = 900
        await source.set(AccountState(id: "C1", email: "first@example.test", planType: "plus",
                                      primaryResetAt: start.addingTimeInterval(18_000),
                                      lastUpdated: clock.now, status: .normal))
        await store.refresh(accountID: "C1")
        XCTAssertEqual(store.state(for: "C1")?.primaryResetObservation, .checking)
        for elapsed in [1_200.0, 1_500] {
            clock.now = start.addingTimeInterval(elapsed)
            clock.uptime = elapsed
            await source.set(AccountState(id: "C1", email: "first@example.test", planType: "plus",
                                          primaryResetAt: start.addingTimeInterval(18_000),
                                          lastUpdated: clock.now, status: .normal))
            await store.refresh(accountID: "C1")
        }
        XCTAssertEqual(store.state(for: "C1")?.primaryResetObservation, .stableObserved)
        clock.now = start.addingTimeInterval(1_800)
        clock.uptime = 1_800
        await source.set(AccountState(id: "C1", email: "second@example.test", planType: "plus",
                                      primaryResetAt: start.addingTimeInterval(18_000),
                                      lastUpdated: clock.now, status: .normal))
        await store.refresh(accountID: "C1")
        XCTAssertEqual(store.state(for: "C1")?.primaryResetObservation, .checking)
        store.reconfigure(pathStrings: ["/tmp/reset-observation-new", "", "", ""])
        XCTAssertEqual(store.state(for: "C1")?.primaryResetObservation, .checking)
        await store.refresh(accountID: "C1")
        XCTAssertEqual(store.state(for: "C1")?.primaryResetObservation, .checking)
    }

    /// 영속 복원 시 이전 실행의 관측 상태를 재사용하지 않는지 검증
    func testObservationIsNotPersisted() throws {
        var state = AccountState(id: "C1", primaryResetAt: start.addingTimeInterval(18_000), status: .normal)
        state.primaryResetObservation = .stableObserved
        state.primaryResetSegmentID = UUID()
        let restored = try JSONDecoder().decode(AccountState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.primaryResetObservation, .checking)
        XCTAssertNil(restored.primaryResetSegmentID)
    }

    /// 고정 시각 3회 관측 fixture 구성
    private func stableTracker() -> ResetTimeTracker {
        var tracker = ResetTimeTracker()
        for elapsed in [0.0, 300, 600] {
            _ = tracker.observe(resetAt: start.addingTimeInterval(18_000),
                                observedAt: start.addingTimeInterval(elapsed), uptime: elapsed)
        }
        return tracker
    }
}

/// 계정 저장소의 정상·실패 스냅샷을 순서대로 주입하는 격리 fixture
private actor ResetObservationSource {
    private var state = AccountState(id: "C1", status: .loading)

    /// 다음 조회에서 반환할 스냅샷 교체
    func set(_ state: AccountState) { self.state = state }

    /// 요청 계정의 스냅샷 반환
    func read(id: String) -> AccountState { state }
}

/// 메인 액터에서 테스트 관측 시각을 함께 이동시키는 시계 fixture
@MainActor
private final class ResetObservationTestClock {
    var now: Date
    var uptime: TimeInterval = 0

    /// 테스트 시작 시각 지정
    init(now: Date) { self.now = now }
}
