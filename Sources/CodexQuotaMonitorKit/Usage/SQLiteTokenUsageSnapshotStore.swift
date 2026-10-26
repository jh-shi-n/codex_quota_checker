import Foundation
import SQLite3

/// 목적: 앱 전용 SQLite 토큰 사용량 스냅샷 저장소
/// 이용처: `TokenUsageSnapshotCache`의 재시작 복원과 만료 정리
/// 저장 범위: 계정 ID, 정규화 홈 식별자, 집계 payload, 갱신·만료 시각
final class SQLiteTokenUsageSnapshotStore: @unchecked Sendable {
    /// 영속 행 상한
    private static let maximumRows = 64
    private let databaseURL: URL
    private let errorLock = NSLock()
    private var cleanupFailed = false
    private var pendingAccountRemovals: Set<String> = []
    private var pendingRemoveAll = false

    /// 최근 정리 SQL 실패 상태의 동시성 보호 조회
    var hasCleanupFailure: Bool {
        errorLock.lock()
        defer { errorLock.unlock() }
        return cleanupFailed
    }

    /// 다음 정리 성공 시 해제되는 재시도 상태 기록
    private func recordCleanup(_ succeeded: Bool) {
        errorLock.lock()
        cleanupFailed = !succeeded || pendingRemoveAll || !pendingAccountRemovals.isEmpty
        errorLock.unlock()
    }


    /// 저장소 파일 경로 초기화
    init(databaseURL: URL) {
        self.databaseURL = databaseURL.standardizedFileURL
    }

