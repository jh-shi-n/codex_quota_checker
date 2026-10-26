// 목적: 외부 초기화·원인 미상·일정 변경·관측 구간 격리 검증
// 이용처: 공통 초기화 판정과 계정 저장소 회귀 테스트
// 사용방법: swift test --filter QuotaResetChangeTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 정상 서버 스냅샷의 변화와 추정 원인의 독립성 검증
@MainActor
final class QuotaResetChangeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// 사용량 회복이 없어도 일정 변경과 유효 리셋권 소모가 함께 있으면 원인 분류 검증
    func testScheduleChangeWithCreditUseHasCreditCause() {
        var before = state(elapsed: 0)
        before.resetCredits = RateLimitResetCredits(availableCount: 1, credits: [
            .init(id: "fixture", expiresAt: start.addingTimeInterval(600))
        ])
        var after = state(elapsed: 10)
        after.primaryResetAt = start.addingTimeInterval(25_000)
        after.resetCredits = RateLimitResetCredits(availableCount: 0)
        let changes = QuotaResetChange.detect(previous: before, current: after, now: start.addingTimeInterval(10))
        XCTAssertEqual(changes.first?.kind, .scheduleChanged)
        XCTAssertEqual(changes.first?.cause, .resetCredit)
    }

    /// 리셋권 응답 부재에도 실제 회복 감지 및 원인 미상 분류 검증
    func testMissingCreditsDoNotSuppressExternalReset() {
        let before = state(elapsed: 0)
        var after = state(elapsed: 10)
        after.primaryUsedPercent = 0
        after.primaryResetAt = start.addingTimeInterval(25_000)
        let changes = QuotaResetChange.detect(previous: before, current: after, now: start.addingTimeInterval(10))
        XCTAssertEqual(changes.map(\.window), [.primary])
        XCTAssertEqual(changes.first?.kind, .reset)
        XCTAssertEqual(changes.first?.cause, .unknown)
    }

    /// 외부 사용과 소멸의 원인 분류 차이 및 초기화 감지 유지 검증
    func testCreditUseAndExpiryHaveDifferentCauses() {
        for expired in [false, true] {
            var before = state(elapsed: 0)
            before.resetCredits = RateLimitResetCredits(availableCount: 1, credits: [
                .init(id: "fixture", expiresAt: start.addingTimeInterval(expired ? 5 : 600))
            ])
            var after = state(elapsed: 10)
            after.resetCredits = RateLimitResetCredits(availableCount: 0)
            after.primaryUsedPercent = 0
            let changes = QuotaResetChange.detect(previous: before, current: after, now: start.addingTimeInterval(10))
            XCTAssertEqual(changes.first?.kind, .reset)
            XCTAssertEqual(changes.first?.cause, expired ? .unknown : .resetCredit)
        }
    }

    /// 시각만 변경되거나 리셋권 개수만 감소하면 초기화로 확정하지 않는지 검증
    func testScheduleOnlyChangeAndCreditOnlyDecreaseAreNotResets() {
        let before = state(elapsed: 0)
        var after = state(elapsed: 10)
        after.primaryResetAt = start.addingTimeInterval(25_000)
        let changes = QuotaResetChange.detect(previous: before, current: after, now: start.addingTimeInterval(10))
        XCTAssertEqual(changes.first?.kind, .scheduleChanged)
        after = state(elapsed: 10)
        after.resetCredits = RateLimitResetCredits(availableCount: 0)
        XCTAssertTrue(QuotaResetChange.detect(previous: before, current: after).isEmpty)
    }

    /// 도달 시각과 실제 사용량 회복이 결합된 정기 초기화 분류 검증
    func testScheduledResetRequiresRecovery() {
        var before = state(elapsed: 0)
        before.primaryResetAt = start.addingTimeInterval(5)
        var after = state(elapsed: 10)
        after.primaryUsedPercent = 0
        XCTAssertEqual(QuotaResetChange.detect(previous: before, current: after, now: start.addingTimeInterval(10)).first?.cause, .scheduled)
    }

    /// 한쪽 일정 변경과 벽시계 역행에서 구간별 재관측·최신 시각 수용 검증
    func testStoreSeparatesChangedWindowAndRecoversFromClockRollback() async throws {
        try await withStore { store, clock, source in
            for elapsed in [0.0, 10] {
                clock.wall = self.start.addingTimeInterval(elapsed)
                clock.uptime = elapsed
                await source.set(self.state(elapsed: elapsed))
                await store.refresh(accountID: "C1")
            }
            let before = try XCTUnwrap(store.state(for: "C1"))
            XCTAssertEqual(before.primaryResetObservation, .stableObserved)
            var changed = self.state(elapsed: 20)
            changed.primaryResetAt = self.start.addingTimeInterval(25_000)
            clock.wall = self.start.addingTimeInterval(20)
            clock.uptime = 20
            await source.set(changed)
            await store.refresh(accountID: "C1")
            let after = try XCTUnwrap(store.state(for: "C1"))
            XCTAssertEqual(after.primaryResetObservation, .checking)
            XCTAssertEqual(after.secondaryResetObservation, .stableObserved)
            XCTAssertNotEqual(after.primaryResetSegmentID, before.primaryResetSegmentID)
            XCTAssertEqual(after.secondaryResetSegmentID, before.secondaryResetSegmentID)
            XCTAssertEqual(after.resetChanges.first?.kind, .scheduleChanged)

            clock.wall = self.start.addingTimeInterval(15)
            clock.uptime = 30
            changed.lastUpdated = clock.wall
            await source.set(changed)
            await store.refresh(accountID: "C1")
            let rolledBack = try XCTUnwrap(store.state(for: "C1"))
            XCTAssertEqual(rolledBack.lastUpdated, clock.wall)
            XCTAssertEqual(rolledBack.primaryResetObservation, .checking)
            XCTAssertEqual(rolledBack.secondaryResetObservation, .checking)
            XCTAssertTrue(rolledBack.resetChanges.isEmpty)
        }
    }

    /// 신선도 범위 안의 중복·역순 응답으로 최신 상태가 후퇴하지 않는지 검증
    func testStoreRejectsDuplicateAndReorderedSnapshots() async throws {
        try await withStore { store, clock, source in
            for elapsed in [0.0, 10] {
                clock.wall = self.start.addingTimeInterval(elapsed)
                clock.uptime = elapsed
                await source.set(self.state(elapsed: elapsed))
                await store.refresh(accountID: "C1")
            }
            let original = try XCTUnwrap(store.state(for: "C1"))
            for (wall, response) in [(20.0, 10.0), (30.0, 1.0)] {
                clock.wall = self.start.addingTimeInterval(wall)
                clock.uptime = wall
                var stale = self.state(elapsed: response)
                stale.primaryUsedPercent = 0
                await source.set(stale)
                await store.refresh(accountID: "C1")
                XCTAssertEqual(store.state(for: "C1")?.lastUpdated, original.lastUpdated)
                XCTAssertEqual(store.state(for: "C1")?.primaryUsedPercent, original.primaryUsedPercent)
                XCTAssertEqual(store.state(for: "C1")?.primaryResetSegmentID, original.primaryResetSegmentID)
            }
        }
    }

    /// 실제 계정과 무관한 정상 한도 스냅샷 생성
    private func state(elapsed: TimeInterval) -> AccountState {
        AccountState(id: "C1", email: "fixture@example.invalid", planType: "plus",
            primaryUsedPercent: 60, secondaryUsedPercent: 30,
            primaryResetAt: start.addingTimeInterval(18_000), secondaryResetAt: start.addingTimeInterval(604_800),
            lastUpdated: start.addingTimeInterval(elapsed), status: .normal)
    }

    /// 사용자 설정과 분리된 저장소·서버 응답·이중 시계 제공
    private func withStore(_ body: @MainActor (AccountStore, ResetChangeClock, ResetChangeSource) async throws -> Void) async throws {
        let suite = "QuotaResetChangeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = ResetChangeSource()
        let clock = ResetChangeClock(wall: start)
        let store = AccountStore(configs: AccountConfig.accounts(for: ["/tmp/reset-change-fixture", "", "", ""]),
            preferencesStore: PreferencesStore(userDefaults: defaults), stateLoader: { _ in await source.read() })
        store.observationNow = { clock.wall }
        store.observationUptime = { clock.uptime }
        try await body(store, clock, source)
    }
}

/// 역순·중복을 포함한 정상 응답의 직접 주입 경계
private actor ResetChangeSource {
    var state = AccountState(id: "C1", status: .loading)
    /// 다음 서버 응답 교체
    func set(_ state: AccountState) { self.state = state }
    /// 주입한 응답 반환
    func read() -> AccountState { state }
}

/// 시스템 시각과 단조 시각을 독립 조절하는 fixture
@MainActor
private final class ResetChangeClock {
    var wall: Date
    var uptime: TimeInterval = 0
    /// 관측 기준 시각 초기화
    init(wall: Date) { self.wall = wall }
}
