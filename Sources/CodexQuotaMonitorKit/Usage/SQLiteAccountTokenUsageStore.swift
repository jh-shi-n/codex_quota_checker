// 목적: 마지막 정상 서버 토큰 사용량의 경로별 영속 저장·복원
// 이용처: 계정 토큰 그래프의 앱 재시작 복원
// 사용방법: 할당량과 동일한 DB의 독립 테이블에 검증된 집계만 보관
import Foundation
import SQLite3

/// 인증 정보·세션 내용 없이 서버 요약과 일별 사용량만 보관하는 저장소
final class SQLiteAccountTokenUsageStore: Sendable {
    private let databaseURL: URL
    static let lifetime = SQLiteQuotaSnapshotStore.lifetime

    /// 앱 공용 DB 또는 격리된 테스트 DB 지정
    init(databaseURL: URL) { self.databaseURL = databaseURL }

    /// 연결과 스키마 생성 후 SQL 작업의 오류 전달
    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try PrivateSQLiteFiles.prepare(databaseURL)
        var pointer: OpaquePointer?
        let result = sqlite3_open_v2(databaseURL.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let db = pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(db); try? PrivateSQLiteFiles.secureExisting(databaseURL) }
        sqlite3_busy_timeout(db, 250)
        guard sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS account_token_usage_snapshots (home_identity TEXT PRIMARY KEY, snapshot BLOB NOT NULL, updated_at REAL NOT NULL)", nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try body(db)
    }

    /// 바인딩 수명과 SQL 실행 결과를 보장하는 단일 구문 처리
    private func statement<T>(_ db: OpaquePointer, _ sql: String, home: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_finalize(pointer) }
        let code = home.withCString { sqlite3_bind_text(pointer, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard code == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        return try body(pointer)
    }

    /// 정상 응답과 원래 조회 시각의 원자적 교체 저장
    func save(_ snapshot: AccountTokenUsage, home: String) throws {
        let data = try JSONEncoder().encode(Payload(snapshot))
        try withDatabase { db in
            try statement(db, "INSERT OR REPLACE INTO account_token_usage_snapshots VALUES (?, ?, ?)", home: home) { query in
                let bound = data.withUnsafeBytes { sqlite3_bind_blob(query, 2, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                guard bound == SQLITE_OK,
                      sqlite3_bind_double(query, 3, snapshot.fetchedAt.timeIntervalSince1970) == SQLITE_OK,
                      sqlite3_step(query) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
            }
        }
    }

    /// 보관 기간 내 정상 payload 복원; 손상된 숫자·날짜의 서버 검증 재적용
    func load(home: String, now: Date = Date()) throws -> AccountTokenUsage? {
        try withDatabase { db in
            try statement(db, "SELECT snapshot FROM account_token_usage_snapshots WHERE home_identity = ?", home: home) { query in
                let code = sqlite3_step(query)
                if code == SQLITE_DONE { return nil }
                guard code == SQLITE_ROW, let blob = sqlite3_column_blob(query, 0) else { throw CocoaError(.fileReadUnknown) }
                let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(query, 0)))
                let payload = try JSONDecoder().decode(Payload.self, from: data)
                guard payload.version == 1, payload.fetchedAt <= now,
                      payload.fetchedAt.addingTimeInterval(Self.lifetime) > now else { return nil }
                return try AccountTokenUsage(result: payload.result, fetchedAt: payload.fetchedAt, accountEmail: payload.email)
            }
        }
    }

    /// 설정에서 제거·변경된 경로의 마지막 조회 결과 삭제
    func remove(home: String) throws {
        try withDatabase { db in
            try statement(db, "DELETE FROM account_token_usage_snapshots WHERE home_identity = ?", home: home) { query in
                guard sqlite3_step(query) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
            }
        }
    }

    /// 만료·미등록 경로 정리 및 최대 64개 캐시 유지
    func cleanup(homes: Set<String>, now: Date = Date()) throws {
        try withDatabase { db in
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT home_identity, updated_at FROM account_token_usage_snapshots ORDER BY updated_at DESC", -1, &query, nil) == SQLITE_OK,
                  let query else { throw CocoaError(.fileReadUnknown) }
            var removed: [String] = []
            var kept = 0
            var code = sqlite3_step(query)
            while code == SQLITE_ROW {
                if let raw = sqlite3_column_text(query, 0) {
                    let home = String(cString: raw)
                    let updated = sqlite3_column_double(query, 1)
                    if !homes.contains(home) || updated + Self.lifetime <= now.timeIntervalSince1970 || kept >= 64 {
                        removed.append(home)
                    } else { kept += 1 }
                }
                code = sqlite3_step(query)
            }
            sqlite3_finalize(query)
            guard code == SQLITE_DONE else { throw CocoaError(.fileReadUnknown) }
            for home in removed {
                try statement(db, "DELETE FROM account_token_usage_snapshots WHERE home_identity = ?", home: home) { deletion in
                    guard sqlite3_step(deletion) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
                }
            }
        }
    }

    /// 버전 정보가 포함된 최소 서버 응답 저장 형식
    private struct Payload: Codable {
        let version: Int
        let fetchedAt: Date
        let email: String?
        let result: CodexJSONValue

        /// 미제공·빈 배열·실제 0을 유지하는 서버 응답 재구성
        init(_ snapshot: AccountTokenUsage) {
            version = 1
            fetchedAt = snapshot.fetchedAt
            email = snapshot.accountEmail
            var summary: [String: CodexJSONValue] = [:]
            if let value = snapshot.lifetimeTokens { summary["lifetimeTokens"] = .number(Double(value)) }
            if let value = snapshot.peakDailyTokens { summary["peakDailyTokens"] = .number(Double(value)) }
            var object: [String: CodexJSONValue] = ["summary": .object(summary)]
            if let days = snapshot.days {
                object["dailyUsageBuckets"] = .array(days.map { .object(["startDate": .string($0.date), "tokens": .number(Double($0.tokens))]) })
            }
            result = .object(object)
        }
    }
}
