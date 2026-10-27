// 목적: 취소된 조회의 마지막 정상 상태 및 재확인 상태 복원 검증
// 이용처: AccountStore·QuotaRefreshCoordinator 취소 회귀 테스트
// 사용방법: swift test --filter RefreshCancellationStateTests
// 실행 예시: swift test --filter RefreshCancellationStateTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 조회 취소 후 화면 상태 복원 검증
@MainActor
final class RefreshCancellationStateTests: XCTestCase {
    /// 캐시 없는 최초 조회 취소 후 대기 상태 및 수동 재조회 가능 상태 확인
    func testCancellingInitialRefreshRestoresWaitingAndAllowsManualRefresh() async throws {
        let fixture = CancellationStateFixture()
        defer { fixture.cleanup() }
        let source = CancellationStateSource(successfulReads: 0)
        let store = AccountStore(configs: fixture.configs, preferencesStore: fixture.preferences) { config in
            try await source.read(id: config.id)
        }
        let task = Task { await store.refresh(accountID: "C1", forceFresh: true) }
        await source.waitForBlockedRead()
        task.cancel()
        _ = await task.value
        let cancelled = try XCTUnwrap(store.state(for: "C1"))
        XCTAssertTrue(cancelled.isWaitingForRefresh)
        XCTAssertFalse(cancelled.isRefreshing)
        await source.allowSuccessAfterCancellation()
        let refreshed = await store.refresh(accountID: "C1", forceFresh: true)
        XCTAssertTrue(refreshed)
        XCTAssertEqual(store.state(for: "C1")?.status, .normal)
        await store.shutdown()
    }

    /// 자동 조회 취소 후 마지막 정상 스냅샷 유지 확인
    func testCancellingRefreshRestoresPreviousNormalState() async throws {
        let fixture = CancellationStateFixture()
        defer { fixture.cleanup() }
        let source = CancellationStateSource(successfulReads: 1)
        let store = AccountStore(configs: fixture.configs, preferencesStore: fixture.preferences) { config in
            try await source.read(id: config.id)
        }
        let controller = QuotaMonitoringController(store: store, preferences: fixture.preferences)
        await store.refresh(accountID: "C1", forceFresh: true)
        let previous = try XCTUnwrap(store.state(for: "C1"))
        controller.setEnabled(true)
        await source.waitForBlockedRead()
        controller.setEnabled(false)
        await source.waitForCancellation()
        for _ in 0..<100 { await Task.yield() }
        let state = try XCTUnwrap(store.state(for: "C1"))
        XCTAssertEqual(state.status, .normal)
        XCTAssertFalse(state.isRefreshing)
        XCTAssertEqual(state.primaryUsedPercent, previous.primaryUsedPercent)
        XCTAssertEqual(state.lastUpdated, previous.lastUpdated)
        controller.stop()
        await store.shutdown()
    }

    /// 검증 2차 조회 취소 후 대기 플래그 해제 및 정상 스냅샷 복원 확인
    func testCancellingSecondVerificationRefreshClearsPendingState() async throws {
        let fixture = CancellationStateFixture()
        defer { fixture.cleanup() }
        let source = CancellationStateSource(successfulReads: 1)
        let store = AccountStore(configs: fixture.configs, preferencesStore: fixture.preferences) { config in
            try await source.read(id: config.id)
        }
        let checks = QuotaRefreshCoordinator(store: store, sleep: { _ in })
        let task = Task { await checks.refresh(accountID: "C1", startup: true) }
        await source.waitForBlockedRead()
        XCTAssertTrue(store.state(for: "C1")?.isResetVerificationPending == true)
        task.cancel()
        await task.value
        let state = try XCTUnwrap(store.state(for: "C1"))
        XCTAssertEqual(state.status, .normal)
        XCTAssertFalse(state.isRefreshing)
        XCTAssertFalse(state.isResetVerificationPending)
        await store.shutdown()
    }

