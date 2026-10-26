// 목적: 조기 리셋 판별과 정상 조회·영속 스냅샷 연동 검증
// 이용처: 할당량 알림 회귀 테스트
// 사용방법: swift test --filter EarlyQuotaResetTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 정상 만료·조기 초기화·오류 복구·중복 조회의 알림 구분 검증
@MainActor
final class EarlyQuotaResetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 두 한도의 동시 초기화와 초기화 직후 일부 사용된 새 구간 감지 확인
    func testDetectsIndependentAndCombinedResets() {
        let previous = snapshot()
        let primaryOnly = state(primary: 0, secondary: 70)
        XCTAssertEqual(
            EarlyQuotaReset.detect(previous: previous, current: primaryOnly, now: now)?.windows,
            [.primary]
        )
        let secondaryOnly = state(primary: 60, secondary: 0)
        XCTAssertEqual(
            EarlyQuotaReset.detect(previous: previous, current: secondaryOnly, now: now)?.windows,
            [.secondary]
        )
        let both = state(primary: 2, secondary: 3, reset: now.addingTimeInterval(7_200))
        let event = EarlyQuotaReset.detect(previous: previous, current: both, now: now)
        XCTAssertEqual(event?.accountID, "C1")
        XCTAssertEqual(event?.windows, [.primary, .secondary])
    }

    /// 첫 조회·정상 만료·누락 값·오류·시각 보정만 발생한 경우 제외 확인
    func testIgnoresObservationsWithoutEvidenceOfEarlyReset() {
        XCTAssertNil(EarlyQuotaReset.detect(previous: nil, current: state(primary: 0), now: now))
        for status: AccountStatus in [.loading, .timeout, .error, .loginRequired, .notConfigured] {
            XCTAssertNil(EarlyQuotaReset.detect(
                previous: snapshot(), current: state(primary: 0, status: status), now: now
            ))
        }
        for reset in [now.addingTimeInterval(-1), now] {
            XCTAssertNil(EarlyQuotaReset.detect(
                previous: snapshot(reset: reset), current: state(primary: 0), now: now
            ))
        }
        XCTAssertNil(EarlyQuotaReset.detect(
            previous: snapshot(reset: nil), current: state(primary: 0), now: now
        ))
        XCTAssertNil(EarlyQuotaReset.detect(
            previous: snapshot(), current: state(primary: nil), now: now
        ))
        XCTAssertNil(EarlyQuotaReset.detect(
            previous: snapshot(), current: state(primary: 59), now: now
        ))
        XCTAssertNil(EarlyQuotaReset.detect(
            previous: snapshot(),
            current: state(primary: 60, reset: now.addingTimeInterval(7_199)),
            now: now
        ))
    }

    /// 리셋 시각이 없어지는 완전 초기화 및 사용량 변화 없는 재조회 구분 확인
    func testDetectsZeroUsageWithoutNewResetDateAndIgnoresUnchangedZero() {
        let current = state(primary: 0, secondary: 0, reset: nil)
        XCTAssertEqual(
            EarlyQuotaReset.detect(previous: snapshot(), current: current, now: now)?.windows,
            [.primary, .secondary]
        )
        let zero = PreferencesStore.QuotaSnapshot(
            usedPercent: 0, resetAt: now.addingTimeInterval(3_600)
        )
        XCTAssertNil(EarlyQuotaReset.detect(previous: zero, current: current, now: now))
    }

    /// 오류 이후 마지막 정상 스냅샷 비교 및 저장·재시작에 따른 중복 알림 방지 확인
    func testAccountStoreNotifiesOnceAcrossFailureRefreshAndRestart() async {
        let suite = "EarlyQuotaResetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(userDefaults: defaults)
        let reset = Date().addingTimeInterval(3_600)
        let loader = ResetStateLoader(states: [
            AccountState(id: "C1", primaryUsedPercent: 60, secondaryUsedPercent: 70,
                         primaryResetAt: reset, secondaryResetAt: reset,
                         resetCredits: RateLimitResetCredits(availableCount: 0), status: .normal),
            AccountState(id: "C1", status: .timeout),
            AccountState(id: "C1", primaryUsedPercent: 0, secondaryUsedPercent: 0,
                         primaryResetAt: reset, secondaryResetAt: reset,
                         resetCredits: RateLimitResetCredits(availableCount: 0), status: .normal),
        ])
        let configs = AccountConfig.defaultAccounts()
        let store = AccountStore(configs: configs, preferencesStore: preferences) { _ in
            await loader.next()
        }
        var events: [EarlyQuotaReset] = []
        store.onEarlyQuotaReset = { events.append($0) }
        await store.refresh(accountID: "C1")
        XCTAssertTrue(events.isEmpty)
        await store.refresh(accountID: "C1")
        XCTAssertTrue(events.isEmpty)
        await store.refreshAll()
        XCTAssertEqual(events.map(\.accountID), ["C1"])
        XCTAssertEqual(events.first?.windows, [.primary, .secondary])
        await store.refresh(accountID: "C1")
        XCTAssertEqual(events.count, 1)

        let restored = AccountStore(
            configs: configs, preferencesStore: PreferencesStore(userDefaults: defaults)
        ) { _ in await loader.next() }
        restored.onEarlyQuotaReset = { events.append($0) }
        await restored.refresh(accountID: "C1")
        XCTAssertEqual(events.count, 1)

        store.reconfigure(pathStrings: ["/tmp/\(UUID().uuidString)", "", "", ""])
        await store.refresh(accountID: "C1")
        XCTAssertEqual(events.count, 1)
    }

    /// 리셋권 사용·소멸 정보가 초기화 감지 자체를 차단하지 않는지 확인
    func testResetCreditUsageAndAmbiguousExpiryDoNotHideRecovery() {
        let active = RateLimitResetCredits.Credit(id: "active", expiresAt: now.addingTimeInterval(600))
        let expired = RateLimitResetCredits.Credit(id: "expired", expiresAt: now.addingTimeInterval(-1))
        var current = state(primary: 0)
        current.resetCredits = RateLimitResetCredits(availableCount: 0)
        for credits in [
            RateLimitResetCredits(availableCount: 1, credits: [active]),
            RateLimitResetCredits(availableCount: 1),
        ] {
            let before = PreferencesStore.QuotaSnapshot(
                usedPercent: 60, resetAt: now.addingTimeInterval(3_600), resetCredits: credits
            )
            XCTAssertNotNil(EarlyQuotaReset.detect(previous: before, current: current, now: now))
        }
        let expiredBefore = PreferencesStore.QuotaSnapshot(
            usedPercent: 60, resetAt: now.addingTimeInterval(3_600),
            resetCredits: RateLimitResetCredits(availableCount: 1, credits: [expired])
        )
        XCTAssertNotNil(EarlyQuotaReset.detect(previous: expiredBefore, current: current, now: now))
        current.resetCredits = nil
        XCTAssertNotNil(EarlyQuotaReset.detect(previous: snapshot(), current: current, now: now))
        let legacyBefore = PreferencesStore.QuotaSnapshot(usedPercent: 60, resetAt: now.addingTimeInterval(3_600))
        current.resetCredits = RateLimitResetCredits(availableCount: 0)
        XCTAssertNotNil(EarlyQuotaReset.detect(previous: legacyBefore, current: current, now: now))
    }

    /// 최초 캐시 복원과 실제 초기화 이벤트의 혼동 방지 검증
    func testCachedWeeklyRecoveryDoesNotNotifyOnFirstServerReading() async {
        let suite = "WeeklyResetRegression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(userDefaults: defaults)
        let reference = Date()
        let credits = RateLimitResetCredits(availableCount: 3, credits: (1...3).map {
            .init(id: "fixture-\($0)", expiresAt: reference.addingTimeInterval(10 * 86_400))
        })
        let config = AccountConfig.defaultAccounts()[3]
        preferences.updateQuotaSnapshot(for: config.home, snapshot: .init(
            usedPercent: 4,
            resetAt: reference.addingTimeInterval(2 * 3_600),
            secondaryUsedPercent: 11,
            secondaryResetAt: reference.addingTimeInterval(5 * 86_400),
            resetCredits: credits,
            lastUpdated: reference.addingTimeInterval(-300)
        ))
        let fresh = AccountState(
            id: config.id,
            primaryUsedPercent: 0,
            secondaryUsedPercent: 0,
            primaryResetAt: reference.addingTimeInterval(5 * 3_600),
            secondaryResetAt: reference.addingTimeInterval(7 * 86_400),
            resetCredits: credits,
            lastUpdated: reference,
            status: .normal
        )
        let store = AccountStore(preferencesStore: preferences) { _ in fresh }
        var events: [EarlyQuotaReset] = []
        store.onEarlyQuotaReset = { events.append($0) }

        await store.refresh(accountID: config.id)
        await store.refresh(accountID: config.id)

        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(store.state(for: "C4")?.secondaryUsedPercent, 0)
        XCTAssertEqual(preferences.quotaSnapshot(for: config.home)?.secondaryUsedPercent, 0)
    }

    /// 고정 기준 시각의 이전 정상 스냅샷 구성
    private func snapshot(reset: Date? = Date(timeIntervalSince1970: 1_800_003_600)) -> PreferencesStore.QuotaSnapshot {
        PreferencesStore.QuotaSnapshot(
            usedPercent: 60,
            resetAt: reset,
            secondaryUsedPercent: 70,
            secondaryResetAt: reset,
            resetCredits: RateLimitResetCredits(availableCount: 0)
        )
    }

    /// 지정 사용량과 상태를 가진 조회 결과 생성
    private func state(
        primary: Double? = 60,
        secondary: Double? = 70,
        reset: Date? = Date(timeIntervalSince1970: 1_800_003_600),
        status: AccountStatus = .normal
    ) -> AccountState {
        AccountState(
            id: "C1", primaryUsedPercent: primary, secondaryUsedPercent: secondary,
            primaryResetAt: reset, secondaryResetAt: reset,
            resetCredits: RateLimitResetCredits(availableCount: 0), status: status
        )
    }
}

/// 순서대로 결과를 반환하고 마지막 결과를 유지하는 테스트 로더
private actor ResetStateLoader {
    private var states: [AccountState]

    /// 조회 순서의 고정 결과 보관
    init(states: [AccountState]) {
        self.states = states
    }

    /// 마지막 결과를 보존하면서 다음 조회 결과 반환
    func next() -> AccountState {
        var state = states.count > 1 ? states.removeFirst() : states[0]
        state.lastUpdated = Date()
        return state
    }
}
