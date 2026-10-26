// 목적: Ping 후 조회의 고정·이동·실패·중복·계정 격리 검증
// 이용처: 수동·자동 공통 확인 서비스 회귀 테스트
// 사용방법: swift test --filter ResetTimeConfirmationTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 실제 대기·전송 없이 관측 추적기를 사용하는 후속 조회 검증
@MainActor
final class ResetTimeConfirmationTests: XCTestCase {
    /// 재시작 캐시에 로그인 정보가 처음 채워지는 경우의 후속 확인 검증
    func testCachedIdentityResolutionContinuesConfirmation() async {
        let h = ConfirmationHarness()
        h.account.email = nil
        h.account.planType = nil
        h.account.status = .loading
        h.resolveIdentityOnRead = true
        let result = await h.service.confirm(h.account)
        XCTAssertTrue(result.isCurrentAccount)
        XCTAssertTrue(result.isStable())
        XCTAssertEqual(result.queryCount, 2)
    }

    /// 최초 보완 이후 실제 로그인 변경의 추가 조회 차단 검증
    func testResolvedIdentityIsPinnedForLaterQueries() async {
        let h = ConfirmationHarness()
        h.account.email = nil
        h.account.planType = nil
        h.account.status = .loading
        h.resolveIdentityOnRead = true
        h.onSleep = { h.account.email = "changed@example.invalid" }
        let result = await h.service.confirm(h.account)
        XCTAssertFalse(result.isCurrentAccount)
        XCTAssertEqual(result.queryCount, 1)
    }

    /// 첫 응답을 확정하지 않고 10초 후 두 번째 응답으로 고정 확인
    func testFixedTimesRequireTwoSpacedQueries() async {
        let h = ConfirmationHarness()
        let result = await h.service.confirm(h.account)
        XCTAssertTrue(result.isStable())
        XCTAssertEqual(result.queryCount, 2)
        XCTAssertEqual(h.delays, [10])
    }

    /// 한쪽 시각만 이동하는 경우 구간별 결과와 조회 상한 구분
    func testMovingPrimaryDoesNotHideStableSecondary() async {
        let h = ConfirmationHarness()
        h.movingPrimary = true
        let result = await h.service.confirm(h.account)
        XCTAssertEqual(result.primary, .movingObserved)
        XCTAssertEqual(result.secondary, .stableObserved)
        XCTAssertEqual(result.queryCount, 4)
        XCTAssertEqual(h.delays, [10, 10, 10])
    }

    /// 동일 응답 재사용을 고정 관측의 두 번째 근거로 사용하지 않는지 검증
    func testDuplicateResponsesNeverConfirmStability() async {
        let h = ConfirmationHarness()
        h.duplicateResponses = true
        let result = await h.service.confirm(h.account)
        XCTAssertFalse(result.isStable())
        XCTAssertEqual(result.primary, .unavailable)
        XCTAssertEqual(result.queryCount, 4)
    }

    /// 조회 실패와 시각 변동 구분 및 최대 네 번의 조회 제한 검증
    func testFailedQueriesRemainUnavailableAndStopAtLimit() async {
        let h = ConfirmationHarness()
        h.failedQueries = [1, 2, 3, 4]
        let result = await h.service.confirm(h.account)
        XCTAssertEqual(result.primary, .unavailable)
        XCTAssertEqual(result.secondary, .unavailable)
        XCTAssertFalse(result.lastRefreshSucceeded)
        XCTAssertNil(result.account)
        XCTAssertEqual(result.queryCount, 4)
    }

    /// 일시적 실패 이후 두 정상 조회로 복구하고 추가 전송 없이 확인
    func testFailedFirstQueryCanRecoverWithFreshObservations() async {
        let h = ConfirmationHarness()
        h.failedQueries = [1]
        let result = await h.service.confirm(h.account)
        XCTAssertTrue(result.isStable())
        XCTAssertEqual(result.queryCount, 3)
        XCTAssertEqual(h.delays, [10, 10])
    }

