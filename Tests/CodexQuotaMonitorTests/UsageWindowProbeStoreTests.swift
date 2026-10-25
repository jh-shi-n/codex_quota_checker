// 목적: 계정 전환 중 초기화 갱신 유지와 결과 격리 검증
// 이용처: 초기화 갱신 저장소 회귀 테스트
// 사용방법: swift test --filter UsageWindowProbeStoreTests
import XCTest
@testable import CodexQuotaMonitorKit

/// 화면 수명과 독립적인 계정별 갱신 동작 검증
@MainActor
final class UsageWindowProbeStoreTests: XCTestCase {
    /// 동일 경로의 로그인·구독 변경에서 이전 실행 결과·시각 재사용 차단 검증
    func testLoginAndSubscriptionChangesDoNotInheritOldProbeResult() async {
        let store = UsageWindowProbeStore()
        let original = AccountState(id: "C1", email: "first@example.invalid", planType: "plus", status: .normal)
        await store.start(for: original) { account in
            AccountDashboardDefaults.unavailableProbe(accountID: account.id)
        }!.value
        XCTAssertNotNil(store.presentation(for: original))
        for emailChanged in [false, true] {
            var changed = original
            if emailChanged { changed.email = "second@example.invalid" }
            else { changed.planType = "pro" }
            XCTAssertNil(store.presentation(for: changed))
            XCTAssertNil(store.lastStartedAt(for: changed))
            XCTAssertFalse(store.isConfirming(for: changed))
        }
    }

    /// 팝오버 재진입과 중복 실행 시에도 현재 계정의 원래 요청 시작 시각 유지
    func testRequestStartTimeSurvivesOverlapAndLastExecutionRemainsInMemory() async throws {
        let store = UsageWindowProbeStore()
        let account = AccountState(id: "C1", status: .normal)
        let gate = ProbeStoreTestGate()
        let before = Date()
        let task = try XCTUnwrap(store.start(for: account) { account in
            await gate.wait()
            return AccountDashboardDefaults.unavailableProbe(accountID: account.id)
        })
        let started = try XCTUnwrap(store.startedAt(for: account))
        XCTAssertGreaterThanOrEqual(started, before)
        XCTAssertLessThanOrEqual(started, Date())
        XCTAssertNil(store.start(for: account) { _ in fatalError("중복 실행 금지") })
        XCTAssertEqual(store.startedAt(for: account), started)
        XCTAssertEqual(store.lastStartedAt(for: account), started)
        var changed = account
        changed.configurationGeneration += 1
        XCTAssertNil(store.startedAt(for: changed))
        XCTAssertNil(store.lastStartedAt(for: changed))
        await gate.waitUntilStarted()
        await gate.release()
        await task.value
        XCTAssertNil(store.startedAt(for: account))
        XCTAssertEqual(store.lastStartedAt(for: account), started)
        XCTAssertNil(UsageWindowProbeStore().lastStartedAt(for: account))
    }

    /// 요청 화면 취소 이후에도 다른 계정과 병행 완료 및 결과 복원 검증
    func testCallerCancellationPreservesRefreshAndIndependentAccountResults() async {
        let store = UsageWindowProbeStore()
        let first = AccountState(id: "C1", status: .normal)
        let second = AccountState(id: "C2", status: .normal)
        let gate = ProbeStoreTestGate()
        let firstTask = store.start(for: first) { account in
            await gate.wait()
            XCTAssertFalse(Task.isCancelled)
            return AccountDashboardDefaults.unavailableProbe(accountID: account.id)
        }!
        await gate.waitUntilStarted()
        let caller = Task { await firstTask.value }
        caller.cancel()
        XCTAssertTrue(store.isRunning(for: first))
        XCTAssertNil(store.start(for: first) { account in
            XCTFail("동일 계정 중복 실행")
            return AccountDashboardDefaults.unavailableProbe(accountID: account.id)
        })
        let secondTask = store.start(for: second) { account in
            AccountDashboardDefaults.unavailableProbe(accountID: account.id)
        }!
        await secondTask.value
        XCTAssertEqual(store.presentation(for: second)?.result.accountID, "C2")
        XCTAssertTrue(store.isRunning(for: first))
        XCTAssertNil(store.presentation(for: first))
        await gate.release()
        await caller.value
        XCTAssertFalse(store.isRunning(for: first))
        XCTAssertEqual(store.presentation(for: first)?.result.accountID, "C1")
    }

    /// 경로 세대 변경 시 이전 갱신 결과와 실행 상태의 노출 방지 검증
    func testReconfiguredAccountDoesNotInheritOldResult() async {
        let store = UsageWindowProbeStore()
        let old = AccountState(id: "C1", status: .normal)
        var current = old
        current.configurationGeneration += 1
        let task = store.start(for: old) { account in
            AccountDashboardDefaults.unavailableProbe(accountID: account.id)
        }!
        XCTAssertFalse(store.isRunning(for: current))
        await task.value
        XCTAssertNotNil(store.presentation(for: old))
        XCTAssertNil(store.presentation(for: current))
    }

