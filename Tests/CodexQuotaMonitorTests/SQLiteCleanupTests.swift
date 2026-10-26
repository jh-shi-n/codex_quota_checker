// 목적: SQLite 캐시의 보존 경계·행 상한·정리 실패 재시도 검증
import Foundation
import SQLite3
import XCTest
@testable import CodexQuotaMonitorKit

/// 앱 원본 데이터와 분리된 SQLite 정리 정책 회귀 검증
@MainActor
final class SQLiteCleanupTests: XCTestCase {
    /// 외부 SQLite 쓰기 잠금 대기 중에도 MainActor 응답과 메모리 캐시 갱신 유지
    func testLockedDatabaseDoesNotBlockMainActor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let database = root.appendingPathComponent("usage.sqlite")
        let preferences = PreferencesStore(userDefaults: defaults, defaultPaths: [root.path, "", "", ""], quotaDatabaseURL: database)
        await preferences.waitForCacheIO()
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &pointer), SQLITE_OK)
        let db = try XCTUnwrap(pointer)
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)
        let started = Date()
        preferences.updateQuotaSnapshot(for: root, snapshot: .init(usedPercent: 42, lastUpdated: Date()))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.15)
        XCTAssertEqual(preferences.quotaSnapshot(for: root)?.usedPercent, 42)
        await preferences.waitForCacheIO()
        XCTAssertNotNil(preferences.cacheError)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    /// 기존 0755 디렉터리·0644 DB와 sidecar의 사용자 전용 권한 보정
    func testExistingDatabaseAndSidecarPermissionsAreRestricted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let database = root.appendingPathComponent("usage.sqlite")
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let path = database.path + suffix
            FileManager.default.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o644])
        }
        try PrivateSQLiteFiles.prepare(database)
        let directoryMode = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int
        XCTAssertEqual(directoryMode, 0o700)
        for suffix in ["", "-wal", "-shm", "-journal"] {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: database.path + suffix)[.posixPermissions] as? Int, 0o600)
        }
    }

    /// 최신 64행·등록 경로·14일 만료 경계의 독립 적용 검증
    func testQuotaRetentionCountPathsAndExpiryBoundary() throws {
        try withDatabase { database in
            let store = SQLiteQuotaSnapshotStore(databaseURL: database)
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            var snapshots: [String: PreferencesStore.QuotaSnapshot] = [:]
            for index in 0..<70 {
                snapshots["/account/\(index)"] = PreferencesStore.QuotaSnapshot(
                    usedPercent: 10, lastUpdated: now.addingTimeInterval(Double(index)))
            }
            try store.save(snapshots, now: now)
            try store.cleanup(registeredPaths: Set(snapshots.keys), now: now)
            let limited = try store.load(now: now)
            XCTAssertEqual(limited.count, 64)
            XCTAssertNil(limited["/account/0"])
            XCTAssertNotNil(limited["/account/69"])
            try store.cleanup(registeredPaths: ["/account/69"], now: now)
            XCTAssertEqual(try store.load(now: now).count, 1)
            let expiry = now.addingTimeInterval(69 + SQLiteQuotaSnapshotStore.lifetime)
            XCTAssertEqual(try store.load(now: expiry.addingTimeInterval(-0.001)).count, 1)
            try store.cleanup(registeredPaths: ["/account/69"], now: expiry)
            XCTAssertTrue(try store.load(now: expiry).isEmpty)
        }
    }

    /// 삭제 실패를 호출자에 전달하고 실패 원인 제거 후 재시도하는지 검증
    func testQuotaCleanupFailurePreservesRowsAndCanRetry() throws {
        try withDatabase { database in
            let store = SQLiteQuotaSnapshotStore(databaseURL: database)
            let now = Date()
            try store.save(["/account": PreferencesStore.QuotaSnapshot(usedPercent: 25, lastUpdated: now)])
            try execute(database, "CREATE TRIGGER block_quota_delete BEFORE DELETE ON quota_snapshots BEGIN SELECT RAISE(FAIL, 'fixture'); END")
            XCTAssertThrowsError(try store.cleanup(registeredPaths: [], now: now))
            XCTAssertEqual(try store.load(now: now).count, 1)
            try execute(database, "DROP TRIGGER block_quota_delete")
            try store.cleanup(registeredPaths: [], now: now)
            XCTAssertTrue(try store.load(now: now).isEmpty)
        }
    }

    /// 토큰 캐시 삭제 SQL 오류의 상태 노출과 다음 성공 시 해제 검증
    func testTokenCleanupFailureIsTrackedAndRetryClearsFailure() throws {
        try withDatabase { database in
            let store = SQLiteTokenUsageSnapshotStore(databaseURL: database)
            let now = Date()
            XCTAssertTrue(store.save(payload: Data("fixture".utf8), accountID: "C1", homeIdentity: "/account",
                                     updatedAt: now, expiresAt: now.addingTimeInterval(60)))
            try execute(database, "CREATE TRIGGER block_token_delete BEFORE DELETE ON token_usage_snapshots BEGIN SELECT RAISE(FAIL, 'fixture'); END")
            store.remove(accountID: "C1")
            XCTAssertTrue(store.hasCleanupFailure)
            XCTAssertNil(store.load(accountID: "C1", homeIdentity: "/account", referenceDate: now))
            try execute(database, "DROP TRIGGER block_token_delete")
            store.purgeExpired(beforeOrAt: now)
            XCTAssertFalse(store.hasCleanupFailure)
            XCTAssertNil(store.load(accountID: "C1", homeIdentity: "/account", referenceDate: now))
        }
    }

    /// 테스트 전용 SQL 연결과 명령 실패 전달
    private func execute(_ url: URL, _ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    /// 인증 파일과 사용자 DB를 참조하지 않는 임시 저장소 수명 관리
    private func withDatabase(_ operation: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try operation(root.appendingPathComponent("token-usage.sqlite"))
    }
}