    /// 계정 교체 이후 이전 계정의 조회·결과 반영 차단 검증
    func testIdentityChangeDuringWaitStopsBeforeNextQuery() async {
        let h = ConfirmationHarness()
        h.onSleep = { h.account.email = "changed@example.invalid" }
        let result = await h.service.confirm(h.account)
        XCTAssertFalse(result.isCurrentAccount)
        XCTAssertEqual(result.queryCount, 1)
    }

    /// 한도별 추가 초기화에서 이전 구간의 고정 확인 방지 검증
    func testNewPrimarySegmentDoesNotConfirmOldSegment() async {
        let h = ConfirmationHarness()
        h.onSleep = {
            h.primary.restart()
            h.account.primaryResetSegmentID = h.primary.segmentID
        }
        let result = await h.service.confirm(h.account)
        XCTAssertEqual(result.primary, .superseded)
        XCTAssertEqual(result.secondary, .stableObserved)
        XCTAssertFalse(result.isStable())
        XCTAssertEqual(result.queryCount, 2)
    }

    /// 체크 해제·종료의 대기 취소 이후 추가 조회 차단 검증
    func testCancellationDuringSleepStopsConfirmation() async {
        let h = ConfirmationHarness()
        h.cancelSleep = true
        let result = await h.service.confirm(h.account)
        XCTAssertFalse(result.isCurrentAccount)
        XCTAssertEqual(result.queryCount, 1)
    }
}

/// 한도별 실제 관측 추적기와 가상 시계의 공통 확인 fixture
@MainActor
private final class ConfirmationHarness {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var elapsed: TimeInterval = 0
    var account: AccountState
    var primary = ResetTimeTracker()
    var secondary = ResetTimeTracker()
    var movingPrimary = false
    var resolveIdentityOnRead = false
    var duplicateResponses = false
    var failedQueries: Set<Int> = []
    var cancelSleep = false
    var queries = 0
    var delays: [TimeInterval] = []
    var onSleep: (() -> Void)?

    /// 시계·조회·취소를 실제 소비 없는 서비스로 연결
    lazy var service = ResetTimeConfirmationService(
        refresh: { [unowned self] _ in read() },
        current: { [unowned self] _ in account },
        now: { [unowned self] in start.addingTimeInterval(elapsed) },
        sleep: { [unowned self] seconds in
            delays.append(seconds)
            if cancelSleep { throw CancellationError() }
            elapsed += seconds
            onSleep?()
        }
    )

    /// Ping 이전 계정 식별과 조회 시각 기준 생성
    init() {
        account = AccountState(id: "C1", email: "fixture@example.invalid", planType: "plus",
            primaryUsedPercent: 1, secondaryUsedPercent: 20,
            lastUpdated: Date(timeIntervalSince1970: 1_799_999_999), status: .normal)
    }

    /// 각 조회의 고정·이동·실패·중복 응답과 관측 구간 생성
    private func read() -> AccountState {
        queries += 1
        if resolveIdentityOnRead {
            account.email = "fixture@example.invalid"
            account.planType = "plus"
        }
        if duplicateResponses && queries > 1 { return account }
        if failedQueries.contains(queries) {
            account.status = .error
            return account
        }
        account.status = .normal
        account.lastUpdated = start.addingTimeInterval(elapsed)
        account.primaryResetAt = start.addingTimeInterval(18_000 + (movingPrimary ? elapsed : 0))
        account.secondaryResetAt = start.addingTimeInterval(604_800)
        account.primaryResetObservation = primary.observe(resetAt: account.primaryResetAt,
            observedAt: account.lastUpdated!, uptime: elapsed)
        account.secondaryResetObservation = secondary.observe(resetAt: account.secondaryResetAt,
            observedAt: account.lastUpdated!, uptime: elapsed)
        account.primaryResetSegmentID = primary.segmentID
        account.secondaryResetSegmentID = secondary.segmentID
        return account
    }
}
