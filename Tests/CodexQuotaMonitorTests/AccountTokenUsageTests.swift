// 목적: 서버 사용량 검증·미제공 구분·계정 격리와 실패 보존 검증
// 이용처: 서버 통계의 로컬 집계 오염 방지 회귀 테스트
// 사용방법: swift test --filter AccountTokenUsageTests
import Foundation
import SQLite3
import XCTest
@testable import CodexQuotaMonitorKit

@MainActor
final class AccountTokenUsageTests: XCTestCase {
    /// null·미제공·실제 0·빈 날짜 목록의 구분 검증
    func testNullableFieldsAndZero() async throws {
        let absent = try AccountTokenUsage(result: .object(["summary": .object([:])]))
        XCTAssertNil(absent.lifetimeTokens)
        XCTAssertNil(absent.days)
        let zero = try AccountTokenUsage(result: .object(["summary": .object(["lifetimeTokens": .number(0)]), "dailyUsageBuckets": .array([])]))
        XCTAssertEqual(zero.lifetimeTokens, 0)
        XCTAssertEqual(zero.days, [])
        let null = try AccountTokenUsage(result: .object(["summary": .object(["lifetimeTokens": .null]), "dailyUsageBuckets": .null]))
        XCTAssertNil(null.lifetimeTokens)
        XCTAssertNil(null.days)
    }

    /// 날짜 자동 보정·Boolean·소수·정밀도 손실·중복 합산의 거절 검증
    func testMalformedDataNeverBecomesZeroOrPartialSuccess() async throws {
        for count in [CodexJSONValue.bool(true), .number(-1), .number(1.5), .number(.infinity), .number(9_007_199_254_740_992)] {
            XCTAssertThrowsError(try AccountTokenUsage(result: .object(["summary": .object(["lifetimeTokens": count])])))
        }
        for date in ["2026-02-30", "2026-13-01", "2026-1-01", "0000-01-01", "2026-01-01\n"] {
            XCTAssertThrowsError(try AccountTokenUsage(result: payload(date: date)))
        }
        XCTAssertNoThrow(try AccountTokenUsage(result: payload(date: "2024-02-29")))
        let day: CodexJSONValue = .object(["startDate": .string("2026-01-01"), "tokens": .number(1)])
        XCTAssertThrowsError(try AccountTokenUsage(result: .object(["summary": .object([:]), "dailyUsageBuckets": .array([day, day])])))
    }

    /// 재진입 캐시·실패 후 정상값 유지·세대 및 로그인 계정 격리 검증
    func testStorePreservesSuccessAndSeparatesIdentity() async throws {
        let store = AccountTokenUsageStore()
        let account = AccountState(id: "C1", email: "one@example.test", status: .normal)
        let snapshot = try AccountTokenUsage(result: payload(date: "2026-10-23"))
        var calls = 0
        store.loader = { _ in calls += 1; return .success(snapshot) }
        await store.refresh(for: account)?.value
        XCTAssertNil(store.refresh(for: account))
        XCTAssertEqual(calls, 1)
        store.loader = { _ in .failure(.timeout) }
        await store.refresh(for: account, force: true)?.value
        XCTAssertEqual(store.snapshot(for: account), snapshot)
        XCTAssertTrue(store.hasFailed(for: account))
        var changed = account
        changed.configurationGeneration += 1
        XCTAssertNil(store.snapshot(for: changed))
        var loginChanged = account
        loginChanged.email = "two@example.test"
        XCTAssertNil(store.snapshot(for: loginChanged))
        store.invalidateAll()
        XCTAssertNil(store.snapshot(for: account))
    }

    /// 한 슬롯의 설정 변경이 다른 계정의 정상 서버 결과를 지우지 않는지 검증
    func testSlotInvalidationPreservesOtherAccounts() async throws {
        let store = AccountTokenUsageStore()
        let first = AccountState(id: "C1", status: .normal)
        let second = AccountState(id: "C2", status: .normal)
        let snapshot = try AccountTokenUsage(result: payload(date: "2026-10-23"))
        store.loader = { _ in .success(snapshot) }
        await store.refresh(for: first)?.value
        await store.refresh(for: second)?.value
        store.invalidate(accountID: first.id)
        await store.waitForPersistence()
        XCTAssertNil(store.snapshot(for: first))
        XCTAssertEqual(store.snapshot(for: second), snapshot)
    }

