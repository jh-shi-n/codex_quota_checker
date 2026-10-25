// 목적: 초기화 시각 예약·사전 알림·도달 재조회·설정·안내 문구 검증
// 이용처: 초기화 예약 기능의 결정적 회귀 테스트
// 사용방법: swift test
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 실제 대기와 네트워크 없이 초기화 예약 경계 검증
@MainActor
final class QuotaResetSchedulerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 주간 잔량 0이면 5시간 사전·도달 알림 모두 생략 검증
    func testExhaustedWeeklyQuotaSuppressesFiveHourNotifications() async {
        let h = ResetScheduleHarness()
        var account = makeAccount(resetAfter: 600)
        account.secondaryRemainingPercent = 0
        h.result = account
        h.scheduler.reconcile(states: [account], reminderMinutes: 5, now: now)
        await h.scheduler.tick(now: now.addingTimeInterval(300))
        await h.scheduler.tick(now: now.addingTimeInterval(600))
        XCTAssertEqual(h.refreshes, ["C1"])
        XCTAssertTrue(h.alerts.isEmpty)
    }

    /// 두 구간 동시 도달 시 계정 1회 조회 및 각 알림 1회 전달 검증
    func testReminderAndBoundaryRefreshAreIndependentAndDeduplicated() async {
        let h = ResetScheduleHarness()
        var account = makeAccount(resetAfter: 600)
        account.secondaryResetAt = account.primaryResetAt
        account.secondaryResetObservation = .stableObserved
        h.scheduler.reconcile(states: [account], reminderMinutes: 5, now: now)
        await h.scheduler.tick(now: now.addingTimeInterval(299))
        XCTAssertTrue(h.alerts.isEmpty)
        await h.scheduler.tick(now: now.addingTimeInterval(300))
        await h.scheduler.tick(now: now.addingTimeInterval(301))
        XCTAssertEqual(h.alerts.count, 2)
        XCTAssertTrue(h.refreshes.isEmpty)
        XCTAssertTrue(h.alerts.allSatisfy { $0.body.contains("5분 뒤") })
        var updated = account
        updated.primaryResetAt = now.addingTimeInterval(18_600)
        updated.primaryResetObservation = .checking
        updated.secondaryResetObservation = .checking
        h.result = updated
        h.onRefresh = {
            h.scheduler.reconcile(states: [updated], reminderMinutes: 5, now: self.now.addingTimeInterval(600))
        }
        await h.scheduler.tick(now: now.addingTimeInterval(600))
        await h.scheduler.tick(now: now.addingTimeInterval(601))
        XCTAssertEqual(h.refreshes, ["C1"])
        XCTAssertEqual(h.alerts.count, 4)
        XCTAssertTrue(h.alerts[2].body.contains("시각 변경을 확인"))
        XCTAssertTrue(h.alerts[3].body.contains("아직 확인되지"))
    }

    /// 안정 관측 이전에는 예약하지 않고 예정 시각 변경 시 이전 알림 취소 검증
    func testMovingOrChangedTimestampCancelsOldSchedule() async {
        let h = ResetScheduleHarness()
        var account = makeAccount(resetAfter: 600)
        account.primaryResetObservation = .movingObserved
        h.scheduler.reconcile(states: [account], reminderMinutes: 5, now: now)
        await h.scheduler.tick(now: now.addingTimeInterval(300))
        XCTAssertTrue(h.alerts.isEmpty)
        account.primaryResetObservation = .stableObserved
        h.scheduler.reconcile(states: [account], reminderMinutes: 5, now: now)
        account.primaryResetAt = now.addingTimeInterval(1_200)
        account.primaryResetObservation = .checking
        h.scheduler.reconcile(states: [account], reminderMinutes: 5, now: now.addingTimeInterval(100))
        await h.scheduler.tick(now: now.addingTimeInterval(600))
        XCTAssertTrue(h.refreshes.isEmpty)
        XCTAssertTrue(h.alerts.isEmpty)
    }

    /// 계정 경로 세대 변경 및 로그아웃 후 이전 예약 미전달 검증
    func testConfigurationChangeAndLoginFailureInvalidateSchedule() async {
        for changeGeneration in [true, false] {
            let h = ResetScheduleHarness()
            var account = makeAccount(resetAfter: 600)
            h.scheduler.reconcile(states: [account], reminderMinutes: 5, now: now)
            if changeGeneration {
                account.configurationGeneration += 1
                account.primaryResetObservation = .checking
            } else {
                account.status = .loginRequired
            }
            h.scheduler.reconcile(states: [account], reminderMinutes: 5, now: now.addingTimeInterval(600))
            await h.scheduler.tick(now: now.addingTimeInterval(600))
            XCTAssertTrue(h.refreshes.isEmpty)
            XCTAssertTrue(h.alerts.isEmpty)
        }
    }

    /// 각 사전 알림 설정과 예약 후 설정 변경의 정확한 시점 검증
    func testThreeFiveTenMinuteOptionsAndChangedLead() async {
        for lead in [3, 5, 10] {
            let h = ResetScheduleHarness()
            let account = makeAccount(resetAfter: 1_200)
            h.scheduler.reconcile(states: [account], reminderMinutes: lead, now: now)
            let fire = now.addingTimeInterval(Double(1_200 - lead * 60))
            await h.scheduler.tick(now: fire.addingTimeInterval(-1))
            XCTAssertTrue(h.alerts.isEmpty)
            await h.scheduler.tick(now: fire)
            XCTAssertEqual(h.alerts.count, 1)
            XCTAssertTrue(h.alerts[0].body.contains("\(lead)분 뒤"))
        }
        let h = ResetScheduleHarness()
        let account = makeAccount(resetAfter: 1_200)
        h.scheduler.reconcile(states: [account], reminderMinutes: 10, now: now)
        h.scheduler.reconcile(states: [account], reminderMinutes: 3, now: now.addingTimeInterval(100))
        await h.scheduler.tick(now: now.addingTimeInterval(600))
        XCTAssertTrue(h.alerts.isEmpty)
        await h.scheduler.tick(now: now.addingTimeInterval(1_020))
        XCTAssertEqual(h.alerts.count, 1)
    }

    /// 사전 알림 해제는 도달 조회에 영향 없고 실패를 초기화 완료로 표현하지 않는지 검증
    func testReminderDisabledStillRefreshesAtBoundaryAndReportsFailure() async {
        let h = ResetScheduleHarness()
        h.scheduler.reconcile(states: [makeAccount(resetAfter: 600)], reminderMinutes: 0, now: now)
        await h.scheduler.tick(now: now.addingTimeInterval(300))
        XCTAssertTrue(h.alerts.isEmpty)
        h.result = AccountState(id: "C1", status: .timeout)
        await h.scheduler.tick(now: now.addingTimeInterval(600))
        XCTAssertEqual(h.refreshes, ["C1"])
        XCTAssertEqual(h.alerts.count, 1)
        XCTAssertTrue(h.alerts[0].body.contains("확인하지 못했습니다"))
    }

    /// 절전 복귀의 지난 사전 알림 생략 및 동시 정기 조회의 도달 이벤트 보존 검증
    func testWakeSkipsStaleReminderAndRegularRefreshDoesNotLoseBoundary() async {
        let h = ResetScheduleHarness()
        var account = makeAccount(resetAfter: 600)
        h.scheduler.reconcile(states: [account], reminderMinutes: 5, now: now)
        await h.scheduler.tick(now: now.addingTimeInterval(400))
        XCTAssertTrue(h.alerts.isEmpty)
        account.primaryResetObservation = .checking
        h.scheduler.reconcile(states: [account], reminderMinutes: 5, now: now.addingTimeInterval(601))
        await h.scheduler.tick(now: now.addingTimeInterval(601))
        await h.scheduler.tick(now: now.addingTimeInterval(602))
        XCTAssertEqual(h.refreshes, ["C1"])
        XCTAssertEqual(h.alerts.count, 1)
    }

    /// 도달 재조회 중 계정이 바뀌면 이전 계정 알림을 보내지 않는지 검증
    func testAccountChangeDuringBoundaryReadSuppressesStaleAlert() async {
        let h = ResetScheduleHarness()
        let account = makeAccount(resetAfter: 600)
        h.scheduler.reconcile(states: [account], reminderMinutes: 0, now: now)
        h.onRefresh = {
            var changed = account
            changed.configurationGeneration += 1
            changed.primaryResetObservation = .checking
            h.scheduler.reconcile(states: [changed], reminderMinutes: 0, now: self.now.addingTimeInterval(600))
        }
        await h.scheduler.tick(now: now.addingTimeInterval(600))
        XCTAssertEqual(h.refreshes, ["C1"])
        XCTAssertTrue(h.alerts.isEmpty)
    }

    /// 안정 관측의 2초 오차가 사전 알림 중복 예약으로 이어지지 않는지 검증
    func testTimestampNoiseDoesNotRepeatReminder() async {
        let h = ResetScheduleHarness()
        var account = makeAccount(resetAfter: 600)
        h.scheduler.reconcile(states: [account], reminderMinutes: 5, now: now)
        await h.scheduler.tick(now: now.addingTimeInterval(300))
        account.primaryResetAt = now.addingTimeInterval(601)
        h.scheduler.reconcile(states: [account], reminderMinutes: 5, now: now.addingTimeInterval(300))
        await h.scheduler.tick(now: now.addingTimeInterval(301))
        XCTAssertEqual(h.alerts.count, 1)
    }

    /// 사전 알림 설정의 영속성과 일반 조회 주기 보존 검증
    func testPreferencesPersistLeadWithoutChangingRegularRefresh() {
        let suite = "QuotaResetSchedulerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(userDefaults: defaults)
        XCTAssertEqual(preferences.resetReminderMinutes, 5)
        preferences.updateRefreshInterval(minutes: 10)
        for lead in [0, 3, 5, 10, -1] {
            preferences.updateResetReminder(minutes: lead)
            let restored = PreferencesStore(userDefaults: defaults)
            XCTAssertEqual(restored.resetReminderMinutes, lead == -1 ? 5 : lead)
            XCTAssertEqual(restored.refreshIntervalMinutes, 10)
        }
    }

    /// 제목 옆 안내는 5시간 안정 관측에만 표시하고 이동·실패·만료 제외 검증
    func testHeaderNoticeOnlyDescribesFutureStableFiveHourQuota() {
        var account = makeAccount(resetAfter: 181)
        account.secondaryResetAt = now.addingTimeInterval(604_800)
        account.secondaryResetObservation = .stableObserved
        XCTAssertEqual(AccountDashboardFormatting.fiveHourResetNotice(for: account, now: now),
                       "3분 뒤 5시간 할당량이 초기화될 예정입니다.")
        for (seconds, expected) in [(59.0, "1분"), (3_599.0, "59분"),
                                    (3_600.0, "1시간"), (10_861.0, "3시간 1분")] {
            account.primaryResetAt = now.addingTimeInterval(seconds)
            XCTAssertEqual(AccountDashboardFormatting.remainingTimeText(until: account.primaryResetAt, now: now),
                           expected)
            XCTAssertEqual(AccountDashboardFormatting.fiveHourResetNotice(for: account, now: now),
                           "\(expected) 뒤 5시간 할당량이 초기화될 예정입니다.")
        }
        account.primaryResetAt = now.addingTimeInterval(181)
        account.primaryResetObservation = .movingObserved
        XCTAssertNil(AccountDashboardFormatting.fiveHourResetNotice(for: account, now: now))
        account.primaryResetObservation = .stableObserved
        account.status = .timeout
        XCTAssertNil(AccountDashboardFormatting.fiveHourResetNotice(for: account, now: now))
        account.status = .normal
        XCTAssertNil(AccountDashboardFormatting.fiveHourResetNotice(for: account, now: now.addingTimeInterval(181)))
    }

    /// 미래의 안정 관측 계정 fixture 생성
    private func makeAccount(resetAfter seconds: TimeInterval) -> AccountState {
        var state = AccountState(id: "C1", primaryResetAt: now.addingTimeInterval(seconds), status: .normal)
        state.primaryResetObservation = .stableObserved
        return state
    }
}

/// 예약기의 재조회·전달 입력과 결과를 기록하는 메인 액터 fixture
@MainActor
private final class ResetScheduleHarness {
    var refreshes: [String] = []
    var alerts: [QuotaResetAlert] = []
    var result: AccountState?
    var onRefresh: (() -> Void)?
    lazy var scheduler = QuotaResetScheduler(
        refresh: { [unowned self] id in
            refreshes.append(id)
            onRefresh?()
            return result
        },
        notify: { [unowned self] alert in alerts.append(alert) }
    )
}
