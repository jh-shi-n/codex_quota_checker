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

    /// 10초 대기 없이 연속 요청의 마지막 정상 시각을 기준으로 고정 판정 검증
    func testRapidRequestsUseLatestObservation() {
        var tracker = ResetTimeTracker()
        for (elapsed, delta, expected) in [(0.0, 0.0, ResetTimeObservation.checking),
                                          (1, 1, .checking), (2, 1, .stableObserved)] {
            XCTAssertEqual(tracker.observe(resetAt: start.addingTimeInterval(18_000 + delta),
                observedAt: start.addingTimeInterval(elapsed), uptime: elapsed), expected)
        }
    }

    /// 빠른 조회의 비례 이동과 작은 고정 시각 잡음 혼동 방지 검증
    func testRapidMovementAndFixedJitterAreDistinct() {
        var moving = ResetTimeTracker()
        var fixed = ResetTimeTracker()
        for elapsed in [0.0, 1, 2] {
            _ = moving.observe(resetAt: start.addingTimeInterval(18_000 + elapsed),
                observedAt: start.addingTimeInterval(elapsed), uptime: elapsed)
            _ = fixed.observe(resetAt: start.addingTimeInterval(18_000 + (elapsed == 1 ? 1 : 0)),
                observedAt: start.addingTimeInterval(elapsed), uptime: elapsed)
        }
        XCTAssertEqual(moving.observation, .movingObserved)
        XCTAssertEqual(fixed.observation, .stableObserved)
        XCTAssertEqual(fixed.observe(resetAt: start.addingTimeInterval(18_000),
            observedAt: start.addingTimeInterval(3), uptime: 3), .stableObserved)
    }

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

    /// 허용 오차 경계와 큰 변경의 구간 재설정 검증
    func testToleranceBoundaries() {
        for delta in [3.0, 3.001] {
            var tracker = ResetTimeTracker()
            let segment = tracker.segmentID
            XCTAssertEqual(tracker.observe(resetAt: start.addingTimeInterval(18_000), observedAt: start, uptime: 0), .checking)
            XCTAssertEqual(tracker.observe(resetAt: start.addingTimeInterval(18_000 + delta),
                observedAt: start.addingTimeInterval(10), uptime: 10), delta == 3 ? .stableObserved : .checking)
            XCTAssertEqual(tracker.segmentID == segment, delta == 3)
        }
    }

    /// primary·secondary 단발 ±20초 보정을 이동으로 오인하지 않는지 검증
    func testSingleTwentySecondCorrectionRemainsChecking() async {
        for primary in [true, false] {
            for delta in [-20.0, 20.0] {
                let originalPrimary = start.addingTimeInterval(18_000)
                let originalSecondary = start.addingTimeInterval(604_800)
                let prior = AccountState(id: "C1", email: "fixture@example.test", planType: "plus",
                    primaryResetAt: originalPrimary, secondaryResetAt: originalSecondary,
                    lastUpdated: start.addingTimeInterval(-30), status: .normal)
                var current = prior
                current.lastUpdated = start
                if primary { current.primaryResetAt = originalPrimary.addingTimeInterval(delta) }
                else { current.secondaryResetAt = originalSecondary.addingTimeInterval(delta) }
                let state = await finishVerification(prior: prior, current: current)
                let observation = primary ? state?.primaryResetObservation : state?.secondaryResetObservation
                let reset = primary ? state?.primaryResetAt : state?.secondaryResetAt
                let evidence = primary ? state?.primaryResetEvidence : state?.secondaryResetEvidence
                XCTAssertEqual(observation, .checking)
                XCTAssertNil(evidence)
                XCTAssertEqual(AccountDashboardFormatting.resetScheduleStatusText(
                    reset, observation: observation ?? .stableObserved, status: .normal, now: start
                ), "초기화 시각 확인 중")
            }
        }
    }

    /// 단발 보정 뒤 동일한 후속 관측으로 고정 근거 복구 검증
    func testSingleCorrectionCanRecoverOnFollowUpFixedReading() async throws {
        let original = start.addingTimeInterval(18_000)
        let prior = AccountState(id: "C1", email: "fixture@example.test", planType: "plus",
            primaryResetAt: original, lastUpdated: start.addingTimeInterval(-30), status: .normal)
        let correction = AccountState(id: "C1", email: "fixture@example.test", planType: "plus",
            primaryResetAt: original.addingTimeInterval(20), lastUpdated: start, status: .normal)
        let firstResult = await finishVerification(prior: prior, current: correction)
        let first = try XCTUnwrap(firstResult)
        XCTAssertEqual(first.primaryResetObservation, .checking)
        let repeated = AccountState(id: "C1", email: "fixture@example.test", planType: "plus",
            primaryResetAt: correction.primaryResetAt, lastUpdated: start.addingTimeInterval(3), status: .normal)
        let recovered = await finishVerification(prior: first, current: repeated)
        XCTAssertEqual(recovered?.primaryResetObservation, .stableObserved)
        XCTAssertEqual(recovered?.primaryResetEvidence?.resetAt, correction.primaryResetAt)
        let observedAt = try XCTUnwrap(repeated.lastUpdated)
        XCTAssertTrue(recovered?.primaryResetEvidence?.matches(correction.primaryResetAt, now: observedAt) == true)
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
            ), elapsed == 0 ? .checking : .stableObserved)
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

    /// 한도별 분리·일시 실패 뒤 동일 시각 유지·계정과 경로 변경 시 폐기 검증
    func testAccountStoreRetainsEvidenceAfterFailureAndDiscardsItOnIdentityChange() async {
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
        XCTAssertEqual(store.state(for: "C1")?.primaryResetObservation, .stableObserved)
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

    /// 별도 저장 근거 없는 AccountState 직렬화의 관측 구간 재사용 차단 검증
    func testObservationIsNotPersisted() throws {
        var state = AccountState(id: "C1", primaryResetAt: start.addingTimeInterval(18_000), status: .normal)
        state.primaryResetObservation = .stableObserved
        state.primaryResetSegmentID = UUID()
        state.isPrimaryResetVerificationPending = true
        let restored = try JSONDecoder().decode(AccountState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.primaryResetObservation, .checking)
        XCTAssertNil(restored.primaryResetSegmentID)
        XCTAssertFalse(restored.isResetVerificationPending)
    }

    /// 격리 계정 저장소로 조회·검증 결과 반영
    private func finishVerification(prior: AccountState, current: AccountState) async -> AccountState? {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ResetTimeObservationTests.Finish.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let configs = AccountConfig.accounts(for: [root.appendingPathComponent("c1").path, "", "", ""])
        let preferences = PreferencesStore(userDefaults: defaults,
            defaultPaths: configs.map { $0.home.path }, quotaDatabaseURL: root.appendingPathComponent("quota.sqlite"))
        let store = AccountStore(configs: configs, preferencesStore: preferences) { _ in current }
        let observedAt = current.lastUpdated ?? start
        let uptime = current.lastUpdated.flatMap { latest in
            prior.lastUpdated.map { latest.timeIntervalSince($0) }
        } ?? 0
        store.observationNow = { observedAt }
        store.observationUptime = { uptime }
        _ = await store.refreshOutcome(accountID: "C1", forceFresh: true)
        guard let expected = store.state(for: "C1") else { return nil }
        store.finishResetVerification(expected: expected, comparedTo: prior)
        return store.state(for: "C1")
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