    /// 3초 확인 대기 취소 후 재확인 안내 해제 및 정상 상태 유지 확인
    func testCancellingVerificationDelayClearsPendingState() async throws {
        let fixture = CancellationStateFixture()
        defer { fixture.cleanup() }
        let source = CancellationStateSource(successfulReads: 1)
        let store = AccountStore(configs: fixture.configs, preferencesStore: fixture.preferences) { config in
            try await source.read(id: config.id)
        }
        let checks = QuotaRefreshCoordinator(store: store, sleep: { _ in
            try await Task.sleep(for: .seconds(60))
        })
        let task = Task { await checks.refresh(accountID: "C1", startup: true) }
        for _ in 0..<10_000 where store.state(for: "C1")?.isResetVerificationPending != true {
            await Task.yield()
        }
        XCTAssertTrue(store.state(for: "C1")?.isResetVerificationPending == true)
        task.cancel()
        await task.value
        let state = try XCTUnwrap(store.state(for: "C1"))
        XCTAssertEqual(state.status, .normal)
        XCTAssertFalse(state.isResetVerificationPending)
        await store.shutdown()
    }

    /// 검증 취소 후 경합 조회도 취소될 때 재확인 플래그 부활 차단 확인
    func testVerificationCancellationClearsPendingFromConcurrentRefreshRecovery() async throws {
        let fixture = CancellationStateFixture()
        defer { fixture.cleanup() }
        let source = CancellationStateSource(successfulReads: 1)
        let store = AccountStore(configs: fixture.configs, preferencesStore: fixture.preferences) { config in
            try await source.read(id: config.id)
        }
        let checks = QuotaRefreshCoordinator(store: store, sleep: { _ in
            try await Task.sleep(for: .seconds(60))
        })
        let verification = Task { await checks.refresh(accountID: "C1", startup: true) }
        for _ in 0..<10_000 where store.state(for: "C1")?.isResetVerificationPending != true {
            await Task.yield()
        }
        XCTAssertTrue(store.state(for: "C1")?.isResetVerificationPending == true)
        let concurrentRefresh = Task { await store.refreshOutcome(accountID: "C1", forceFresh: true) }
        await source.waitForBlockedRead()
        verification.cancel()
        await verification.value
        concurrentRefresh.cancel()
        _ = await concurrentRefresh.value
        let state = try XCTUnwrap(store.state(for: "C1"))
        XCTAssertEqual(state.status, .normal)
        XCTAssertFalse(state.isRefreshing)
        XCTAssertFalse(state.isResetVerificationPending)
        await store.shutdown()
    }

    /// 구 요청 취소 완료가 최신 강제 조회 결과를 덮지 않는지 확인
    func testCancellingOlderForcedRefreshPreservesNewerSuccess() async throws {
        let fixture = CancellationStateFixture()
        defer { fixture.cleanup() }
        let configs = fixture.configs
        let source = ConcurrentCancellationSource()
        let store = AccountStore(configs: configs, preferencesStore: fixture.preferences) { config in
            try await source.read(id: config.id)
        }
        let older = Task { await store.refreshOutcome(accountID: "C1", forceFresh: true) }
        await source.waitForCalls(1)
        let newer = Task { await store.refreshOutcome(accountID: "C1", forceFresh: true) }
        await source.waitForCalls(2)
        let newerResult = await newer.value
        XCTAssertTrue(newerResult.isSuccess)
        older.cancel()
        let olderResult = await older.value
        XCTAssertEqual(olderResult, .superseded)
        XCTAssertEqual(store.state(for: "C1")?.status, .normal)
        XCTAssertEqual(store.state(for: "C1")?.usedPercent, 20)
        await store.shutdown()
    }

