// 목적: Claude 초기화 경계의 재조회·관측·알림·실패 격리 검증
// 이용처: 공통 초기화 예약과 Claude 조회 연결의 회귀 테스트
// 사용방법: swift test --filter ClaudeResetRefreshTests
// 실행 예시: swift test --filter ClaudeResetRefreshTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 서버 응답과 시계를 제어한 Claude 초기화 통합 검증
@MainActor
final class ClaudeResetRefreshTests: XCTestCase {
    /// 두 정상 조회의 고정 관측·초기화 재조회·서버 0% 표시 검증
    func testClaudeBoundaryRefreshRecoversZeroAndSchedulesNextWindow() async throws {
        let h = try ClaudeResetHarness()
        defer { h.cleanUp() }
        await h.checks.refresh(accountID: "C1", startup: true)
        let initial = try XCTUnwrap(h.store.state(for: "C1"))
        XCTAssertEqual(initial.primaryResetObservation, .stableObserved)
        XCTAssertEqual(h.loads, 2)
        h.scheduler.reconcile(states: [initial], reminderMinutes: 5, now: h.now)
        h.advance(297)
        await h.scheduler.tick(now: h.now)
        XCTAssertEqual(h.alerts.count, 1)
        h.advance(300)
        h.used = 0
        h.reset = h.now.addingTimeInterval(18_000)
        await h.scheduler.tick(now: h.now)
        let updated = try XCTUnwrap(h.store.state(for: "C1"))
        XCTAssertEqual(updated.primaryRemainingPercent, 100)
        XCTAssertEqual(updated.primaryResetObservation, .stableObserved)
        XCTAssertEqual(h.loads, 4)
        XCTAssertEqual(h.alerts.count, 2)
        XCTAssertTrue(h.alerts.last?.body.contains("시각 변경을 확인") == true)
        XCTAssertNil(h.preferences.quotaSnapshot(for: h.home))
        await h.scheduler.tick(now: h.now)
        XCTAssertEqual(h.alerts.count, 2)
        h.scheduler.reconcile(states: [updated], reminderMinutes: 5, now: h.now)
        h.advance(h.reset.timeIntervalSince(h.now) - 300)
        await h.scheduler.tick(now: h.now)
        XCTAssertEqual(h.alerts.count, 3)
    }

    /// 예정 시각 이전의 실제 사용량 회복 알림과 중복 방지 검증
    func testEarlyClaudeResetEmitsOneEvent() async throws {
        let h = try ClaudeResetHarness()
        defer { h.cleanUp() }
        var events: [EarlyQuotaReset] = []
        h.store.onEarlyQuotaReset = { events.append($0) }
        await h.checks.refresh(accountID: "C1", startup: true)
        h.advance(10)
        h.used = 0
        h.reset = h.now.addingTimeInterval(18_000)
        await h.checks.refresh(accountID: "C1")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.windows, [.primary])
        XCTAssertNil(h.preferences.quotaSnapshot(for: h.home))
    }

    /// 5시간·주간 동시 초기화의 알림별 1회 전달 검증
    func testBothClaudeWindowsResetTogether() async throws {
        let h = try ClaudeResetHarness()
        defer { h.cleanUp() }
        h.weekReset = h.reset
        await h.checks.refresh(accountID: "C1", startup: true)
        h.scheduler.reconcile(states: [try XCTUnwrap(h.store.state(for: "C1"))], reminderMinutes: 0, now: h.now)
        h.advance(600)
        h.used = 0
        h.weekUsed = 0
        h.reset = h.now.addingTimeInterval(18_000)
        h.weekReset = h.now.addingTimeInterval(604_800)
        await h.scheduler.tick(now: h.now)
        XCTAssertEqual(h.loads, 4)
        XCTAssertEqual(h.alerts.count, 2)
        XCTAssertEqual(h.store.state(for: "C1")?.secondaryRemainingPercent, 100)
    }

    /// 초기화 경계의 일시적 조회 실패 후 1회 재시도로 정상 복구 검증
    func testBoundaryFailureRetriesWithoutReportingFalseReset() async throws {
        let h = try ClaudeResetHarness()
        defer { h.cleanUp() }
        await h.checks.refresh(accountID: "C1", startup: true)
        h.advance(600)
        h.used = 0
        h.reset = h.now.addingTimeInterval(18_000)
        h.failedLoads = [3]
        await h.checks.refresh(accountID: "C1")
        XCTAssertEqual(h.loads, 5)
        XCTAssertEqual(h.store.state(for: "C1")?.primaryRemainingPercent, 100)
    }

    /// 초기화 직후 일부 구간 누락의 3초 후 복구 및 재관측 검증
    func testMissingBoundaryWindowRetriesAndRecovers() async throws {
        let h = try ClaudeResetHarness()
        defer { h.cleanUp() }
        await h.checks.refresh(accountID: "C1", startup: true)
        h.advance(600)
        h.reset = h.now.addingTimeInterval(18_000)
        h.used = 0
        h.missingLoads = [3]
        await h.checks.refresh(accountID: "C1")
        XCTAssertEqual(h.loads, 5)
        XCTAssertEqual(h.delays, [3, 3, 3])
        XCTAssertEqual(h.store.state(for: "C1")?.primaryRemainingPercent, 100)
        XCTAssertEqual(h.store.state(for: "C1")?.primaryResetObservation, .stableObserved)
    }

    /// 누락 응답 지속 시 재시도 상한과 임의 100% 표시 차단 검증
    func testPersistentMissingWindowRemainsUnknownWithBoundedRetry() async throws {
        let h = try ClaudeResetHarness()
        defer { h.cleanUp() }
        await h.checks.refresh(accountID: "C1", startup: true)
        h.advance(600)
        h.missingLoads = [3, 4]
        await h.checks.refresh(accountID: "C1")
        XCTAssertEqual(h.loads, 4)
        XCTAssertNil(h.store.state(for: "C1")?.primaryRemainingPercent)
    }

    /// 초기화 대기 중 계정 변경의 이전 계정 추가 조회 차단 검증
    func testAccountChangeDuringRetryCancelsOldRead() async throws {
        let h = try ClaudeResetHarness()
        defer { h.cleanUp() }
        await h.checks.refresh(accountID: "C1", startup: true)
        h.advance(600)
        h.missingLoads = [3]
        h.changeAccountDuringSleep = true
        await h.checks.refresh(accountID: "C1")
        XCTAssertEqual(h.loads, 3)
    }

    /// 주기 조회에서 만료 구간이 먼저 사라져도 도달 알림 유지 검증
    func testExpiredWindowDoesNotCancelPendingClaudeBoundary() async throws {
        let h = try ClaudeResetHarness()
        defer { h.cleanUp() }
        await h.checks.refresh(accountID: "C1", startup: true)
        h.scheduler.reconcile(states: [try XCTUnwrap(h.store.state(for: "C1"))], reminderMinutes: 0, now: h.now)
        h.advance(600)
        h.missingLoads = [3, 4, 5]
        await h.store.refresh(accountID: "C1", forceFresh: true)
        h.scheduler.reconcile(states: [try XCTUnwrap(h.store.state(for: "C1"))], reminderMinutes: 0, now: h.now)
        await h.scheduler.tick(now: h.now)
        XCTAssertEqual(h.alerts.count, 1)
        XCTAssertFalse(h.alerts[0].body.contains("시각 변경을 확인"))
    }
}

