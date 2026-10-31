import Foundation
import CoreFoundation

/// Reads only token counters from rollout JSONL files below one configured
/// CODEX_HOME. Authentication, configuration, databases, prompts, messages,
/// tool content, and file contents are never returned by this type.
public struct LocalTokenUsageProvider: TokenUsageRangeProvider, Sendable {
    /// 전체 집계 대상 파일 수 상한; 초과 확인 즉시 탐색 종료
    public static let defaultMaximumFileCount = 512
    /// Maximum UTF-8 bytes accepted for one JSONL line. Oversized lines are
    /// discarded without attempting to parse or retain their content.
    public static let defaultMaximumLineBytes = 1_048_576
    /// 한 번의 집계에서 읽는 전체 파일 바이트 상한
    public static let defaultMaximumReadBytes = 256 * 1024 * 1024

    public let calendar: Calendar
    public let maxFileCount: Int
    public let maxLineBytes: Int
    public let maxReadBytes: Int

    public static let defaultMaxFileCount = defaultMaximumFileCount
    public static let defaultMaxLineBytes = defaultMaximumLineBytes

    private let now: @Sendable () -> Date
    private let aggregator: TokenUsageAggregator

    public init(
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = { Date() },
        maxFileCount: Int = LocalTokenUsageProvider.defaultMaximumFileCount,
        maxLineBytes: Int = LocalTokenUsageProvider.defaultMaximumLineBytes,
        maxReadBytes: Int = LocalTokenUsageProvider.defaultMaximumReadBytes,
        historyDayCount: Int = TokenUsageSnapshot.historyDayCount
    ) {
        self.calendar = calendar
        self.maxFileCount = max(0, maxFileCount)
        self.maxLineBytes = max(1, maxLineBytes)
        self.maxReadBytes = max(0, maxReadBytes)
        self.now = now
        self.aggregator = TokenUsageAggregator(calendar: calendar, dayCount: historyDayCount)
    }

    /// 보관 정책의 날짜 수에 맞춘 동일 검증·취소·읽기 상한 적용
    public func snapshot(home: URL, historyDayCount: Int) async -> TokenUsageSnapshot {
        await LocalTokenUsageProvider(calendar: calendar, now: now, maxFileCount: maxFileCount,
            maxLineBytes: maxLineBytes, maxReadBytes: maxReadBytes, historyDayCount: historyDayCount).snapshot(home: home)
    }

    /// 명시한 범위의 로컬 세션 집계와 완전한 성공 결과 반환
    public func snapshot(home: URL) async -> TokenUsageSnapshot {
        await snapshot(homes: [home])
    }