    /// Ping 종료 이후 한도 재조회까지 화면 취소와 무관한 실행 상태 유지 검증
    func testRunningStateIncludesQuotaRefreshAfterPing() async {
        let store = UsageWindowProbeStore()
        let account = AccountState(id: "C1", status: .normal)
        let ping = ProbeStoreTestGate()
        let quota = ProbeStoreTestGate()
        let task = store.start(for: account) { account in
            await ping.wait()
            store.markConfirming(for: account)
            await quota.wait()
            XCTAssertFalse(Task.isCancelled)
            return UsageWindowProbePresentationResult(
                result: UsageWindowProbeResult(accountID: account.id, status: .success, startedAt: Date(), completedAt: Date()),
                quotaRefreshSucceeded: true,
                refreshedAccount: account
            )
        }!
        await ping.waitUntilStarted()
        XCTAssertFalse(store.isConfirming(for: account))
        let caller = Task { await task.value }
        caller.cancel()
        await ping.release()
        await quota.waitUntilStarted()
        XCTAssertTrue(store.isRunning(for: account))
        XCTAssertTrue(store.isConfirming(for: account))
        XCTAssertNil(store.presentation(for: account))
        await quota.release()
        await caller.value
        XCTAssertFalse(store.isRunning(for: account))
        XCTAssertFalse(store.isConfirming(for: account))
        XCTAssertEqual(store.presentation(for: account)?.quotaRefreshSucceeded, true)
    }

    /// 실패 후 실행 상태 해제 및 동일 계정 재시도 결과 교체 검증
    func testFailureReleasesGateAndRetryReplacesResult() async {
        let store = UsageWindowProbeStore()
        let account = AccountState(id: "C1", status: .normal)
        await store.start(for: account) { account in
            AccountDashboardDefaults.unavailableProbe(accountID: account.id, category: .timeout)
        }!.value
        XCTAssertFalse(store.isRunning(for: account))
        XCTAssertEqual(store.presentation(for: account)?.failureCategory, .timeout)
        let retry = store.start(for: account) { account in
            UsageWindowProbePresentationResult(
                result: UsageWindowProbeResult(accountID: account.id, status: .success, startedAt: Date(), completedAt: Date()),
                quotaRefreshSucceeded: false
            )
        }!
        XCTAssertTrue(store.isRunning(for: account))
        await retry.value
        XCTAssertTrue(store.presentation(for: account)?.isSuccess == true)
        XCTAssertEqual(store.presentation(for: account)?.quotaRefreshSucceeded, false)
        XCTAssertFalse(store.isRunning(for: account))
    }

    /// 미등록 슬롯에서 실제 실행 콜백 호출 방지 검증
    func testUnconfiguredAccountDoesNotStart() {
        let store = UsageWindowProbeStore()
        let account = AccountState.notConfigured(id: "C1")
        XCTAssertNil(store.start(for: account) { account in
            XCTFail("미등록 계정 실행")
            return AccountDashboardDefaults.unavailableProbe(accountID: account.id)
        })
        XCTAssertFalse(store.isRunning(for: account))
    }

    /// 다른 계정 또는 설정 변경으로 무효화된 응답의 저장 방지 검증
    func testMismatchedAndInvalidatedResultsAreDiscarded() async {
        let store = UsageWindowProbeStore()
        let account = AccountState(id: "C1", status: .normal)
        await store.start(for: account) { _ in
            AccountDashboardDefaults.unavailableProbe(accountID: "C2")
        }!.value
        XCTAssertNil(store.presentation(for: account))
        await store.start(for: account) { account in
            UsageWindowProbePresentationResult(
                result: UsageWindowProbeResult(accountID: account.id, status: .success, startedAt: Date(), completedAt: Date()),
                isCurrentAccount: false
            )
        }!.value
        XCTAssertNil(store.presentation(for: account))
        XCTAssertFalse(store.isRunning(for: account))
    }

    /// 앱 종료 취소 후 늦은 결과가 재시작 작업 상태를 덮어쓰지 않는지 검증
    func testShutdownCancelsWorkAndLateCompletionDoesNotClearRestart() async {
        let store = UsageWindowProbeStore()
        let account = AccountState(id: "C1", status: .normal)
        let oldGate = ProbeStoreTestGate()
        let old = store.start(for: account) { account in
            await oldGate.wait()
            XCTAssertTrue(Task.isCancelled)
            return AccountDashboardDefaults.unavailableProbe(accountID: account.id, category: .timeout)
        }!
        await oldGate.waitUntilStarted()
        store.cancelAll()
        XCTAssertFalse(store.isRunning(for: account))
        let newGate = ProbeStoreTestGate()
        let current = store.start(for: account) { account in
            await newGate.wait()
            return AccountDashboardDefaults.unavailableProbe(accountID: account.id, category: .processFailure)
        }!
        await newGate.waitUntilStarted()
        await oldGate.release()
        await old.value
        XCTAssertNil(store.presentation(for: account))
        XCTAssertTrue(store.isRunning(for: account))
        await newGate.release()
        await current.value
        XCTAssertFalse(store.isRunning(for: account))
        XCTAssertEqual(store.presentation(for: account)?.failureCategory, .processFailure)
    }
}

/// 테스트 작업의 진입·완료 시점 제어
private actor ProbeStoreTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false

    /// 진입 알림 이후 외부 해제까지 대기
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            didStart = true
            started?.resume()
            started = nil
        }
    }

    /// 테스트 작업의 대기 진입까지 동기화
    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { started = $0 }
    }

    /// 대기 중인 작업 완료 허용
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
