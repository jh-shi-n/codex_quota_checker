// 목적: 14일 스냅샷과 독립적인 계정별 일별 토큰 집계 보관
// 이용처: 주간 사용량 차트·달력 기준 보관 기간·앱 재시작 복원
// 사용방법: 캐시의 직렬 디스크 큐에서 merge·load·prune 호출
import Foundation
import SQLite3

/// 원본 내용 없이 날짜별 숫자만 저장하는 장기 집계 경계
final class SQLiteTokenUsageHistoryStore: @unchecked Sendable {
    let databaseURL: URL
    private var blockedAccounts: Set<String> = []
    private var blockAll = false

    /// 앱 전용 DB 경로 또는 테스트용 임시 경로 연결
    init(databaseURL: URL) { self.databaseURL = databaseURL }

    /// 불완전하거나 취소된 집계를 제외한 동일 날짜의 최신 값 교체
    func merge(
        _ snapshot: TokenUsageSnapshot, accountID: String, homeIdentity: String,
        options: TokenUsageOptions, now: Date, calendar: Calendar
    ) throws -> TokenUsageSnapshot {
        guard snapshot.availability == .available else { return snapshot }
        try withDatabase { db in
            try execute(db, "BEGIN IMMEDIATE")
            defer { try? execute(db, "ROLLBACK") }
            let oldHome = try accountMetadata(db, accountID)?.home
            if oldHome != nil && oldHome != homeIdentity {
                try execute(db, "DELETE FROM token_history_accounts WHERE account_id = ?", [.text(accountID)])
            }
            try execute(db, """
                INSERT INTO token_history_accounts VALUES (?, ?, ?)
                ON CONFLICT(account_id) DO UPDATE SET home_identity=excluded.home_identity,
                updated_at=max(updated_at, excluded.updated_at)
                """, [.text(accountID), .text(homeIdentity), .real(snapshot.generatedAt.timeIntervalSince1970)])
            let cutoff = options.cutoff(at: now, calendar: calendar)
            let today = dayKey(now, calendar: calendar)
            let known = snapshot.recordedDates.map { Set($0.map { dayKey($0, calendar: calendar) }) }
            for point in snapshot.dailyPoints where point.date >= cutoff && point.date <= now {
                let key = dayKey(point.date, calendar: calendar)
                guard known == nil || known!.contains(key) else { continue }
                try execute(db, """
                    INSERT INTO token_daily_history VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, day) DO UPDATE SET
                    input_tokens=excluded.input_tokens, output_tokens=excluded.output_tokens,
                    cached_input_tokens=excluded.cached_input_tokens, session_count=excluded.session_count,
                    updated_at=excluded.updated_at
                    WHERE excluded.updated_at >= token_daily_history.updated_at
                    AND (excluded.input_tokens > 0 OR excluded.output_tokens > 0
                    OR excluded.session_count > 0 OR excluded.day = ?)
                    """, [.text(accountID), .text(key), .integer(point.inputTokens), .integer(point.outputTokens),
                          point.cachedInputTokens.map(Value.integer) ?? .null, .integer(point.sessionCount),
                          .real(snapshot.generatedAt.timeIntervalSince1970), .text(today)])
            }
            try deleteExpired(db, options: options, now: now, calendar: calendar)
            try execute(db, "COMMIT")
        }
        blockedAccounts.remove(accountID)
        return try load(accountID: accountID, homeIdentity: homeIdentity, options: options, now: now, calendar: calendar)
            ?? snapshot
    }