    /// 취소를 따르지 않는 이전 응답도 새 요청 결과를 덮어쓰지 않는지 검증
    func testInvalidationRejectsLateResponse() async throws {
        let store = AccountTokenUsageStore()
        let account = AccountState(id: "C1", status: .normal)
        let old = try AccountTokenUsage(result: payload(date: "2026-10-22"))
        let current = try AccountTokenUsage(result: payload(date: "2026-10-23"))
        let gate = UsageResponseGate()
        store.loader = { _ in await gate.wait(); return .success(old) }
        let first = try XCTUnwrap(store.refresh(for: account))
        await gate.waitUntilStarted()
        XCTAssertNil(store.refresh(for: account, force: true))
        store.invalidate(accountID: account.id)
        await store.waitForPersistence()
        store.loader = { _ in .success(current) }
        await store.refresh(for: account)?.value
        await gate.release()
        await first.value
        XCTAssertEqual(store.snapshot(for: account), current)
        XCTAssertFalse(store.isLoading(for: account))
    }

    /// 재시작·종료 후 마지막 정상값과 원래 조회 시각 복원 및 조회 실패 시 디스크 값 보존
    func testPersistentSnapshotSurvivesRestartAndFailedRefreshWithoutAutomaticQuery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("usage.sqlite")
        let homes = ["C1": directory.appendingPathComponent("account")]
        let account = AccountState(id: "C1", email: "one@example.test", status: .normal)
        let fetchedAt = Date().addingTimeInterval(-60)
        let snapshot = try AccountTokenUsage(result: payload(date: "2026-10-23"), fetchedAt: fetchedAt, accountEmail: account.email)
        let first = AccountTokenUsageStore(databaseURL: database)
        first.restore(accounts: [account], homes: homes)
        await first.waitForPersistence()
        first.loader = { _ in .success(snapshot) }
        await first.refresh(for: account)?.value
        XCTAssertNil(first.persistenceError)
        first.invalidateAll()

