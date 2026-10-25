// 목적: 자동 Ping 초기화 감지·잔량 경계·재시도·취소·중복 방지 검증
// 이용처: 실제 CLI·할당량 소비 없는 결정적 회귀 검사
// 사용방법: swift test --filter AutomaticResetPingTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 주입한 시계·네트워크·대기로 자동 전송 정책 검증
@MainActor
final class AutomaticResetPingTests: XCTestCase {
    /// 이미 고정 관측된 새 구간에서는 추가 Ping 소비 생략 검증
    func testStableResetAtPreflightSkipsSending() async {
        let h = AutomaticPingHarness()
        var stable = h.after
        stable.primaryResetObservation = .stableObserved
        h.fresh = stable
        h.trigger()
        await h.coordinator.waitForPendingOperations()
        XCTAssertEqual(h.probes, 0)
        XCTAssertEqual(h.refreshes, 1)
        XCTAssertTrue(h.alerts.isEmpty)
    }

    /// 외부 리셋권 사용도 실제 회복이 확인되면 공통 초기화 판정으로 처리
    func testExternalCreditResetIsDetectedWithoutSuppressingEvent() async {
        let h = AutomaticPingHarness()
        h.before.primaryResetAt = h.clock.addingTimeInterval(1_000)
        h.before.resetCredits = RateLimitResetCredits(availableCount: 1, credits: [
            .init(id: "fixture", expiresAt: h.clock.addingTimeInterval(86_400))
        ])
        h.after.resetCredits = RateLimitResetCredits(availableCount: 0)
        h.trigger()
        await h.coordinator.waitForPendingOperations()
        XCTAssertEqual(h.probes, 1)
        XCTAssertTrue(h.alerts.isEmpty)
    }

    /// 공통 확인 상한 이후에도 전송·이전 재시도 대기를 반복하지 않는지 검증
    func testCompletedMovingConfirmationNeverResendsPing() async {
        let h = AutomaticPingHarness()
        h.confirmationResult = ResetTimeConfirmationResult(primary: .movingObserved, secondary: .stableObserved,
            account: h.after, lastRefreshSucceeded: true, isCurrentAccount: true, queryCount: 4)
        h.trigger()
        await h.coordinator.waitForPendingOperations()
        XCTAssertEqual(h.probes, 1)
        XCTAssertEqual(h.refreshes, 1)
        XCTAssertTrue(h.delays.isEmpty)
        XCTAssertEqual(h.alerts.first?.title, "자동 Ping 시각 확인 미완료")
    }

    /// 최초 실행·기능 활성화 시 과거 초기화에 전송하지 않는지 검증
    func testFirstSnapshotAndEnablingOnlyEstablishBaseline() async {
        let h = AutomaticPingHarness()
        h.coordinator.reconcile(states: [h.after], enabled: false)
        h.coordinator.reconcile(states: [h.after], enabled: true)
        await h.coordinator.waitForPendingOperations()
        XCTAssertEqual(h.probes, 0)
        XCTAssertEqual(h.refreshes, 0)
    }

    /// 확인된 초기화 1건의 한 번 전송과 동일 결과 재조회 중복 방지 검증
    func testConfirmedResetSendsOnce() async {
        let h = AutomaticPingHarness()
        h.trigger()
        h.coordinator.reconcile(states: [h.after], enabled: true)
        await h.coordinator.waitForPendingOperations()
        h.coordinator.reconcile(states: [h.after], enabled: true)
        await h.coordinator.waitForPendingOperations()
        XCTAssertEqual(h.probes, 1)
        XCTAssertEqual(h.refreshes, 1)
        XCTAssertTrue(h.alerts.isEmpty)
    }