    /// 이전 강제 조회 중 새 강제 조회 취소 시 기존 timeout 스냅샷 복원 확인
    func testCancellingNewerForcedRefreshRestoresPriorTimeoutWhileOlderIsActive() async throws {
        let fixture = CancellationStateFixture()
        defer { fixture.cleanup() }
        let source = NestedForcedCancellationSource()
        let store = AccountStore(configs: fixture.configs, preferencesStore: fixture.preferences) { config in
            try await source.read(id: config.id)
        }
        _ = await store.refreshOutcome(accountID: "C1", forceFresh: true)
        _ = await store.refreshOutcome(accountID: "C1", forceFresh: true)
        let previous = try XCTUnwrap(store.state(for: "C1"))
        XCTAssertEqual(previous.status, .timeout)
        XCTAssertNotNil(previous.lastUpdated)
        let older = Task { await store.refreshOutcome(accountID: "C1", forceFresh: true) }
        await source.waitForCalls(3)
        let newer = Task { await store.refreshOutcome(accountID: "C1", forceFresh: true) }
        await source.waitForCalls(4)
        newer.cancel()
        let newerResult = await newer.value
        XCTAssertEqual(newerResult, .superseded)
        let restored = try XCTUnwrap(store.state(for: "C1"))
        XCTAssertEqual(restored.status, .timeout)
        XCTAssertEqual(restored.lastUpdated, previous.lastUpdated)
        older.cancel()
        _ = await older.value
        XCTAssertEqual(store.state(for: "C1")?.status, .timeout)
        await store.shutdown()
    }

    /// 공유 요청의 한 소비자 취소가 다른 소비자의 로딩을 조기 해제하지 않는지 확인
    func testCancellingOneSharedWaiterPreservesOtherWaiter() async throws {
        let fixture = CancellationStateFixture()
        defer { fixture.cleanup() }
        let configs = fixture.configs
        let source = SharedCancellationSource()
        let store = AccountStore(configs: configs, preferencesStore: fixture.preferences) { config in
            try await source.read(id: config.id)
        }
        _ = await store.refreshOutcome(accountID: "C1")
        let cancelled = Task { await store.refreshOutcome(accountID: "C1") }
        await source.waitForCalls(2)
        let remaining = Task { await store.refreshOutcome(accountID: "C1") }
        try await Task.sleep(for: .milliseconds(30))
        cancelled.cancel()
        try await Task.sleep(for: .milliseconds(30))
        let loaderWasCancelled = await source.wasCancelled()
        XCTAssertFalse(loaderWasCancelled)
        XCTAssertTrue(store.state(for: "C1")?.isRefreshing == true)
        let result = await remaining.value
        _ = await cancelled.value
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(store.state(for: "C1")?.status, .normal)
        await store.shutdown()
    }

    /// 경로 재설정 이후 구 요청 취소의 이전 상태 복원 차단 확인
    func testCancellingRefreshAfterReconfigurationPreservesNewAccountState() async throws {
        let fixture = CancellationStateFixture()
        defer { fixture.cleanup() }
        let configs = fixture.configs
        let source = CancellationStateSource(successfulReads: 0)
        let store = AccountStore(configs: configs, preferencesStore: fixture.preferences) { config in
            try await source.read(id: config.id)
        }
        let old = Task { await store.refreshOutcome(accountID: "C1", forceFresh: true) }
        await source.waitForBlockedRead()
        var updated = configs
        updated[0] = AccountConfig(id: "C1", home: URL(fileURLWithPath: "/tmp/cancel-reconfigured-c1-new"), position: .left)
        store.reconfigure(updated)
        old.cancel()
        _ = await old.value
        let state = try XCTUnwrap(store.state(for: "C1"))
        XCTAssertTrue(state.isWaitingForRefresh)
        XCTAssertFalse(state.isRefreshing)
        XCTAssertEqual(state.configurationGeneration, 1)
        await store.shutdown()
    }
}

/// 임시 설정 도메인 및 SQLite 경로 제공
@MainActor
private final class CancellationStateFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "CodexQuotaMonitorTests.CancelState.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    lazy var configs = AccountConfig.accounts(for: [root.appendingPathComponent("c1").path, "", "", ""])
    lazy var preferences = PreferencesStore(userDefaults: defaults, defaultPaths: configs.map { $0.home.path },
        quotaDatabaseURL: root.appendingPathComponent("quota.sqlite"))

    /// 임시 설정 도메인 및 데이터베이스 제거
    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