        let second = AccountTokenUsageStore(databaseURL: database)
        var calls = 0
        second.loader = { _ in calls += 1; return .failure(.timeout) }
        var initial = account
        initial.email = nil
        initial.status = .loading
        second.restore(accounts: [initial], homes: homes)
        await second.waitForPersistence()
        XCTAssertEqual(second.snapshot(for: initial), snapshot)
        second.restore(accounts: [account], homes: homes)
        await second.waitForPersistence()
        XCTAssertEqual(second.snapshot(for: account)?.fetchedAt, fetchedAt)
        XCTAssertEqual(calls, 0)
        await second.refresh(for: account, force: true)?.value
        XCTAssertTrue(second.hasFailed(for: account))
        let third = AccountTokenUsageStore(databaseURL: database)
        third.restore(accounts: [account], homes: homes)
        await third.waitForPersistence()
        XCTAssertEqual(third.snapshot(for: account), snapshot)
    }

    /// 슬롯·경로·로그인 계정 변경 시 다른 계정의 정상 캐시와 표시 범위 격리
    func testPersistentSnapshotSeparatesHomesAndLoginIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("usage.sqlite")
        let homes = ["C1": directory.appendingPathComponent("one"), "C2": directory.appendingPathComponent("two")]
        let one = AccountState(id: "C1", email: "one@example.test", status: .normal)
        let two = AccountState(id: "C2", email: "two@example.test", status: .normal)
        let first = AccountTokenUsageStore(databaseURL: database)
        first.restore(accounts: [one, two], homes: homes)
        await first.waitForPersistence()
        let snapshots = try Dictionary(uniqueKeysWithValues: [one, two].map { account in
            (account.id, try AccountTokenUsage(result: payload(date: "2026-10-23"), accountEmail: account.email))
        })
        first.loader = { account in .success(snapshots[account.id]!) }
        await first.refresh(for: one)?.value
        await first.refresh(for: two)?.value
        let restarted = AccountTokenUsageStore(databaseURL: database)
        var changedLogin = one
        changedLogin.email = "another@example.test"
        restarted.restore(accounts: [changedLogin, two], homes: homes)
        await restarted.waitForPersistence()
        XCTAssertNil(restarted.snapshot(for: changedLogin))
        XCTAssertNotNil(restarted.snapshot(for: two))
        var changedHomes = homes
        changedHomes["C1"] = directory.appendingPathComponent("new")
        restarted.restore(accounts: [one, two], homes: changedHomes)
        await restarted.waitForPersistence()
        XCTAssertNil(restarted.snapshot(for: one))
        let third = AccountTokenUsageStore(databaseURL: database)
        third.restore(accounts: [one, two], homes: homes)
        await third.waitForPersistence()
        XCTAssertNil(third.snapshot(for: one))
        XCTAssertNotNil(third.snapshot(for: two))
    }

    /// 할당량과 동일한 14일 만료 경계 및 미제공·실제 0의 저장 복원 검증
    func testPersistentSnapshotExpirationAndOptionalValues() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = SQLiteAccountTokenUsageStore(databaseURL: directory.appendingPathComponent("usage.sqlite"))
        let now = Date()
        for (index, result) in [
            CodexJSONValue.object(["summary": .object([:])]),
            .object(["summary": .object(["lifetimeTokens": .number(0)]), "dailyUsageBuckets": .array([])]),
            payload(date: "2026-10-23"),
        ].enumerated() {
            let snapshot = try AccountTokenUsage(result: result, fetchedAt: now)
            let home = "home-\(index)"
            try persistence.save(snapshot, home: home)
            XCTAssertEqual(try persistence.load(home: home, now: now), snapshot)
            XCTAssertNotNil(try persistence.load(home: home, now: now.addingTimeInterval(SQLiteAccountTokenUsageStore.lifetime - 1)))
            XCTAssertNil(try persistence.load(home: home, now: now.addingTimeInterval(SQLiteAccountTokenUsageStore.lifetime)))
        }
        try persistence.cleanup(homes: ["home-0"], now: now)
        XCTAssertNotNil(try persistence.load(home: "home-0", now: now))
        XCTAssertNil(try persistence.load(home: "home-1", now: now))
    }

    /// 디스크 쓰기 실패가 서버 정상값을 숨기거나 조회 실패로 바뀌지 않는지 검증
    func testStorageFailurePreservesSuccessfulServerSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountTokenUsageStore(databaseURL: directory)
        let account = AccountState(id: "C1", status: .normal)
        store.restore(accounts: [account], homes: ["C1": directory.appendingPathComponent("account")])
        await store.waitForPersistence()
        let snapshot = try AccountTokenUsage(result: payload(date: "2026-10-23"))
        store.loader = { _ in .success(snapshot) }
        await store.refresh(for: account)?.value
        XCTAssertEqual(store.snapshot(for: account), snapshot)
        XCTAssertFalse(store.hasFailed(for: account))
        XCTAssertNotNil(store.persistenceError)
    }

    /// 한 계정의 손상된 캐시가 다른 계정의 정상값 복원을 중단하지 않는지 검증
    func testCorruptCacheDoesNotBlockOtherAccounts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("usage.sqlite")
        let homes = ["C1": directory.appendingPathComponent("one"), "C2": directory.appendingPathComponent("two")]
        let persistence = SQLiteAccountTokenUsageStore(databaseURL: database)
        let snapshot = try AccountTokenUsage(result: payload(date: "2026-10-23"))
        try persistence.save(snapshot, home: homes["C1"]!.path)
        try persistence.save(snapshot, home: homes["C2"]!.path)
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &pointer), SQLITE_OK)
        let db = try XCTUnwrap(pointer)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "UPDATE account_token_usage_snapshots SET snapshot = X'7B' WHERE home_identity LIKE '%/one'", nil, nil, nil), SQLITE_OK)
        let store = AccountTokenUsageStore(databaseURL: database)
        let one = AccountState(id: "C1", status: .normal)
        let two = AccountState(id: "C2", status: .normal)
        store.restore(accounts: [one, two], homes: homes)
        await store.waitForPersistence()
        XCTAssertNil(store.snapshot(for: one))
        XCTAssertEqual(store.snapshot(for: two), snapshot)
        XCTAssertNotNil(store.persistenceError)
    }

    /// 이전 복원 예약 중 다른 슬롯 경로가 변경되어도 유지 계정 디스크 캐시 복원 검증
    func testRestoreReconfigurationDoesNotLoseUnchangedPendingHome() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("usage.sqlite")
        let firstHome = directory.appendingPathComponent("one").resolvingSymlinksInPath()
        let secondHome = directory.appendingPathComponent("two").resolvingSymlinksInPath()
        let persistence = SQLiteAccountTokenUsageStore(databaseURL: database)
        let snapshot = try AccountTokenUsage(result: payload(date: "2026-10-23"))
        try persistence.save(snapshot, home: firstHome.path)
        let accounts = [AccountState(id: "C1", status: .normal), AccountState(id: "C2", status: .normal)]
        let store = AccountTokenUsageStore(databaseURL: database)
        store.restore(accounts: accounts, homes: ["C1": firstHome, "C2": secondHome])
        store.restore(accounts: accounts, homes: ["C1": firstHome, "C2": directory.appendingPathComponent("new-two")])
        await store.waitForPersistence()
        XCTAssertEqual(store.snapshot(for: accounts[0]), snapshot)
        store.restore(accounts: accounts, homes: ["C1": firstHome, "C2": directory.appendingPathComponent("new-two")])
        await store.waitForPersistence()
        XCTAssertEqual(store.snapshot(for: accounts[0]), snapshot)
    }

    /// 비동기 복원 완료 전 명시적 무효화한 계정의 캐시 재등장 차단
    func testInvalidatingPendingRestoreDoesNotResurrectSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("usage.sqlite")
        let home = directory.appendingPathComponent("account").resolvingSymlinksInPath()
        let persistence = SQLiteAccountTokenUsageStore(databaseURL: database)
        let snapshot = try AccountTokenUsage(result: payload(date: "2026-10-23"))
        try persistence.save(snapshot, home: home.path)
        let account = AccountState(id: "C1", status: .normal)
        let store = AccountTokenUsageStore(databaseURL: database)
        store.restore(accounts: [account], homes: ["C1": home])
        store.invalidate(accountID: account.id)
        await store.waitForPersistence()
        XCTAssertNil(store.snapshot(for: account))
    }

    /// 동일 경로 복원 중 로그인 표시·설정 세대가 갱신되어도 최신 계정 키에 연결 검증
    func testPendingRestoreUsesLatestAccountIdentityAtCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("usage.sqlite")
        let home = directory.appendingPathComponent("account").resolvingSymlinksInPath()
        let persistence = SQLiteAccountTokenUsageStore(databaseURL: database)
        let snapshot = try AccountTokenUsage(result: payload(date: "2026-10-23"), accountEmail: "known@example.test")
        try persistence.save(snapshot, home: home.path)
        let initial = AccountState(id: "C1", status: .loading)
        var latest = initial
        latest.email = "known@example.test"
        latest.configurationGeneration = 1
        let store = AccountTokenUsageStore(databaseURL: database)
        store.restore(accounts: [initial], homes: ["C1": home])
        store.restore(accounts: [latest], homes: ["C1": home])
        await store.waitForPersistence()
        XCTAssertEqual(store.snapshot(for: latest), snapshot)
        XCTAssertNil(store.snapshot(for: initial))
    }

    /// 날짜가 있는 최소 서버 응답 구성
    private func payload(date: String) -> CodexJSONValue {
        .object(["summary": .object([:]), "dailyUsageBuckets": .array([
            .object(["startDate": .string(date), "tokens": .number(10)])
        ])])
    }
}

/// 응답 완료 시점을 제어하는 취소 비협조형 서버 대역
private actor UsageResponseGate {
    private var started = false
    private var pending: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    /// 테스트의 명시적 해제까지 응답 대기
    func wait() async {
        started = true
        observers.forEach { $0.resume() }
        observers.removeAll()
        await withCheckedContinuation { pending = $0 }
    }

    /// 서버 요청 진입 시점 대기
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { observers.append($0) }
    }

    /// 보관한 이전 응답 완료
    func release() {
        pending?.resume()
        pending = nil
    }
}
