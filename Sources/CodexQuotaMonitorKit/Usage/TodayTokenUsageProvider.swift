// 목적: 당일 세션의 추가된 로그만 읽는 저비용 토큰 집계
// 이용처: 계정 상세가 열린 동안의 당일 그래프 갱신
// 사용방법: todaySnapshot 호출, 준비 중·상한·읽기 실패 시 nil로 기존 값 유지
import Foundation
import SQLite3

/// 모델 호출 없이 당일 집계만 제공하는 수집 경계
public protocol TokenUsageTodayProvider: Sendable {
    /// 준비된 당일 숫자 집계 또는 수집 보류·실패 시 nil 반환
    func todaySnapshot(home: URL) async -> TokenUsageSnapshot?
}

/// 읽기 전용 DB의 당일 파일 목록과 파일별 커서를 사용하는 증분 수집기
public actor TodayTokenUsageProvider: TokenUsageTodayProvider {
    public static let refreshInterval: TimeInterval = 15
    public static let maximumReadBytes = 4 * 1024 * 1024
    public static let maximumFileCount = 256
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let maxReadBytes: Int
    private let maxFiles: Int
    private let parser: LocalTokenUsageProvider
    private var homes: [URL: HomeState] = [:]
    private(set) var lastReadBytes = 0

    /// 계정별 파일 상태와 마지막 접근 시각
    private struct HomeState {
        var files: [URL: Cursor] = [:]
        var accessedAt: Date
    }

    /// 원문 없이 파일 위치·숫자 누계·과대 행 건너뛰기 상태만 보관
    private struct Cursor {
        var offset: UInt64 = 0
        var discarding = false
        var state = TokenRolloutAccumulator()
        var identity: String
        var size: UInt64 = 0
        var modifiedAt: Date = .distantPast
    }

    /// 자동 수집의 바이트·파일 상한 및 검증용 시계 설정
    public init(calendar: Calendar = .autoupdatingCurrent, now: @escaping @Sendable () -> Date = { Date() },
                maxReadBytes: Int = maximumReadBytes, maxFiles: Int = maximumFileCount) {
        self.calendar = calendar
        self.now = now
        self.maxReadBytes = max(1, maxReadBytes)
        self.maxFiles = max(1, min(Self.maximumFileCount, maxFiles))
        parser = LocalTokenUsageProvider(calendar: calendar, now: now)
    }

    /// 준비가 끝난 전체 당일 합계만 반환, 초기 큰 파일은 여러 주기에 나눠 수집
    public func todaySnapshot(home: URL) async -> TokenUsageSnapshot? {
        await todaySnapshot(homes: [home])
    }

    /// 홈별 증분 커서를 보존하며 동일 세션·파일의 당일 합계 중복 제거
    public func todaySnapshot(homes sourceHomes: [URL]) async -> TokenUsageSnapshot? {
        var seen = LocalSessionDeduplicator()
        var combined: [TokenUsageDailyPoint] = []
        for home in sourceHomes {
            guard let result = await collect(home: home, seen: &seen) else { return nil }
            combined.append(contentsOf: result.dailyPoints)
        }
        return TokenUsageAggregator(calendar: calendar, dayCount: 1).aggregate(dailyPoints: combined, generatedAt: now())
    }

    /// 단일 홈의 기존 상한을 적용한 수집 및 중복 없는 숫자 반환
    private func collect(home: URL, seen: inout LocalSessionDeduplicator) async -> TokenUsageSnapshot? {
        lastReadBytes = 0
        let reference = now()
        let root = home.standardizedFileURL.resolvingSymlinksInPath()
        guard home.isFileURL, !Task.isCancelled else { return nil }
        do {
            let urls = try candidates(home: root, at: reference)
            if homes[root] == nil, homes.count >= 4,
               let oldest = homes.min(by: { $0.value.accessedAt < $1.value.accessedAt })?.key {
                homes.removeValue(forKey: oldest)
            }
            var state = homes[root] ?? HomeState(accessedAt: reference)
            state.accessedAt = reference
            state.files = state.files.filter { urls.contains($0.key) }
            var remaining = maxReadBytes
            var complete = true
            let today = calendar.startOfDay(for: reference)
            var points: [TokenUsageDailyPoint] = []
            for url in urls.sorted(by: { $0.path < $1.path }) {
                try Task.checkCancellation()
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? NSNumber,
                      let modified = attributes[.modificationDate] as? Date else { throw Failure.read }
                let identity = "\(attributes[.systemNumber] ?? 0)-\(attributes[.systemFileNumber] ?? 0)"
                let length = size.uint64Value
                var cursor = state.files[url] ?? Cursor(identity: identity)
                if cursor.identity != identity || length < cursor.size
                    || (length == cursor.size && modified != cursor.modifiedAt) {
                    cursor = Cursor(identity: identity)
                }
                let directoryDate = parser.dateFromSessionsDirectory(for: url, sessionsURL: root.appendingPathComponent("sessions"))
                let finished = try advance(url: url, cursor: &cursor, length: length,
                    directoryDate: directoryDate, remaining: &remaining)
                cursor.size = length
                cursor.modifiedAt = modified
                cursor.state.byDay = cursor.state.byDay.filter { $0.key >= today }
                state.files[url] = cursor
                complete = complete && finished
                if seen.insert(file: url), seen.insert(sessionID: cursor.state.sessionID) {
                    points.append(contentsOf: cursor.state.points.filter { calendar.isDate($0.date, inSameDayAs: reference) })
                }
            }
            homes[root] = state
            guard complete, !Task.isCancelled else { return nil }
            let result = TokenUsageAggregator(calendar: calendar, dayCount: 1).aggregate(dailyPoints: points, generatedAt: reference)
            return TokenUsageSnapshot(generatedAt: reference, dailyPoints: result.dailyPoints, today: result.today,
                last7Days: result.last7Days, last30Days: result.last30Days, totalSessions: result.totalSessions,
                averageTokensPerSession: result.averageTokensPerSession, recordedDates: [today])
        } catch { return nil }
    }

    /// 바이트 상한 내의 추가 기록을 읽고 완결된 행만 숫자 집계에 반영
    private func advance(url: URL, cursor: inout Cursor, length: UInt64, directoryDate: Date?, remaining: inout Int) throws -> Bool {
        guard cursor.offset < length else { return true }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: cursor.offset)
        var position = cursor.offset
        var line: [UInt8] = []
        while position < length, remaining > 0 {
            try Task.checkCancellation()
            let count = min(64 * 1024, remaining, Int(min(UInt64(Int.max), length - position)))
            guard let data = try handle.read(upToCount: count), !data.isEmpty else { return false }
            remaining -= data.count
            lastReadBytes += data.count
            for byte in data {
                position += 1
                if byte == 10 {
                    if !cursor.discarding {
                        if line.last == 13 { line.removeLast() }
                        parser.accumulate(line, state: &cursor.state, directoryDate: directoryDate)
                    }
                    line.removeAll(keepingCapacity: true)
                    cursor.discarding = false
                    cursor.offset = position
                } else if !cursor.discarding {
                    if line.count < parser.maxLineBytes { line.append(byte) }
                    else { line.removeAll(keepingCapacity: false); cursor.discarding = true }
                }
            }
            if cursor.discarding { cursor.offset = position }
        }
        return cursor.offset == length
    }

    /// 인덱스 기반 당일 갱신 목록과 당일 폴더에서 제한된 수의 경로 조회
    private func candidates(home: URL, at reference: Date) throws -> Set<URL> {
        let databaseURL = home.appendingPathComponent("state_5.sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            throw Failure.read
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 0)
        guard sqlite3_exec(handle, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK else { throw Failure.read }
        let start = calendar.startOfDay(for: reference)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { throw Failure.read }
        let sql = """
            SELECT rollout_path FROM threads
            WHERE updated_at >= ? AND updated_at < ?
            UNION ALL
            SELECT rollout_path FROM threads WHERE updated_at >= ? AND updated_at < ?
            LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw Failure.read }
        defer { sqlite3_finalize(statement) }
        for (index, value) in [start.timeIntervalSince1970, end.timeIntervalSince1970,
                               start.timeIntervalSince1970 * 1000, end.timeIntervalSince1970 * 1000].enumerated() {
            sqlite3_bind_double(statement, Int32(index + 1), value)
        }
        sqlite3_bind_int(statement, 5, Int32(maxFiles + 1))
        let sessions = home.appendingPathComponent("sessions").resolvingSymlinksInPath()
        var urls = Set<URL>()
        var rows = 0
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            rows += 1
            guard rows <= maxFiles else { throw Failure.limit }
            if let text = sqlite3_column_text(statement, 0) {
                let url = URL(fileURLWithPath: String(cString: text)).standardizedFileURL.resolvingSymlinksInPath()
                if url.path.hasPrefix(sessions.path + "/"), url.pathExtension.lowercased() == "jsonl" { urls.insert(url) }
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw Failure.read }
        let parts = calendar.dateComponents([.year, .month, .day], from: start)
        let today = sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
        if FileManager.default.fileExists(atPath: today.path) {
            guard let listing = FileManager.default.enumerator(at: today, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { throw Failure.read }
            for case let url as URL in listing where url.pathExtension.lowercased() == "jsonl" {
                let resolved = url.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(sessions.path + "/") else { throw Failure.read }
                urls.insert(resolved)
                guard urls.count <= maxFiles else { throw Failure.limit }
            }
        }
        return urls
    }

    /// 자동 수집 실패와 기존 성공 그래프를 구분하는 내부 오류
    private enum Failure: Error { case read, limit }
}
