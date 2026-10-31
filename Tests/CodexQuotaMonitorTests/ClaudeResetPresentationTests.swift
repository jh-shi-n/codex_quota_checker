// 목적: 실제 Claude 사용량 응답의 초기화 예정 시각 표시 회귀 검증
// 이용처: 계정 상세의 날짜·남은 시간·제공자별 표시 정책
// 사용방법: swift test --filter ClaudeResetPresentationTests
// 실행 예시: swift test --filter ClaudeResetPresentationTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 공식 CLI의 분 단위 예정 시각과 앱 고정 관측의 분리 검증
@MainActor
final class ClaudeResetPresentationTests: XCTestCase {
    /// 2026-10-31 실제 응답의 날짜·시차·분 생략 파싱과 미확정 관측의 표시 검증
    func testActualCLIResponseShowsReportedDatesWhileChecking() throws {
        let iso = ISO8601DateFormatter()
        let now = try XCTUnwrap(iso.date(from: "2026-10-31T09:38:08Z"))
        let text = "Current session: 3% used · resets Oct 31 at 10:50pm (Asia/Seoul)\nCurrent week (all models): 13% used · resets Oct 31 at 7pm (Asia/Seoul)"
        let rates = try ClaudeUsageQuery.decode(text: text, now: now)
        let primary = Date(timeIntervalSince1970: try XCTUnwrap(rates["five_hour"]?["resets_at"]))
        let secondary = Date(timeIntervalSince1970: try XCTUnwrap(rates["seven_day"]?["resets_at"]))
        XCTAssertEqual(primary, iso.date(from: "2026-10-31T13:50:00Z"))
        XCTAssertEqual(secondary, iso.date(from: "2026-10-31T10:00:00Z"))
        XCTAssertEqual(rates["five_hour"]?["used_percentage"], 3)
        XCTAssertEqual(rates["seven_day"]?["used_percentage"], 13)
        for reset in [primary, secondary] {
            let displayed = AccountDashboardFormatting.observedResetDate(reset, observation: .checking,
                status: .normal, now: now, provider: .claude)
            XCTAssertEqual(displayed, reset)
            XCTAssertNotEqual(AccountDashboardFormatting.remainingTimeText(until: displayed, now: now), "—")
            XCTAssertEqual(AccountDashboardFormatting.resetScheduleStatusText(reset, observation: .checking,
                status: .normal, now: now, provider: .claude), "고정됨")
        }
    }

    /// Claude의 확인·변동 관측과 독립적인 예정 시각 표시 및 Codex 고정 조건 유지 검증
    func testProviderPoliciesRemainDistinct() {
        let now = Date()
        let reset = now.addingTimeInterval(1000)
        for observation in [ResetTimeObservation.checking, .movingObserved, .stableObserved] {
            XCTAssertEqual(AccountDashboardFormatting.observedResetDate(reset, observation: observation,
                status: .normal, now: now, provider: .claude), reset)
            XCTAssertEqual(AccountDashboardFormatting.observedResetDate(reset, observation: observation,
                status: .normal, now: now), observation == .stableObserved ? reset : nil)
        }
        XCTAssertEqual(AccountDashboardFormatting.resetScheduleStatusText(reset, observation: .checking,
            status: .loading, now: now, provider: .claude), "조회 중")
        var account = AccountState(id: "C4", primaryResetAt: reset, status: .normal, provider: .claude)
        XCTAssertNotNil(AccountDashboardFormatting.fiveHourResetNotice(for: account, now: now))
        account.provider = .codex
        XCTAssertNil(AccountDashboardFormatting.fiveHourResetNotice(for: account, now: now))
    }

    /// 시각 누락·만료·비정상 값·조회 실패의 확정 시각 표시 차단 검증
    func testUnavailableDatesAndFailuresRemainHidden() {
        let now = Date()
        for reset in [nil, now, now.addingTimeInterval(-1), Date(timeIntervalSince1970: .nan)] {
            XCTAssertNil(AccountDashboardFormatting.observedResetDate(reset, observation: .stableObserved,
                status: .normal, now: now, provider: .claude))
        }
        for status in [AccountStatus.error, .timeout, .loginRequired, .codexNotFound, .notConfigured] {
            XCTAssertNil(AccountDashboardFormatting.observedResetDate(now.addingTimeInterval(1000),
                observation: .stableObserved, status: status, now: now, provider: .claude))
        }
    }

    /// 실제 로그와 같은 182초 후 양방향 60초 변경의 후속 확인 대상 포함 검증
    func testExactMinuteShiftIsRecheckedForBothWindows() {
        let now = Date()
        let previous = AccountState(id: "C4", email: "fixture@example.test", planType: "pro",
            primaryResetAt: now.addingTimeInterval(18000), secondaryResetAt: now.addingTimeInterval(36000),
            lastUpdated: now, status: .normal, provider: .claude)
        for shift in [-60.0, 60.0] {
            var current = previous
            current.lastUpdated = now.addingTimeInterval(182)
            current.primaryResetAt = previous.primaryResetAt?.addingTimeInterval(shift)
            current.secondaryResetAt = previous.secondaryResetAt?.addingTimeInterval(shift)
            XCTAssertEqual(QuotaRefreshCoordinator.largeChangeWindows(previous: previous, current: current), [.primary, .secondary])
        }
        var moving = previous
        moving.lastUpdated = now.addingTimeInterval(60)
        moving.primaryResetAt = previous.primaryResetAt?.addingTimeInterval(60)
        moving.secondaryResetAt = previous.secondaryResetAt?.addingTimeInterval(60)
        XCTAssertFalse(QuotaRefreshCoordinator.hasLargeChange(previous: previous, current: moving))
    }
}