    /// 주간 잔량 0·10·미확인과 5시간 소진 시 전송·실패 알림 제외 검증
    func testLowUnknownAndExhaustedQuotaSuppressPingAndAlerts() async {
        for weekly: Double? in [0, 10, nil] {
            let h = AutomaticPingHarness()
            h.after.secondaryRemainingPercent = weekly
            h.trigger()
            await h.coordinator.waitForPendingOperations()
            XCTAssertEqual(h.probes, 0)
            XCTAssertTrue(h.alerts.isEmpty)
        }
        let h = AutomaticPingHarness()
        h.before.secondaryResetAt = h.before.primaryResetAt
        h.after.secondaryUsedPercent = 0
        h.after.primaryUsedPercent = 100
        h.trigger()
        await h.coordinator.waitForPendingOperations()
        XCTAssertEqual(h.probes, 0)
        XCTAssertTrue(h.alerts.isEmpty)
    }

    /// 10% 초과의 정확한 경계에서만 전송 허용 검증
    func testAboveTenPercentIsEligible() async {
        let h = AutomaticPingHarness()
        h.after.secondaryRemainingPercent = 10.001
        h.trigger()
        await h.coordinator.waitForPendingOperations()
        XCTAssertEqual(h.probes, 1)
    }

    /// 감지 직후 잔량이 줄면 실제 전송 전 재조회로 차단 검증
    func testPreflightRechecksQuotaBeforeSending() async {
        let h = AutomaticPingHarness()
        var fresh = h.after
        fresh.secondaryRemainingPercent = 0
        h.fresh = fresh
        h.trigger()
        await h.coordinator.waitForPendingOperations()
        XCTAssertEqual(h.refreshes, 1)
        XCTAssertEqual(h.probes, 0)
        XCTAssertTrue(h.alerts.isEmpty)
    }

    /// 전송 실패 뒤 주간 잔량이 소진되면 재시도·실패 알림 제외 검증
    func testQuotaExhaustionBetweenRetriesStopsWithoutAlert() async {
        let h = AutomaticPingHarness()
        h.failures = 4
        h.onProbe = {
            var fresh = h.after
            fresh.secondaryRemainingPercent = 0
            h.fresh = fresh
        }
        h.trigger()
        await h.coordinator.waitForPendingOperations()
        XCTAssertEqual(h.probes, 1)
        XCTAssertTrue(h.alerts.isEmpty)
    }

    /// 대기 중 소진이 정상 조회로 확인된 뒤 후속 조회가 실패해도 실패 알림 제외 검증
    func testObservedExhaustionCancelsEvenWhenNextRefreshFails() async {
        let h = AutomaticPingHarness()
        h.failures = 4
        h.onSleep = {
            var exhausted = h.after
            exhausted.secondaryRemainingPercent = 0
            h.coordinator.reconcile(states: [exhausted], enabled: true)
            exhausted.status = .error
            h.fresh = exhausted
        }
        h.trigger()
        await h.coordinator.waitForPendingOperations()
        XCTAssertEqual(h.probes, 1)
        XCTAssertTrue(h.alerts.isEmpty)
    }

    /// 최신 할당량 조회가 계속 실패하면 Ping 미전송과 최종 실패 1회 검증
    func testPreflightFailuresNeverSendPingAndNotifyOnce() async {
        let h = AutomaticPingHarness()
        var failed = h.after
        failed.status = .error
        h.fresh = failed
        h.trigger()
        await h.coordinator.waitForPendingOperations()
        XCTAssertEqual(h.refreshes, 4)
        XCTAssertEqual(h.probes, 0)
        XCTAssertEqual(h.alerts.count, 1)
    }

    /// 5시간·주간 동시 초기화를 계정 1회 전송으로 합치는지 검증
    func testSimultaneousWindowsShareOnePing() async {
        let h = AutomaticPingHarness()
        h.before.secondaryResetAt = h.before.primaryResetAt
        h.after.secondaryUsedPercent = 0
        h.trigger()
        await h.coordinator.waitForPendingOperations()
        XCTAssertEqual(h.probes, 1)
    }

    /// 단순 이동 시각과 오래된 결과는 초기화로 취급하지 않는지 검증
    func testMovingAndStaleSnapshotsDoNotSend() async {
        let h = AutomaticPingHarness()
        h.before.primaryResetObservation = .movingObserved
        h.after.primaryUsedPercent = h.before.primaryUsedPercent
        h.trigger()
        await h.coordinator.waitForPendingOperations()
        XCTAssertEqual(h.probes, 0)
        let stale = AutomaticPingHarness()
        stale.after.lastUpdated = stale.clock.addingTimeInterval(-120)
        stale.trigger()
        await stale.coordinator.waitForPendingOperations()
        XCTAssertEqual(stale.probes, 0)
    }

