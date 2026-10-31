// 목적: 요청 없이 초기화 일정의 표시 근거와 만료 처리 검증
// 이용처: 계정 상세 날짜·카운트다운·안내 문구 회귀 테스트
// 사용방법: swift test --filter ResetSchedulePresentationTests
import XCTest
@testable import CodexQuotaMonitorKit

/// c2의 고정 시각과 c1·c4의 미확인·이동 시각 비교
final class ResetSchedulePresentationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// 동일한 서버 시각도 관측 근거에 따라 표시 여부 분리
    func testOnlyStableFutureScheduleIsDisplayed() {
        let reset = start.addingTimeInterval(18_000)
        for observation in [ResetTimeObservation.checking, .movingObserved, .stableObserved] {
            let displayed = AccountDashboardFormatting.observedResetDate(
                reset, observation: observation, status: .normal, now: start
            )
            XCTAssertEqual(displayed, observation == .stableObserved ? reset : nil)
        }
    }

    /// c2의 이동 후 고정 관측과 c4의 연속 이동을 실제 관측기로 재현
    func testFixedAndMovingSchedulesRemainIndependent() {
        var fixed = ResetTimeTracker()
        var moving = ResetTimeTracker()
        for elapsed in [0.0, 61, 72, 254] {
            let now = start.addingTimeInterval(elapsed)
            let fixedReset = start.addingTimeInterval(18_000 + min(elapsed, 61))
            let movingReset = now.addingTimeInterval(18_000)
            let fixedObservation = fixed.observe(resetAt: fixedReset, observedAt: now, uptime: elapsed)
            let movingObservation = moving.observe(resetAt: movingReset, observedAt: now, uptime: elapsed)
            XCTAssertEqual(AccountDashboardFormatting.observedResetDate(
                fixedReset, observation: fixedObservation, status: .normal, now: now
            ), elapsed >= 72 ? fixedReset : nil)
            XCTAssertNil(AccountDashboardFormatting.observedResetDate(
                movingReset, observation: movingObservation, status: .normal, now: now
            ))
        }
        XCTAssertEqual(fixed.observation, .stableObserved)
        XCTAssertEqual(moving.observation, .movingObserved)
    }

    /// 만료·누락·비정상 날짜와 조회 실패의 확정 표시 차단
    func testExpiredInvalidAndFailedSchedulesAreHidden() {
        for reset in [nil, start, start.addingTimeInterval(-1), Date(timeIntervalSince1970: .infinity),
                      Date(timeIntervalSince1970: .nan)] {
            XCTAssertNil(AccountDashboardFormatting.observedResetDate(
                reset, observation: .stableObserved, status: .normal, now: start
            ))
        }
        for status in [AccountStatus.error, .loginRequired, .notConfigured, .codexNotFound] {
            XCTAssertNil(AccountDashboardFormatting.observedResetDate(
                start.addingTimeInterval(18_000), observation: .stableObserved, status: status, now: start
            ))
        }
        XCTAssertEqual(AccountDashboardFormatting.resetScheduleStatusText(
            start, observation: .stableObserved, status: .normal, now: start
        ), "재조회 필요 (초기화 시각 초과)")
    }

    /// 앱 재시작의 캐시 기본 관측 상태에서 일정 표시 차단
    func testRestoredCacheDoesNotImplyStableObservation() {
        let account = AccountState(id: "C1", primaryResetAt: start.addingTimeInterval(18_000), status: .loading)
        XCTAssertNil(AccountDashboardFormatting.observedResetDate(
            account.primaryResetAt, observation: account.primaryResetObservation, status: account.status, now: start
        ))
        XCTAssertNil(AccountDashboardFormatting.fiveHourResetNotice(for: account, now: start))
    }
}