    /// 마지막 수집 시각을 보존한 장기 집계와 실제 수집 날짜 복원
    func load(
        accountID: String, homeIdentity: String, options: TokenUsageOptions, now: Date, calendar: Calendar
    ) throws -> TokenUsageSnapshot? {
        guard !blockAll, !blockedAccounts.contains(accountID), FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        return try withDatabase { db in
            guard let metadata = try accountMetadata(db, accountID), metadata.home == homeIdentity else { return nil }
            let cutoff = options.cutoff(at: now, calendar: calendar)
            let statement = try prepare(db, """
                SELECT day, input_tokens, output_tokens, cached_input_tokens, session_count
                FROM token_daily_history WHERE account_id = ? AND day >= ? AND day <= ? ORDER BY day
                """, [.text(accountID), .text(dayKey(cutoff, calendar: calendar)), .text(dayKey(now, calendar: calendar))])
            defer { sqlite3_finalize(statement) }
            var points: [TokenUsageDailyPoint] = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                let text = String(cString: sqlite3_column_text(statement, 0))
                guard let date = dayDate(text, calendar: calendar) else { throw Failure.invalidData }
                points.append(TokenUsageDailyPoint(date: date,
                    inputTokens: sqlite3_column_int64(statement, 1), outputTokens: sqlite3_column_int64(statement, 2),
                    cachedInputTokens: sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 3),
                    sessionCount: sqlite3_column_int64(statement, 4)))
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw Failure.operationFailed }
            let count = (calendar.dateComponents([.day], from: cutoff, to: calendar.startOfDay(for: now)).day ?? 0) + 1
            let result = TokenUsageAggregator(calendar: calendar, dayCount: count).aggregate(dailyPoints: points, generatedAt: now)
            return TokenUsageSnapshot(generatedAt: metadata.updatedAt, dailyPoints: result.dailyPoints,
                today: result.today, last7Days: result.last7Days, last30Days: result.last30Days,
                totalSessions: result.totalSessions, averageTokensPerSession: result.averageTokensPerSession,
                recordedDates: points.map(\.date))
        }
    }

    /// 삭제 실패 중 이전 계정 복원을 차단하는 계정별 삭제
    func remove(accountID: String) throws {
        blockedAccounts.insert(accountID)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { blockedAccounts.remove(accountID); return }
        try withDatabase { try execute($0, "DELETE FROM token_history_accounts WHERE account_id = ?", [.text(accountID)]) }
        blockedAccounts.remove(accountID)
    }

    /// 명시적 전체 삭제 시 복원 차단과 집계 제거
    func removeAll() throws {
        blockAll = true
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { blockAll = false; return }
        try withDatabase { try execute($0, "DELETE FROM token_history_accounts") }
        blockAll = false
        blockedAccounts.removeAll()
    }

    /// 보관 기간 경계와 실패한 계정 삭제 재시도·해제 페이지의 점진적 회수
    func prune(options: TokenUsageOptions, now: Date, calendar: Calendar) throws {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return }
        if blockAll { try removeAll() }
        for id in Array(blockedAccounts) { try remove(accountID: id) }
        try withDatabase { db in
            try deleteExpired(db, options: options, now: now, calendar: calendar)
            try execute(db, "PRAGMA incremental_vacuum(64)")
        }
    }

    /// 달력 개월 수 기준으로 보관 시작일 이전 행 제거
    private func deleteExpired(_ db: OpaquePointer, options: TokenUsageOptions, now: Date, calendar: Calendar) throws {
        try execute(db, "DELETE FROM token_daily_history WHERE day < ?", [.text(dayKey(options.cutoff(at: now, calendar: calendar), calendar: calendar))])
    }

    /// 계정 경로와 마지막 성공 수집 시각 조회
    private func accountMetadata(_ db: OpaquePointer, _ id: String) throws -> (home: String, updatedAt: Date)? {
        let statement = try prepare(db, "SELECT home_identity, updated_at FROM token_history_accounts WHERE account_id = ?", [.text(id)])
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw Failure.operationFailed }
        return (String(cString: sqlite3_column_text(statement, 0)), Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)))
    }

    /// 로컬 날짜의 시간대 변경과 독립적인 정렬 키 구성
    private func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 정렬 키를 현재 달력의 로컬 날짜로 복원
    private func dayDate(_ key: String, calendar: Calendar) -> Date? {
        let values = key.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: values[0], month: values[1], day: values[2]))
    }

    /// 제한된 잠금 대기와 사용자 전용 권한을 적용하는 DB 연결
    private func withDatabase<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        try PrivateSQLiteFiles.prepare(databaseURL)
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db = pointer else { if let pointer { sqlite3_close(pointer) }; throw Failure.operationFailed }
        defer { sqlite3_close(db); try? PrivateSQLiteFiles.secureExisting(databaseURL) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
        guard sqlite3_busy_timeout(db, 250) == SQLITE_OK else { throw Failure.operationFailed }
        try execute(db, "PRAGMA auto_vacuum = INCREMENTAL")
        guard let schema = Self.schemaURL() else { throw Failure.invalidData }
        guard sqlite3_exec(db, try String(contentsOf: schema, encoding: .utf8), nil, nil, nil) == SQLITE_OK else { throw Failure.operationFailed }
        return try operation(db)
    }

    /// 빌드 디렉터리가 없는 설치 앱의 리소스를 우선하고 SwiftPM 실행 경로 지원
    static func schemaURL(installedResources: URL? = Bundle.main.resourceURL) -> URL? {
        if let url = installedResources?.appendingPathComponent("CodexQuotaMonitor_CodexQuotaMonitorKit.bundle"),
           let bundle = Bundle(url: url), let schema = bundle.url(forResource: "token-history-schema", withExtension: "sql") {
            return schema
        }
        return Bundle.module.url(forResource: "token-history-schema", withExtension: "sql")
    }

    /// 자료형에 따른 SQL 값 바인딩과 실패 시 구문 해제
    private func prepare(_ db: OpaquePointer, _ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK, let statement = pointer else { throw Failure.operationFailed }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let .text(text): result = text.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            case let .integer(number): result = sqlite3_bind_int64(statement, index, number)
            case let .real(number): result = sqlite3_bind_double(statement, index, number)
            case .null: result = sqlite3_bind_null(statement, index)
            }
            if result != SQLITE_OK { sqlite3_finalize(statement); throw Failure.operationFailed }
        }
        return statement
    }

    /// 바인딩된 SQL 실행과 구문 해제
    private func execute(_ db: OpaquePointer, _ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(db, sql, values)
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw Failure.operationFailed }
    }

    /// 숫자와 식별자만 포함하는 SQL 값
    private enum Value { case text(String), integer(Int64), real(Double), null }
    /// 사용자 데이터와 SQL 원문을 포함하지 않는 실패 구분
    private enum Failure: Error { case operationFailed, invalidData }
}