    /// 최초 실패 뒤 3회 순차 재시도로 네 번째 성공 시 알림 제외 검증
    func testThreeRetriesThenSuccess() async {
        let h = AutomaticPingHarness()
        h.failures = 3
        h.trigger()
        await h.coordinator.waitForPendingOperations()
        XCTAssertEqual(h.probes, 4)
        XCTAssertEqual(h.delays, [5, 15, 30])
        XCTAssertTrue(h.alerts.isEmpty)
    }

    /// 네 번 실패 시 재시도 종료 및 실패 알림 1회 검증
    func testExhaustedRetriesNotifyOnce() async {
        let h = AutomaticPingHarness()
        h.failures = 4
        h.trigger()
        await h.coordinator.waitForPendingOperations()
        XCTAssertEqual(h.probes, 4)
        XCTAssertEqual(h.alerts.count, 1)
        XCTAssertEqual(h.alerts.first?.title, "할당량 자동 Ping 실패")
    }

    /// 인증·미지원 모델 등 영구 오류는 추가 소비 없이 즉시 실패 안내 검증
    func testPermanentFailureDoesNotRetry() async {
        let h = AutomaticPingHarness()
        h.failureCategory = .authenticationFailure
        h.failures = 4
        h.trigger()
        await h.coordinator.waitForPendingOperations()
        XCTAssertEqual(h.probes, 1)
        XCTAssertTrue(h.delays.isEmpty)
        XCTAssertEqual(h.alerts.count, 1)
    }

    /// 수동 Ping 실행 중에는 중복 전송·재시도·실패 알림 제외 검증
    func testAlreadyRunningDoesNotRetryOrNotify() async {
        let h = AutomaticPingHarness()
        h.failureCategory = .alreadyRunning
        h.failures = 4
        h.trigger()
        await h.coordinator.waitForPendingOperations()
        XCTAssertEqual(h.probes, 1)
        XCTAssertTrue(h.delays.isEmpty)
        XCTAssertTrue(h.alerts.isEmpty)
    }

    /// Ping 성공 후 조회 실패 시 Ping 반복 없이 조회만 재시도 검증
    func testSuccessfulPingIsNeverRepeatedForRefreshFailure() async {
        let h = AutomaticPingHarness()
        h.confirmationFails = true
        h.trigger()
        await h.coordinator.waitForPendingOperations()
        XCTAssertEqual(h.probes, 1)
        XCTAssertEqual(h.refreshes, 2)
        XCTAssertEqual(h.delays, [5])
        XCTAssertTrue(h.alerts.isEmpty)
    }

    /// 사용자 수동 사용이 먼저 시작되면 추가 Ping을 생략하는지 검증
    func testManualUsageWinsBeforeAutomaticSend() async {
        let h = AutomaticPingHarness()
        var fresh = h.after
        fresh.primaryUsedPercent = 1
        h.fresh = fresh
        h.trigger()
        await h.coordinator.waitForPendingOperations()
        XCTAssertEqual(h.probes, 0)
        XCTAssertTrue(h.alerts.isEmpty)
    }

    /// 대기 중 체크 해제 시 추가 재시도·실패 알림 취소 검증
    func testDisablingDuringRetryCancelsRemainingWork() async {
        let h = AutomaticPingHarness()
        h.failures = 4
        h.onSleep = { h.coordinator.reconcile(states: [h.after], enabled: false) }
        h.trigger()
        await h.coordinator.waitForPendingOperations()
        XCTAssertEqual(h.probes, 1)
        XCTAssertTrue(h.alerts.isEmpty)
    }