/// 최초 정상 응답 이후 취소 가능한 조회 대기 제공
private actor CancellationStateSource {
    let successfulReads: Int
    var calls = 0
    var blocked = false
    var cancelled = false
    var succeedsAfterCancellation = false

    /// 선행 정상 응답 횟수 설정
    init(successfulReads: Int) { self.successfulReads = successfulReads }

    /// 정상 스냅샷 또는 취소 오류 반환
    func read(id: String) async throws -> AccountState {
        calls += 1
        if calls <= successfulReads || succeedsAfterCancellation {
            return AccountState(id: id, email: "cancel@example.invalid", planType: "plus",
                primaryUsedPercent: 20, primaryResetAt: Date().addingTimeInterval(18_000),
                lastUpdated: Date(), status: .normal)
        }
        blocked = true
        do { try await Task.sleep(for: .seconds(30)) }
        catch { cancelled = true; throw error }
        return AccountState(id: id, status: .error)
    }

    /// 취소 이후 후속 수동 조회의 정상 응답 허용
    func allowSuccessAfterCancellation() { succeedsAfterCancellation = true }

    /// 취소 가능한 조회 진입까지 대기
    func waitForBlockedRead() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !blocked && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(blocked)
    }

    /// loader 취소 전파까지 대기
    func waitForCancellation() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !cancelled && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(cancelled)
    }
}

/// 오래된 요청은 장시간 대기하고 최신 요청은 빠르게 정상 응답
private actor ConcurrentCancellationSource {
    var calls = 0

    /// 호출 순번에 따라 지연 시간 및 사용량 설정
    func read(id: String) async throws -> AccountState {
        calls += 1
        let call = calls
        try await Task.sleep(for: .milliseconds(call == 1 ? 10_000 : 50))
        return AccountState(id: id, usedPercent: Double(call * 10), status: .normal)
    }

    /// 지정된 loader 호출 수까지 대기
    func waitForCalls(_ count: Int) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while calls < count && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertGreaterThanOrEqual(calls, count)
    }
}

/// 첫 조회 완료 후 공유 조회를 취소 전파 없이 마치는 mock loader
private actor SharedCancellationSource {
    var calls = 0
    var cancelled = false

    /// 두 번째 요청을 지연 응답으로 제공
    func read(id: String) async throws -> AccountState {
        calls += 1
        let call = calls
        if call > 1 {
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { cancelled = true; throw error }
        }
        return AccountState(id: id, usedPercent: Double(call * 10), status: .normal)
    }

    /// 지정된 loader 호출 수까지 대기
    func waitForCalls(_ count: Int) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while calls < count && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertGreaterThanOrEqual(calls, count)
    }

    /// 마지막 waiter 취소로 loader까지 취소됐는지 조회
    func wasCancelled() -> Bool { cancelled }
}

/// 정상 응답, timeout 스냅샷, 취소 가능한 두 중첩 요청 제공
private actor NestedForcedCancellationSource {
    var calls = 0

    /// 호출 순번에 따라 정상·timeout·취소 대기 결과 반환
    func read(id: String) async throws -> AccountState {
        calls += 1
        switch calls {
        case 1:
            return AccountState(id: id, email: "nested@example.invalid", planType: "plus",
                usedPercent: 35, lastUpdated: Date(), status: .normal)
        case 2:
            return AccountState(id: id, status: .timeout, errorMessage: "timeout")
        default:
            try await Task.sleep(for: .seconds(30))
            return AccountState(id: id, status: .normal)
        }
    }

    /// 지정된 loader 호출 수까지 대기
    func waitForCalls(_ count: Int) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while calls < count && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertGreaterThanOrEqual(calls, count)
    }
}