    /// 홈별 기존 읽기 상한을 유지하며 세션·파일 중복을 제거한 합산
    public func snapshot(homes: [URL]) async -> TokenUsageSnapshot {
        var dailyPoints: [TokenUsageDailyPoint] = []
        var seen = LocalSessionDeduplicator()
        let generatedAt = now()
        for home in homes {
            guard !Task.isCancelled else {
                return aggregator.emptySnapshot(generatedAt: generatedAt, availability: .unavailable, error: .cancelled)
            }
            guard home.isFileURL else {
                return aggregator.emptySnapshot(
                    generatedAt: generatedAt,
                    availability: .unavailable,
                    error: .invalidHome
                )
            }

            let sessionsURL = home.standardizedFileURL.appendingPathComponent(
                "sessions",
                isDirectory: true
            ).resolvingSymlinksInPath()
            let fileManager = FileManager.default
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: sessionsURL.path, isDirectory: &isDirectory) else {
                // 새 홈의 세션 부재는 다른 소스의 집계를 중단하지 않는 조건
                continue
            }
            guard isDirectory.boolValue,
                  fileManager.isReadableFile(atPath: sessionsURL.path) else {
                return aggregator.emptySnapshot(
                    generatedAt: generatedAt,
                    availability: .unavailable,
                    error: .sessionsDirectoryUnavailable
                )
            }

            let scan = rolloutCandidates(
                in: sessionsURL,
                referenceDate: generatedAt,
                fileManager: fileManager
            )
            if let error = scan.error {
                return aggregator.emptySnapshot(generatedAt: generatedAt, availability: .unavailable, error: error)
            }
            var remainingBytes = maxReadBytes
            do {
                for candidate in scan.files {
                    try Task.checkCancellation()
                    guard seen.insert(file: candidate.url) else { continue }
                    let parsed = try parseRollout(candidate, fileManager: fileManager, remainingBytes: &remainingBytes)
                    if seen.insert(sessionID: parsed.sessionID) { dailyPoints.append(contentsOf: parsed.points) }
                }
                try Task.checkCancellation()
            } catch {
                let failure: TokenUsageSnapshotError = error is CancellationError ? .cancelled
                    : (error as? RolloutReadError == .byteLimitExceeded ? .readLimitExceeded : .rolloutReadFailed)
                return aggregator.emptySnapshot(generatedAt: generatedAt, availability: .unavailable, error: failure)
            }
        }
        return aggregator.aggregate(dailyPoints: dailyPoints, generatedAt: generatedAt)
    }

    private struct RolloutCandidate {
        let url: URL
        let directoryDate: Date?
    }

    /// 후보 파일과 전체 탐색의 완전성 상태
    private struct RolloutScan {
        let files: [RolloutCandidate]
        let error: TokenUsageSnapshotError?
    }

    /// 상한 초과·탐색 실패를 부분 정상 통계와 구분하는 후보 수집
    private func rolloutCandidates(
        in sessionsURL: URL,
        referenceDate: Date,
        fileManager: FileManager
    ) -> RolloutScan {
        var scanError: TokenUsageSnapshotError?
        guard let enumerator = fileManager.enumerator(
                  at: sessionsURL,
                  includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                  options: [.skipsHiddenFiles],
                  errorHandler: { _, _ in
                      scanError = .rolloutReadFailed
                      return false
                  }
              ) else {
            return RolloutScan(files: [], error: .sessionsDirectoryUnavailable)
        }

        let today = calendar.startOfDay(for: referenceDate)
        // UTC 폴더가 로컬 날짜보다 하루 앞서는 경우도 실제 이벤트 날짜로 집계
        let latestDirectoryDay = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let firstDay = calendar.date(
            byAdding: .day,
            value: -(aggregator.dayCount - 1),
            to: today
        ) ?? today
        var candidates: [RolloutCandidate] = []

        for case let url as URL in enumerator {
            if Task.isCancelled { return RolloutScan(files: [], error: .cancelled) }
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]) else {
                scanError = .rolloutReadFailed
                break
            }
            guard values.isRegularFile == true else { continue }

            let directoryDate = dateFromSessionsDirectory(
                for: url,
                sessionsURL: sessionsURL
            )
            if let directoryDate {
                let day = calendar.startOfDay(for: directoryDate)
                guard day <= latestDirectoryDay else { continue }
                // 과거 디렉터리에서 최근 재개된 세션의 집계 포함
                if day < firstDay, (values.contentModificationDate ?? .distantPast) < firstDay {
                    continue
                }
            }
            candidates.append(RolloutCandidate(url: url, directoryDate: directoryDate))
            if candidates.count > maxFileCount {
                return RolloutScan(files: [], error: .fileLimitExceeded)
            }
        }

        candidates.sort { lhs, rhs in
            let lhsDate = lhs.directoryDate ?? .distantPast
            let rhsDate = rhs.directoryDate ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            // This ordering is internal only; no path is exposed in a model.
            return lhs.url.path < rhs.url.path
        }
        return RolloutScan(files: candidates, error: scanError)
    }

    /// 누적 증가분의 날짜별 배분 및 마지막 사용일 기준 세션 중복 제거
    private func parseRollout(
        _ candidate: RolloutCandidate,
        fileManager: FileManager,
        remainingBytes: inout Int
    ) throws -> TokenRolloutAccumulator {
        guard fileManager.isReadableFile(atPath: candidate.url.path) else { throw CocoaError(.fileReadNoPermission) }
        var state = TokenRolloutAccumulator()
        try readJSONLines(at: candidate.url, remainingBytes: &remainingBytes) { line in
            accumulate(line, state: &state, directoryDate: candidate.directoryDate)
        }
        return state
    }

    /// 전체 집계와 증분 집계가 공유하는 누적 카운터 증가분 계산
    func accumulate(_ line: [UInt8], state: inout TokenRolloutAccumulator, directoryDate: Date?) {
        guard let object = try? JSONSerialization.jsonObject(
            with: Data(line),
            options: [.fragmentsAllowed]
        ), let root = object as? [String: Any] else {
            return
        }
        if root["type"] as? String == "session_meta", let payload = root["payload"] as? [String: Any],
           let id = payload["id"] as? String, !id.isEmpty { state.sessionID = id }
        let eventDate = timestamp(in: root)
        if state.safeDate == nil { state.safeDate = eventDate }
        guard isTokenCountEvent(root),
              let totals = tokenTotals(in: root),
              let date = eventDate ?? state.safeDate ?? directoryDate else {
            return
        }

        let day = calendar.startOfDay(for: date)
        let delta = TokenUsageTotals(
            inputTokens: max(0, totals.inputTokens - state.highestTotals.inputTokens),
            outputTokens: max(0, totals.outputTokens - state.highestTotals.outputTokens),
            cachedInputTokens: totals.cachedInputTokens.map { max(0, $0 - (state.highestTotals.cachedInputTokens ?? 0)) }
        )
        state.highestTotals = TokenUsageTotals(
            inputTokens: max(state.highestTotals.inputTokens, totals.inputTokens),
            outputTokens: max(state.highestTotals.outputTokens, totals.outputTokens),
            cachedInputTokens: totals.cachedInputTokens.map { max(state.highestTotals.cachedInputTokens ?? 0, $0) }
                ?? state.highestTotals.cachedInputTokens
        )
        state.byDay[day] = (state.byDay[day] ?? .zero).adding(delta)
        state.latestUsageDay = max(state.latestUsageDay ?? day, day)
    }

    /// 청크별 취소 확인과 전체 파일 공통 읽기 상한을 적용하는 행 읽기
    private func readJSONLines(
        at url: URL,
        remainingBytes: inout Int,
        _ callback: ([UInt8]) -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let chunkSize = 64 * 1024
        var line = Data()
        line.reserveCapacity(min(maxLineBytes, chunkSize))
        var discardingOversizedLine = false

        while true {
            try Task.checkCancellation()
            // 상한 도달 후 EOF 판별에 한해 추가 1바이트 읽기 허용
            let readSize = remainingBytes < chunkSize ? remainingBytes + 1 : chunkSize
            let chunk = try handle.read(upToCount: readSize)
            guard let chunk, !chunk.isEmpty else { break }
            guard chunk.count <= remainingBytes else { throw RolloutReadError.byteLimitExceeded }
            remainingBytes -= chunk.count

            for byte in chunk {
                if byte == 0x0A { // LF
                    if !discardingOversizedLine {
                        callback(trimCarriageReturn(from: line))
                    }
                    line.removeAll(keepingCapacity: true)
                    discardingOversizedLine = false
                } else if !discardingOversizedLine {
                    if line.count < maxLineBytes {
                        line.append(byte)
                    } else {
                        line.removeAll(keepingCapacity: true)
                        discardingOversizedLine = true
                    }
                }
            }
        }

        if !discardingOversizedLine, !line.isEmpty {
            callback(trimCarriageReturn(from: line))
        }
    }

    /// 부분 집계를 정상 결과와 구분하는 내부 읽기 실패
    private enum RolloutReadError: Error {
        case byteLimitExceeded
    }

    private func trimCarriageReturn(from data: Data) -> [UInt8] {
        var bytes = Array(data)
        if bytes.last == 0x0D { bytes.removeLast() }
        return bytes
    }

    private func isTokenCountEvent(_ root: [String: Any]) -> Bool {
        if normalizedType(root["type"]) == "token_count" {
            return true
        }
        if normalizedType(root["type"]) == "event_msg",
           let payload = root["payload"] as? [String: Any],
           normalizedType(payload["type"]) == "token_count" {
            return true
        }
        if let event = root["event_msg"] as? [String: Any],
           normalizedType(event["type"]) == "token_count" {
            return true
        }
        return false
    }

    /// 알려진 사용량 컨테이너의 입력·출력·캐시 숫자 추출; 메시지 내용 순회 제외
    private func tokenTotals(in root: [String: Any]) -> TokenUsageTotals? {
        var containers: [[String: Any]] = [root]
        if let payload = root["payload"] as? [String: Any] { containers.append(payload) }
        if let event = root["event_msg"] as? [String: Any] { containers.append(event) }

        var usageDictionaries: [[String: Any]] = []
        for container in containers {
            appendUsageDictionaries(from: container, into: &usageDictionaries)
            if let info = container["info"] as? [String: Any] {
                appendUsageDictionaries(from: info, into: &usageDictionaries)
                // Some compatible token-count payloads put the counters
                // directly under `info` instead of under `total_token_usage`.
                usageDictionaries.append(info)
            }
        }

        for usage in usageDictionaries {
            let input = numericCounter(in: usage, keys: [
                "input_tokens", "inputTokens", "prompt_tokens", "prompt"
            ])
            let output = numericCounter(in: usage, keys: [
                "output_tokens", "outputTokens", "completion_tokens", "completion"
            ])
            guard input != nil || output != nil else { continue }
            let cached = numericCounter(in: usage, keys: [
                "cached_input_tokens", "cachedInputTokens"
            ])
            return TokenUsageTotals(inputTokens: input ?? 0, outputTokens: output ?? 0, cachedInputTokens: cached)
        }
        return nil
    }

    private func appendUsageDictionaries(
        from container: [String: Any],
        into result: inout [[String: Any]]
    ) {
        for key in [
            "total_token_usage", "totalTokenUsage", "usage", "token_usage", "tokenUsage"
        ] {
            if let dictionary = container[key] as? [String: Any] {
                result.append(dictionary)
            }
        }
    }

    private func numericCounter(
        in dictionary: [String: Any],
        keys: [String]
    ) -> Int64? {
        for key in keys {
            if let value = dictionary[key], let number = nonNegativeInt64(value) {
                return number
            }
        }
        return nil
    }

    /// JSON Boolean 제외 및 음수·실수·상한 안전 변환
    private func nonNegativeInt64(_ value: Any) -> Int64? {
        guard let number = value as? NSNumber,
              !isJSONBoolean(number) else { return nil }

        let doubleValue = number.doubleValue
        guard doubleValue.isFinite else { return nil }
        if doubleValue <= 0 { return 0 }
        if doubleValue >= Double(Int64.max) { return Int64.max }
        return Int64(doubleValue.rounded(.towardZero))
    }

    private func timestamp(in root: [String: Any]) -> Date? {
        let keys = ["timestamp", "created_at", "createdAt", "event_timestamp", "eventTimestamp"]
        for key in keys {
            if let date = parseDate(root[key]) { return date }
        }
        if let payload = root["payload"] as? [String: Any] {
            for key in keys {
                if let date = parseDate(payload[key]) { return date }
            }
        }
        return nil
    }

    /// JSON Boolean을 제외한 숫자 시각 변환
    private func parseDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, !isJSONBoolean(number) {
            let raw = number.doubleValue
            guard raw.isFinite else { return nil }
            let seconds = abs(raw) > 100_000_000_000 ? raw / 1_000 : raw
            return Date(timeIntervalSince1970: seconds)
        }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// Core Foundation 식별자를 이용한 JSON Boolean 판별
    private func isJSONBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// 세션 폴더 아래의 검증된 날짜 구성요소를 파일의 보조 시각으로 변환
    func dateFromSessionsDirectory(for url: URL, sessionsURL: URL) -> Date? {
        let base = sessionsURL.standardizedFileURL.pathComponents
        let directory = url.deletingLastPathComponent().standardizedFileURL.pathComponents
        guard directory.count >= base.count,
              Array(directory.prefix(base.count)) == base else {
            return nil
        }
        let relative = Array(directory.dropFirst(base.count))

        if relative.count >= 3 {
            for index in stride(from: relative.count - 3, through: 0, by: -1) {
                if let date = makeDate(
                    year: relative[index],
                    month: relative[index + 1],
                    day: relative[index + 2]
                ) {
                    return date
                }
            }
        }

        for component in relative.reversed() {
            let pieces = component.split { character in
                character == "-" || character == "_" || character == "."
            }
            if pieces.count == 3,
               let date = makeDate(year: String(pieces[0]), month: String(pieces[1]), day: String(pieces[2])) {
                return date
            }
        }
        return nil
    }

    private func makeDate(year: String, month: String, day: String) -> Date? {
        guard year.count == 4,
              let yearValue = Int(year),
              let monthValue = Int(month),
              let dayValue = Int(day),
              (1...12).contains(monthValue),
              (1...31).contains(dayValue) else {
            return nil
        }
        var components = DateComponents()
        components.year = yearValue
        components.month = monthValue
        components.day = dayValue
        guard let date = calendar.date(from: components) else { return nil }
        let normalized = calendar.startOfDay(for: date)
        // Reject e.g. February 31, which Calendar normalizes into March.
        let check = calendar.dateComponents([.year, .month, .day], from: normalized)
        guard check.year == yearValue,
              check.month == monthValue,
              check.day == dayValue else {
            return nil
        }
        return normalized
    }

    private func normalizedType(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        return string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }
}

/// 원문을 보관하지 않는 파일별 누적 토큰·날짜 상태
struct TokenRolloutAccumulator: Sendable {
    var sessionID: String?
    var safeDate: Date?
    var highestTotals = TokenUsageTotals.zero
    var byDay: [Date: TokenUsageTotals] = [:]
    var latestUsageDay: Date?

    /// 마지막 사용 날짜에만 세션 수를 배정한 일별 숫자 반환
    var points: [TokenUsageDailyPoint] {
        byDay.keys.sorted().map { day in
            TokenUsageDailyPoint(date: day, totals: byDay[day] ?? .zero,
                sessionCount: day == latestUsageDay ? 1 : 0)
        }
    }
}