    /// 전송 중 계정 세대가 바뀌면 이전 계정 응답·알림 폐기 검증
    func testAccountChangeDiscardsLateResult() async {
        let h = AutomaticPingHarness()
        h.failures = 4
        h.onProbe = {
            var replacement = h.after
            replacement.configurationGeneration += 1
            h.coordinator.reconcile(states: [replacement], enabled: true)
        }
        h.trigger()
        await h.coordinator.waitForPendingOperations()
        XCTAssertEqual(h.probes, 1)
        XCTAssertTrue(h.alerts.isEmpty)
    }

    /// 주간 소진 중 조기 5시간 알림 제외 및 주간 알림 보존 검증
    func testEarlyResetNotificationFilterPreservesWeeklyWindow() {
        let primary = EarlyQuotaReset(accountID: "C1", windows: [.primary])
        XCTAssertNil(primary.suppressingUnavailablePrimary(weeklyRemaining: 0))
        let both = EarlyQuotaReset(accountID: "C1", windows: [.primary, .secondary])
        XCTAssertEqual(both.suppressingUnavailablePrimary(weeklyRemaining: 0)?.windows, [.secondary])
        XCTAssertEqual(primary.suppressingUnavailablePrimary(weeklyRemaining: 1)?.windows, [.primary])
    }
}

/// 초기화 이전·이후 스냅샷과 실제 소비 없는 전송 결과 fixture
@MainActor
private final class AutomaticPingHarness {
    let clock = Date(timeIntervalSince1970: 1_800_000_000)
    var before: AccountState
    var after: AccountState
    var fresh: AccountState?
    var probes = 0
    var refreshes = 0
    var failures = 0
    var failureCategory: UsageWindowProbeFailureCategory = .timeout
    var confirmationFails = false
    var confirmationResult: ResetTimeConfirmationResult?
    var alerts: [QuotaResetAlert] = []
    var delays: [TimeInterval] = []
    var onSleep: (() -> Void)?
    var onProbe: (() -> Void)?

    /// 고정 시계와 순차 전송·재조회 기록 연결
    lazy var coordinator = AutomaticResetPingCoordinator(
        refresh: { [unowned self] _ in
            refreshes += 1
            var result = fresh ?? after
            if probes > 0 && probes > failures {
                result.primaryResetObservation = .stableObserved
                result.secondaryResetObservation = .stableObserved
            }
            return result
        },
        probe: { [unowned self] account in
            probes += 1
            onProbe?()
            let failed = probes <= failures
            var refreshed = fresh ?? after
            refreshed.primaryResetObservation = .stableObserved
            refreshed.secondaryResetObservation = .stableObserved
            return UsageWindowProbePresentationResult(
                result: UsageWindowProbeResult(accountID: account.id, status: failed ? .failure : .success,
                    startedAt: clock, completedAt: clock, failureCategory: failed ? failureCategory : nil),
                quotaRefreshSucceeded: !failed && !confirmationFails,
                refreshedAccount: failed || confirmationFails ? nil : refreshed,
                resetConfirmation: confirmationResult
            )
        },
        notify: { [unowned self] alert in alerts.append(alert) },
        now: { [unowned self] in clock },
        sleep: { [unowned self] seconds in delays.append(seconds); onSleep?() }
    )

    /// 정상 사용 중인 안정 시각과 초기화 직후 사용량 0 구성
    init() {
        before = AccountState(id: "C1", email: "fixture@example.invalid", planType: "plus",
            primaryUsedPercent: 80, secondaryUsedPercent: 20,
            primaryResetAt: clock.addingTimeInterval(-1), secondaryResetAt: clock.addingTimeInterval(604_800),
            lastUpdated: clock.addingTimeInterval(-5), status: .normal)
        before.primaryResetObservation = .stableObserved
        before.secondaryResetObservation = .stableObserved
        after = before
        after.primaryUsedPercent = 0
        after.primaryResetAt = clock.addingTimeInterval(18_000)
        after.lastUpdated = clock
        after.primaryResetObservation = .checking
    }

    /// 초기 기준 수집 이후 실제 초기화 상태 적용
    func trigger() {
        coordinator.reconcile(states: [before], enabled: true)
        coordinator.reconcile(states: [after], enabled: true)
    }
}
