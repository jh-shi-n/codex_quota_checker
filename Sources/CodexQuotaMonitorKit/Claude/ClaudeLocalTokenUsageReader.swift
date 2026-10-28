// 목적: Claude Stats 캐시와 세션 기록의 중복 없는 일별 토큰 집계
// 이용처: Claude 계정 상세의 과거 통계·오늘 사용량
// 사용방법: 선택 설정 폴더의 snapshot(home:email:) 호출
// 실행 예시: try await ClaudeLocalTokenUsageReader.shared.snapshot(home: home, email: email)
import CoreFoundation
import Foundation

/// 숫자·응답 식별자·파일 커서만 보관하는 폴더별 증분 집계
public actor ClaudeLocalTokenUsageReader {
    public static let shared = ClaudeLocalTokenUsageReader()
    private let maximumFiles: Int
    private let maximumBytes: Int
    private let maximumLineBytes: Int
    private let now: @Sendable () -> Date
    private var homes: [URL: Home] = [:]
    private let preciseISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let basicISO = ISO8601DateFormatter()
    private static let maximumCounter: Int64 = 9_007_199_254_740_991

    /// 원문을 포함하지 않는 응답별 최종 토큰 수치
    private struct Response {
        let day: String
        let tokens: Int64
        let timestamp: Date
        let sidechain: Bool
    }

    /// 파일 교체·축소·추가 기록 판별을 위한 커서
    private struct FileState {
        var identity: String
        var size: UInt64 = 0
        var modified: Date = .distantPast
        var offset: UInt64 = 0
        var responses: [String: Response] = [:]
    }

    /// 계정 폴더별 파일 상태와 메모리 정리 기준
    private struct Home {
        var files: [URL: FileState] = [:]
        var accessed: Date
    }

    /// 읽기 상한과 UTC 경계 검증용 시계 주입
    public init(maximumFiles: Int = 4096, maximumBytes: Int = 256 * 1024 * 1024,
                maximumLineBytes: Int = 1024 * 1024, now: @escaping @Sendable () -> Date = { Date() }) {
        self.maximumFiles = max(0, maximumFiles)
        self.maximumBytes = max(0, maximumBytes)
        self.maximumLineBytes = max(1, maximumLineBytes)
        self.now = now
    }

    /// 과거 캐시 우선·누락 날짜와 오늘 로그 보완; 실패 시 부분 합계 반환 제외
    public func snapshot(home: URL, email: String?) throws -> AccountTokenUsage {
        try Task.checkCancellation()
        guard home.isFileURL else { throw ClaudeQuotaError.invalidData }
        let root = home.standardizedFileURL.resolvingSymlinksInPath()
        let reference = now()
        let today = AccountUsageCalendar.label(reference)
        let cutoff = AccountUsageCalendar.label(TokenUsageOptions().cutoff(at: reference, calendar: AccountTokenUsage.reportingCalendar))
        let cached = try cache(home: root, cutoff: cutoff, today: today)
        let urls = try candidates(home: root, cutoff: cutoff)
        var state = homes[root] ?? Home(accessed: reference)
        state.accessed = reference
        state.files = state.files.filter { urls.contains($0.key) }
        var remaining = maximumBytes
        var responses: [String: Response] = [:]
        for url in urls.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else { throw ClaudeQuotaError.invalidData }
            let identity = "\(attributes[.systemNumber] ?? 0)-\(attributes[.systemFileNumber] ?? 0)"
            let length = size.uint64Value
            var file = state.files[url] ?? FileState(identity: identity)
            if identity != file.identity || length < file.size || (length == file.size && modified != file.modified) {
                file = FileState(identity: identity)
            }
            try advance(url: url, state: &file, length: length, remaining: &remaining, cutoff: cutoff, today: today)
            file.size = length
            file.modified = modified
            file.responses = file.responses.filter { $0.value.day >= cutoff && $0.value.day <= today }
            state.files[url] = file
            for (key, value) in file.responses {
                if let previous = responses[key] {
                    if preferred(value, over: previous) { responses[key] = value }
                } else { responses[key] = value }
            }
        }
        var days = cached
        var local: [String: Int64] = [:]
        for value in responses.values where days[value.day] == nil {
            local[value.day] = try adding(local[value.day] ?? 0, value.tokens)
        }
        days.merge(local) { cached, _ in cached }
        try Task.checkCancellation()
        var total: Int64 = 0
        for value in days.values { total = try adding(total, value) }
        let summary: [String: CodexJSONValue] = days.isEmpty ? [:] : [
            "lifetimeTokens": .number(Double(total)), "peakDailyTokens": .number(Double(days.values.max() ?? 0))
        ]
        let result = try AccountTokenUsage(result: .object([
            "summary": .object(summary),
            "dailyUsageBuckets": .array(days.sorted { $0.key < $1.key }.map {
                .object(["startDate": .string($0.key), "tokens": .number(Double($0.value))])
            })
        ]), fetchedAt: reference, accountEmail: email, source: .claudeLocal)
        if homes[root] == nil, homes.count >= 4, let oldest = homes.min(by: { $0.value.accessed < $1.value.accessed })?.key {
            homes.removeValue(forKey: oldest)
        }
        homes[root] = state
        return result
    }

    /// キャ시 형식·토큰 정의·완료 날짜를 검증하고 미지원 캐시는 로그로 대체
    private func cache(home: URL, cutoff: String, today: String) throws -> [String: Int64] {
        let url = home.appendingPathComponent("stats-cache.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard url.resolvingSymlinksInPath().path.hasPrefix(home.path + "/") else { throw ClaudeQuotaError.invalidData }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 8 * 1024 * 1024 else { throw ClaudeQuotaError.invalidData }
        let data = try Data(contentsOf: url)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = try? counter(root["version"]), (1...5).contains(version),
              let semantics = try? counter(root["dailyModelTokensVersion"]), semantics == 5,
              let last = root["lastComputedDate"] as? String, validDay(last), last < today,
              let rows = root["dailyModelTokens"] as? [[String: Any]] else { return [:] }
        var result: [String: Int64] = [:]
        do {
            for row in rows {
                guard let day = row["date"] as? String, validDay(day), result[day] == nil,
                      let models = row["tokensByModel"] as? [String: Any], !models.isEmpty else { return [:] }
                var total: Int64 = 0
                for value in models.values { total = try adding(total, counter(value)) }
                if day >= cutoff && day <= last { result[day] = total }
            }
        } catch { return [:] }
        return result
    }

    /// 설정 폴더 밖 링크를 제외한 본 세션·하위 에이전트 기록 탐색
    private func candidates(home: URL, cutoff: String) throws -> Set<URL> {
        let projects = home.appendingPathComponent("projects")
        guard FileManager.default.fileExists(atPath: projects.path) else { return [] }
        guard projects.resolvingSymlinksInPath().path.hasPrefix(home.path + "/") else { throw ClaudeQuotaError.invalidData }
        var failed = false
        guard let enumerator = FileManager.default.enumerator(at: projects,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles], errorHandler: { _, _ in failed = true; return false }) else { throw ClaudeQuotaError.invalidData }
        var result = Set<URL>()
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, url.pathExtension == "jsonl" else { continue }
            if let modified = values.contentModificationDate, AccountUsageCalendar.label(modified) < cutoff { continue }
            guard url.resolvingSymlinksInPath().path.hasPrefix(projects.path + "/") else { throw ClaudeQuotaError.invalidData }
            result.insert(url)
            guard result.count <= maximumFiles else { throw ClaudeQuotaError.invalidData }
        }
        guard !failed else { throw ClaudeQuotaError.invalidData }
        return result
    }

    /// 완결된 행만 반영하고 미완성 끝 행은 다음 갱신에서 다시 읽기
    private func advance(url: URL, state: inout FileState, length: UInt64, remaining: inout Int,
                         cutoff: String, today: String) throws {
        guard state.offset < length else { return }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: state.offset)
        var position = state.offset
        var line = Data()
        while position < length {
            try Task.checkCancellation()
            guard remaining > 0 else { throw ClaudeQuotaError.invalidData }
            let count = min(64 * 1024, remaining, Int(min(UInt64(Int.max), length - position)))
            guard let data = try handle.read(upToCount: count), !data.isEmpty else { throw ClaudeQuotaError.invalidData }
            remaining -= data.count
            for byte in data {
                position += 1
                if byte == 10 {
                    try accumulate(line, fallbackSession: url.deletingPathExtension().lastPathComponent, state: &state, cutoff: cutoff, today: today)
                    line.removeAll(keepingCapacity: true)
                    state.offset = position
                } else {
                    guard line.count < maximumLineBytes else { throw ClaudeQuotaError.invalidData }
                    line.append(byte)
                }
            }
        }
    }

    /// 대화 내용 보관 없이 응답 숫자와 식별자만 추출 및 최종 스냅샷 선택
    private func accumulate(_ line: Data, fallbackSession: String, state: inout FileState, cutoff: String, today: String) throws {
        guard !line.isEmpty else { return }
        guard let root = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw ClaudeQuotaError.invalidData }
        guard root["type"] as? String == "assistant",
              let message = root["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return }
        guard let stamp = root["timestamp"] as? String, let date = timestamp(stamp) else { throw ClaudeQuotaError.invalidData }
        let day = AccountUsageCalendar.label(date)
        guard day >= cutoff, day <= today else { return }
        var total: Int64 = 0
        for key in ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"] {
            if let value = usage[key] { total = try adding(total, counter(value)) }
        }
        if message["stop_reason"] is NSNull,
           try counter(usage["input_tokens"] ?? 0) > 0,
           try counter(usage["output_tokens"] ?? 0) == 0,
           try counter(usage["cache_read_input_tokens"] ?? 0) == 0,
           try counter(usage["cache_creation_input_tokens"] ?? 0) == 0 { return }
        let session = nonblank(root["sessionId"]) ?? fallbackSession
        let messageID = nonblank(message["id"])
        let requestID = nonblank(root["requestId"])
        let key: String
        if let messageID {
            key = "response:" + [session, requestID ?? "", messageID].map { "\($0.utf8.count):\($0)" }.joined()
        } else if let requestID {
            key = "request:" + [session, requestID].map { "\($0.utf8.count):\($0)" }.joined()
        } else { key = "row:\(state.identity):\(state.offset)" }
        let value = Response(day: day, tokens: total, timestamp: date, sidechain: root["isSidechain"] as? Bool == true)
        if let previous = state.responses[key], !preferred(value, over: previous) { return }
        state.responses[key] = value
    }

    /// 본 세션 우선 및 같은 응답의 최신 완료 기록 선택
    private func preferred(_ value: Response, over previous: Response) -> Bool {
        if value.sidechain != previous.sidechain { return !value.sidechain }
        if value.timestamp != previous.timestamp { return value.timestamp > previous.timestamp }
        return value.tokens >= previous.tokens
    }

    /// 불리언·음수·소수·정밀도 초과 토큰 거절
    private func counter(_ raw: Any?) throws -> Int64 {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue <= Double(Self.maximumCounter), number.doubleValue.rounded(.towardZero) == number.doubleValue else {
            throw ClaudeQuotaError.invalidData
        }
        return number.int64Value
    }

    /// 정밀도 상한을 넘는 합계의 정상 표시 차단
    private func adding(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow, result.partialValue <= Self.maximumCounter else { throw ClaudeQuotaError.invalidData }
        return result.partialValue
    }

    /// 응답 식별자의 공백 여부 검증
    private func nonblank(_ raw: Any?) -> String? {
        guard let text = raw as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// 소수 초 유무를 지원하는 ISO 시각 파싱
    private func timestamp(_ text: String) -> Date? {
        preciseISO.date(from: text) ?? basicISO.date(from: text)
    }

    /// 날짜 문자열의 형식과 실제 UTC 날짜 검증
    private func validDay(_ text: String) -> Bool {
        guard text.utf8.count == 10, let date = timestamp(text + "T00:00:00Z") else { return false }
        return AccountUsageCalendar.label(date) == text
    }
}