    /// 계정·홈 조합의 유효한 집계 스냅샷 조회
    func load(
        accountID: String,
        homeIdentity: String,
        referenceDate: Date
    ) -> StoredTokenUsageSnapshot? {
        errorLock.lock()
        let blocked = pendingRemoveAll || pendingAccountRemovals.contains(accountID)
        errorLock.unlock()
        guard !blocked else { return nil }
        return withDatabase { database in
            let sql = """
            SELECT snapshot, updated_at, expires_at
            FROM token_usage_snapshots
            WHERE account_id = ? AND home_identity = ? AND expires_at > ?
            LIMIT 1
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                return nil
            }
            defer { sqlite3_finalize(statement) }
            guard bind(accountID, to: statement, at: 1),
                  bind(homeIdentity, to: statement, at: 2),
                  sqlite3_bind_double(statement, 3, referenceDate.timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW,
                  let blob = sqlite3_column_blob(statement, 0) else {
                return nil
            }
            let byteCount = Int(sqlite3_column_bytes(statement, 0))
            guard byteCount > 0 else { return nil }
            return StoredTokenUsageSnapshot(
                payload: Data(bytes: blob, count: byteCount),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                expiresAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            )
        } ?? nil
    }

    /// 하나의 계정·홈 조합에 최신 제한 payload 저장
    @discardableResult
    func save(
        payload: Data,
        accountID: String,
        homeIdentity: String,
        updatedAt: Date,
        expiresAt: Date
    ) -> Bool {
        withDatabase { database in
            guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                return false
            }
            defer { _ = sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }

            let sql = """
            INSERT INTO token_usage_snapshots
                (account_id, home_identity, snapshot, updated_at, expires_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(account_id, home_identity) DO UPDATE SET
                snapshot = excluded.snapshot,
                updated_at = excluded.updated_at,
                expires_at = excluded.expires_at
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                return false
            }
            defer { sqlite3_finalize(statement) }
            guard bind(accountID, to: statement, at: 1),
                  bind(homeIdentity, to: statement, at: 2),
                  bind(payload, to: statement, at: 3),
                  sqlite3_bind_double(statement, 4, updatedAt.timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_bind_double(statement, 5, expiresAt.timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE,
                  sqlite3_exec(database, Self.pruneRowsSQL, nil, nil, nil) == SQLITE_OK,
                  sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                return false
            }
            return true
        } ?? false
    }

    /// 계정에 저장된 모든 홈 행 제거
    func remove(accountID: String) {
        let succeeded = withDatabase { database in
            execute(database, sql: "DELETE FROM token_usage_snapshots WHERE account_id = ?") { statement in
                bind(accountID, to: statement, at: 1)
            }
        } ?? false
        errorLock.lock()
        if succeeded { pendingAccountRemovals.remove(accountID) }
        else { pendingAccountRemovals.insert(accountID) }
        errorLock.unlock()
        recordCleanup(succeeded)
    }

    /// 저장소 전체 스냅샷 제거
    func removeAll() {
        let succeeded = withDatabase { database in
            sqlite3_exec(database, "DELETE FROM token_usage_snapshots", nil, nil, nil) == SQLITE_OK
        } ?? false
        errorLock.lock()
        pendingRemoveAll = !succeeded
        if succeeded { pendingAccountRemovals.removeAll() }
        errorLock.unlock()
        recordCleanup(succeeded)
    }

    /// 기준 시각까지 만료된 행 제거
    func purgeExpired(beforeOrAt referenceDate: Date) {
        errorLock.lock()
        let retryAll = pendingRemoveAll
        let retryAccounts = pendingAccountRemovals
        errorLock.unlock()
        if retryAll { removeAll() }
        else { for accountID in retryAccounts { remove(accountID: accountID) } }
        let succeeded = withDatabase { database in
            execute(database, sql: "DELETE FROM token_usage_snapshots WHERE expires_at <= ?") { statement in
                sqlite3_bind_double(statement, 1, referenceDate.timeIntervalSince1970) == SQLITE_OK
            }
        } ?? false
        recordCleanup(succeeded)
    }

    private static let pruneRowsSQL = """
    DELETE FROM token_usage_snapshots
    WHERE rowid IN (
        SELECT rowid FROM token_usage_snapshots
        ORDER BY updated_at DESC, account_id ASC, home_identity ASC
        LIMIT -1 OFFSET \(maximumRows)
    )
    """

    /// 데이터베이스 연결 생성·종료와 작업 실행
    private func withDatabase<T>(_ body: (OpaquePointer) -> T?) -> T? {
        do {
            try PrivateSQLiteFiles.prepare(databaseURL)
        } catch {
            return nil
        }

        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database); try? PrivateSQLiteFiles.secureExisting(databaseURL) }
        guard sqlite3_busy_timeout(database, 250) == SQLITE_OK,
              ensureSchema(database) else {
            return nil
        }
        return body(database)
    }

    /// 앱 소유 토큰 snapshot 테이블과 만료 인덱스 보장
    private func ensureSchema(_ database: OpaquePointer) -> Bool {
        let sql = """
        CREATE TABLE IF NOT EXISTS token_usage_snapshots (
            account_id TEXT NOT NULL,
            home_identity TEXT NOT NULL,
            snapshot BLOB NOT NULL,
            updated_at REAL NOT NULL,
            expires_at REAL NOT NULL,
            PRIMARY KEY (account_id, home_identity)
        );
        CREATE INDEX IF NOT EXISTS token_usage_snapshots_expiry
            ON token_usage_snapshots(expires_at);
        """
        return sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
    }

    /// 단일 SQL 명령 준비·바인딩·실행
    private func execute(
        _ database: OpaquePointer,
        sql: String,
        bindValues: (OpaquePointer) -> Bool
    ) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        guard bindValues(statement) else { return false }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    /// 텍스트 값의 SQLite 바인딩
    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) -> Bool {
        value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, Self.transientDestructor()) == SQLITE_OK
        }
    }

    /// BLOB 값의 SQLite 바인딩
    private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) -> Bool {
        value.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            return sqlite3_bind_blob(
                statement,
                index,
                baseAddress,
                Int32(buffer.count),
                Self.transientDestructor()
            ) == SQLITE_OK
        }
    }

    /// SQLite가 바인딩 값을 즉시 복사하는 소멸자
    private static func transientDestructor() -> sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}

/// SQLite에서 복원한 집계 payload와 시각
struct StoredTokenUsageSnapshot {
    let payload: Data
    let updatedAt: Date
    let expiresAt: Date
}