/// 계정별 저장소·예약기·요청 결과를 연결한 격리 fixture
@MainActor
private final class ClaudeResetHarness {
    let home: URL
    let defaults: UserDefaults
    let suite = "ClaudeResetRefresh-" + UUID().uuidString
    let preferences: PreferencesStore
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var uptime: TimeInterval = 0
    var reset = Date(timeIntervalSince1970: 1_800_000_600)
    var used: Double = 80
    var weekReset = Date(timeIntervalSince1970: 1_800_600_000)
    var weekUsed: Double = 4
    var failedLoads: Set<Int> = []
    var loads = 0
    var missingLoads: Set<Int> = []
    var delays: [TimeInterval] = []
    var alerts: [QuotaResetAlert] = []
    var changeAccountDuringSleep = false
    lazy var store: AccountStore = {
        let store = AccountStore(configs: [AccountConfig(id: "C1", home: home, position: .left)], preferencesStore: preferences) { [unowned self] config in
            await self.load(config)
        }
        store.observationNow = { [unowned self] in now }
        store.observationUptime = { [unowned self] in uptime }
        return store
    }()
    lazy var checks = QuotaRefreshCoordinator(store: store, now: { [unowned self] in now }, sleep: { [unowned self] delay in
        await wait(delay)
    })
    lazy var scheduler = QuotaResetScheduler(refresh: { [unowned self] id in
        await checks.refresh(accountID: id)
        return store.state(for: id)
    }, notify: { [unowned self] alert in alerts.append(alert) })

    /// 실제 계정과 분리한 Claude 경로·사용자 설정·캐시 DB 생성
    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(".claude-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)!
        preferences = PreferencesStore(userDefaults: defaults, defaultPaths: [home.path, "", "", ""], quotaDatabaseURL: home.appendingPathComponent("quota.sqlite"))
    }

    /// 구간 누락 또는 서버 사용률을 반환하는 순차 조회
    private func load(_ config: AccountConfig) -> AccountState {
        loads += 1
        let missing = missingLoads.contains(loads)
        if failedLoads.contains(loads) {
            return AccountState(id: config.id, email: "fixture@example.test", planType: "pro", status: .timeout, provider: .claude)
        }
        return AccountState(id: config.id, email: "fixture@example.test", planType: "pro",
            primaryUsedPercent: missing ? nil : used, secondaryUsedPercent: weekUsed,
            primaryResetAt: missing ? nil : reset, secondaryResetAt: weekReset,
            lastUpdated: now, status: .normal, provider: .claude)
    }

    /// 실제 대기 없는 재조회 간격과 대기 중 계정 변경 주입
    private func wait(_ seconds: TimeInterval) async {
        delays.append(seconds)
        advance(seconds)
        if changeAccountDuringSleep { store.reconfigure(pathStrings: ["", "", "", ""]) }
    }

    /// 벽시계와 단조 시계의 동일 간격 전진
    func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds); uptime += seconds }

    /// 임시 사용자 설정과 폴더 정리
    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: home)
    }
}
