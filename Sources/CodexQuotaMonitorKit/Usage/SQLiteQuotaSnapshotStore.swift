// 목적: 경로별 정상 할당량의 SQLite 저장·이관·복원
import Foundation
import SQLite3

/// 토큰 DB의 별도 테이블에 보관하는 할당량 캐시
final class SQLiteQuotaSnapshotStore: Sendable {
    private let databaseURL: URL
    static let lifetime: TimeInterval = 14 * 24 * 60 * 60

    /// 기존 토큰 DB 또는 테스트용 DB 연결
    init(databaseURL: URL) { self.databaseURL = databaseURL }

    /// 연결 수명과 스키마 보장 및 SQL 실패 전달
    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try PrivateSQLiteFiles.prepare(databaseURL)
        var pointer: OpaquePointer?
        let code = sqlite3_open_v2(databaseURL.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let db = pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(db); try? PrivateSQLiteFiles.secureExisting(databaseURL) }
        sqlite3_busy_timeout(db, 250)
        try execute(db, "CREATE TABLE IF NOT EXISTS quota_snapshots (home_identity TEXT PRIMARY KEY, snapshot BLOB NOT NULL, updated_at REAL NOT NULL, expires_at REAL NOT NULL)")
        return try body(db)
    }

    /// SQL 실행 결과의 오류 변환
    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    /// 하나 이상의 경로를 같은 트랜잭션으로 이관·갱신
    func save(_ snapshots: [String: PreferencesStore.QuotaSnapshot], now: Date = Date()) throws {
        try withDatabase { db in
            try execute(db, "BEGIN IMMEDIATE")
            defer { _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
            for (path, snapshot) in snapshots {
                let data = try JSONEncoder().encode(snapshot)
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO quota_snapshots VALUES (?, ?, ?, ?)", -1, &statement, nil) == SQLITE_OK,
                      let statement else { throw CocoaError(.fileWriteUnknown) }
                defer { sqlite3_finalize(statement) }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                let pathCode = path.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
                let dataCode = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient) }
                let updated = snapshot.lastUpdated ?? now
                guard pathCode == SQLITE_OK, dataCode == SQLITE_OK,
                      sqlite3_bind_double(statement, 3, updated.timeIntervalSince1970) == SQLITE_OK,
                      sqlite3_bind_double(statement, 4, updated.addingTimeInterval(Self.lifetime).timeIntervalSince1970) == SQLITE_OK,
                      sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
            }
            try execute(db, "COMMIT")
        }
    }

    /// 만료 이전 캐시의 경로별 복원
    func load(now: Date = Date()) throws -> [String: PreferencesStore.QuotaSnapshot] {
        try withDatabase { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT home_identity, snapshot FROM quota_snapshots WHERE expires_at > ?", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw CocoaError(.fileReadUnknown) }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
            var values: [String: PreferencesStore.QuotaSnapshot] = [:]
            var code = sqlite3_step(statement)
            while code == SQLITE_ROW {
                guard let path = sqlite3_column_text(statement, 0), let blob = sqlite3_column_blob(statement, 1) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 1)))
                values[String(cString: path)] = try JSONDecoder().decode(PreferencesStore.QuotaSnapshot.self, from: data)
                code = sqlite3_step(statement)
            }
            guard code == SQLITE_DONE else { throw CocoaError(.fileReadUnknown) }
            return values
        }
    }

    /// 만료·미등록 경로 제거 및 최신 64행 유지; 실패 시 다음 주기에 재시도
    func cleanup(registeredPaths: Set<String>, now: Date = Date()) throws {
        try withDatabase { db in
            try execute(db, "BEGIN IMMEDIATE")
            defer { _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT home_identity FROM quota_snapshots", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw CocoaError(.fileReadUnknown) }
            var removed: [String] = []
            var code = sqlite3_step(statement)
            while code == SQLITE_ROW {
                if let raw = sqlite3_column_text(statement, 0) {
                    let path = String(cString: raw)
                    if !registeredPaths.contains(path) { removed.append(path) }
                }
                code = sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
            guard code == SQLITE_DONE else { throw CocoaError(.fileReadUnknown) }
            for path in removed {
                var deletion: OpaquePointer?
                guard sqlite3_prepare_v2(db, "DELETE FROM quota_snapshots WHERE home_identity = ?", -1, &deletion, nil) == SQLITE_OK,
                      let deletion else { throw CocoaError(.fileWriteUnknown) }
                defer { sqlite3_finalize(deletion) }
                let bound = path.withCString { sqlite3_bind_text(deletion, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                guard bound == SQLITE_OK, sqlite3_step(deletion) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
            }
            // 유한한 기준 시각만 SQL 조건으로 사용
            guard now.timeIntervalSince1970.isFinite else { throw CocoaError(.fileWriteInvalidFileName) }
            try execute(db, "DELETE FROM quota_snapshots WHERE expires_at <= \(now.timeIntervalSince1970)")
            try execute(db, "DELETE FROM quota_snapshots WHERE home_identity IN (SELECT home_identity FROM quota_snapshots ORDER BY updated_at DESC, home_identity ASC LIMIT -1 OFFSET 64)")
            try execute(db, "COMMIT")
        }
    }

    /// 명시적으로 제거한 경로의 캐시 삭제
    func remove(path: String) throws {
        try withDatabase { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM quota_snapshots WHERE home_identity = ?", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw CocoaError(.fileWriteUnknown) }
            defer { sqlite3_finalize(statement) }
            let code = path.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard code == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
        }
    }
}
