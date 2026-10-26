// 목적: 재실행 전후 고정 관측 근거의 저장·복원·폐기 검증
// 이용처: c2의 확정 시각 유지 및 미확인 계정의 잘못된 복원 방지
// 사용방법: swift test --filter ResetEvidencePersistenceTests
import XCTest
@testable import CodexQuotaMonitorKit

/// 실제 요청 없이 경로별 SQLite 캐시와 모의 응답으로 수행하는 회귀 검증
@MainActor
final class ResetEvidencePersistenceTests: XCTestCase {
    /// 서로 다른 두 정상 조회의 고정 근거가 SQLite에 저장되는지 검증
    func testNewStableObservationIsSavedForRestart() async throws {
        let fixture = try EvidenceFixture()
        defer { fixture.cleanup() }
        let start = Date().addingTimeInterval(-30)
        let states = [0.0, 10].map { elapsed in
            AccountState(id: "C2", email: "fixture@example.invalid", planType: "plus",
                primaryResetAt: fixture.reset, lastUpdated: start.addingTimeInterval(elapsed), status: .normal)
        }
        let source = EvidenceSource(states: states)
        let store = AccountStore(configs: fixture.configs, preferencesStore: fixture.preferences) { _ in await source.read() }
        store.observationNow = { start }
        store.observationUptime = { 0 }
        await store.refresh(accountID: "C2", forceFresh: true)
        XCTAssertNil(fixture.preferences.quotaSnapshot(for: fixture.configs[1].home)?.primaryResetEvidence)
        store.observationNow = { start.addingTimeInterval(10) }
        store.observationUptime = { 10 }
        await store.refresh(accountID: "C2", forceFresh: true)
        XCTAssertNotNil(fixture.preferences.quotaSnapshot(for: fixture.configs[1].home)?.primaryResetEvidence)
        let restarted = await fixture.store(returning: states[1])
        XCTAssertEqual(restarted.state(for: "C2")?.primaryResetObservation, .stableObserved)
    }

    /// 고정 근거 복원과 첫 동일 응답의 관측 유지 및 다음 재실행 복원 검증
    func testStableEvidenceSurvivesRestartAndFirstMatchingResponse() async throws {
        let fixture = try EvidenceFixture()
        defer { fixture.cleanup() }
        fixture.saveEvidence()
        let now = Date()
        let account = AccountState(id: "C2", email: "fixture@example.invalid", planType: "plus",
            primaryResetAt: fixture.reset, lastUpdated: now, status: .normal)
        let store = await fixture.store(returning: account)
        let restored = try XCTUnwrap(store.state(for: "C2"))
        XCTAssertEqual(restored.primaryResetObservation, .stableObserved)
        XCTAssertEqual(AccountDashboardFormatting.observedResetDate(restored.primaryResetAt,
            observation: restored.primaryResetObservation, status: restored.status), fixture.reset)
        store.observationNow = { now }
        await store.refresh(accountID: "C2", forceFresh: true)
        XCTAssertEqual(store.state(for: "C2")?.primaryResetObservation, .stableObserved)
        let reloaded = await fixture.store(returning: account)
        XCTAssertEqual(reloaded.state(for: "C2")?.primaryResetEvidence?.resetAt, fixture.reset)
        XCTAssertEqual(reloaded.state(for: "C2")?.email, account.email)
    }

    /// 로그인·구독·일정 변경에서 이전 고정 근거 폐기 검증
    func testChangedIdentityOrScheduleDiscardsEvidence() async throws {
        for change in ["email", "plan", "reset"] {
            let fixture = try EvidenceFixture()
            defer { fixture.cleanup() }
            fixture.saveEvidence()
            let now = Date()
            let account = AccountState(id: "C2",
                email: change == "email" ? "other@example.invalid" : "fixture@example.invalid",
                planType: change == "plan" ? "pro" : "plus",
                primaryResetAt: fixture.reset.addingTimeInterval(change == "reset" ? 300 : 0),
                lastUpdated: now, status: .normal)
            let store = await fixture.store(returning: account)
            store.observationNow = { now }
            await store.refresh(accountID: "C2", forceFresh: true)
            XCTAssertEqual(store.state(for: "C2")?.primaryResetObservation, .checking)
            XCTAssertNil(store.state(for: "C2")?.primaryResetEvidence)
        }
    }

    /// 만료·미래 관측·다른 시각의 근거와 이전 버전 캐시의 확정 표시 차단
    func testInvalidOrMissingEvidenceDoesNotRestoreStability() async throws {
        let fixture = try EvidenceFixture()
        defer { fixture.cleanup() }
        let now = Date()
        for evidence in [nil,
            ResetTimeEvidence(resetAt: now.addingTimeInterval(-1), observedAt: now.addingTimeInterval(-10)),
            ResetTimeEvidence(resetAt: fixture.reset, observedAt: now.addingTimeInterval(60)),
            ResetTimeEvidence(resetAt: fixture.reset.addingTimeInterval(300), observedAt: now)] {
            fixture.saveEvidence(evidence)
            let store = await fixture.store(returning: AccountState(id: "C2", status: .normal))
            XCTAssertEqual(store.state(for: "C2")?.primaryResetObservation, .checking)
            XCTAssertNil(store.state(for: "C2")?.primaryResetEvidence)
        }
    }
}

/// 사용자 데이터와 분리한 한 계정의 경로·캐시·모의 응답 구성
@MainActor
private final class EvidenceFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let reset = Date().addingTimeInterval(18_000)
    let defaults = UserDefaults(suiteName: "CodexQuotaMonitorTests.\(UUID().uuidString)")!
    let configs: [AccountConfig]
    let preferences: PreferencesStore

    /// 임시 경로의 SQLite 저장소 연결
    init() throws {
        let directory = root
        configs = AccountConfig.accounts(for: (1...4).map { directory.appendingPathComponent("c\($0)").path })
        preferences = PreferencesStore(userDefaults: defaults, defaultPaths: configs.map { $0.home.path },
            quotaDatabaseURL: root.appendingPathComponent("quota.sqlite"))
    }

    /// 유효 고정 관측 근거를 저장하는 기본 fixture
    func saveEvidence() {
        saveEvidence(ResetTimeEvidence(resetAt: reset, observedAt: Date().addingTimeInterval(-60)))
    }

    /// 지정 근거 또는 이전 버전과 같은 근거 없는 스냅샷 저장
    func saveEvidence(_ evidence: ResetTimeEvidence?) {
        preferences.updateQuotaSnapshot(for: configs[1].home, snapshot: .init(
            usedPercent: 0, resetAt: reset, lastUpdated: Date().addingTimeInterval(-30),
            email: "fixture@example.invalid", planType: "plus", primaryResetEvidence: evidence))
    }

    /// SQLite를 새 설정 객체로 다시 읽고 모의 응답 연결
    func store(returning account: AccountState) async -> AccountStore {
        await preferences.waitForCacheIO()
        let reloaded = PreferencesStore(userDefaults: defaults, defaultPaths: configs.map { $0.home.path },
            quotaDatabaseURL: root.appendingPathComponent("quota.sqlite"))
        await reloaded.waitForCacheIO()
        return AccountStore(configs: configs, preferencesStore: reloaded) { _ in account }
    }

    /// 테스트 SQLite와 임시 경로 제거
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

/// 정상 조회 두 건의 시간 순서 보장용 모의 응답 공급
private actor EvidenceSource {
    private var states: [AccountState]

    /// 서버 대신 반환할 스냅샷 지정
    init(states: [AccountState]) { self.states = states }

    /// 다음 정상 조회 응답 반환
    func read() -> AccountState { states.removeFirst() }
}
