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
        var rollouts: [TokenRolloutEvidence] = []
        var seen = LocalSessionDeduplicator()
        let generatedAt = now()
        let today = calendar.startOfDay(for: generatedAt)
        let firstDay = calendar.date(byAdding: .day, value: -(aggregator.dayCount - 1), to: today) ?? today
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
                    let parsed = try parseRollout(candidate, fileManager: fileManager, remainingBytes: &remainingBytes,
                        retainingFrom: firstDay)
                    rollouts.append(TokenRolloutEvidence(url: candidate.url, state: parsed))
                }
                try Task.checkCancellation()
            } catch {
                let failure: TokenUsageSnapshotError = error is CancellationError ? .cancelled
                    : (error as? RolloutReadError == .byteLimitExceeded ? .readLimitExceeded : .rolloutReadFailed)
                return aggregator.emptySnapshot(generatedAt: generatedAt, availability: .unavailable, error: failure)
            }
        }
        let points = reconciledDailyPoints(rollouts, generatedAt: generatedAt)
        let result = aggregator.aggregate(dailyPoints: points, generatedAt: generatedAt)
        let recordedDates = Set(rollouts.flatMap { $0.state.coverageDays }).union([today]).sorted()
        return TokenUsageSnapshot(generatedAt: result.generatedAt, dailyPoints: result.dailyPoints, today: result.today,
            last7Days: result.last7Days, last30Days: result.last30Days, totalSessions: result.totalSessions,
            averageTokensPerSession: result.averageTokensPerSession, availability: result.availability,
            error: result.error, recordedDates: recordedDates)
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
        remainingBytes: inout Int,
        retainingFrom firstDay: Date
    ) throws -> TokenRolloutAccumulator {
        guard fileManager.isReadableFile(atPath: candidate.url.path) else { throw CocoaError(.fileReadNoPermission) }
        var state = TokenRolloutAccumulator()
        try readJSONLines(at: candidate.url, remainingBytes: &remainingBytes) { line in
            accumulate(line, state: &state, directoryDate: candidate.directoryDate, retainingFrom: firstDay)
        }
        return state
    }

    /// 전체 집계와 증분 집계가 공유하는 응답·누계 증거 추출
    func accumulate(_ line: [UInt8], state: inout TokenRolloutAccumulator, directoryDate: Date?,
                    retainingFrom firstDay: Date) {
        guard let object = try? JSONSerialization.jsonObject(
            with: Data(line),
            options: [.fragmentsAllowed]
        ), let root = object as? [String: Any] else {
            return
        }
        if normalizedType(root["type"]) == "session_meta", let payload = root["payload"] as? [String: Any] {
            if let id = nonemptyString(payload["id"]) { state.sessionIDs.insert(id) }
            if let parent = nonemptyString(payload["parent_thread_id"]) {
                state.parentThreadIDs.insert(parent)
                state.hasLineageBoundary = true
            }
            if payload["history_base"] != nil { state.hasLineageBoundary = true }
        }
        if normalizedType(root["type"]) == "history_base" { state.hasLineageBoundary = true }
        if root["history_base"] != nil { state.hasLineageBoundary = true }

        let eventDate = timestamp(in: root)
        if state.safeDate == nil { state.safeDate = eventDate }
        if let response = responseUsage(in: root, eventDate: eventDate ?? state.safeDate ?? directoryDate) {
            state.responseThreadIDs.insert(response.threadID)
            state.coverageDays.insert(calendar.startOfDay(for: response.timestamp))
            let key = TokenUsageResponseKey(threadID: response.threadID, responseID: response.responseID)
            state.responses[key] = state.responses[key].map { $0.merging(response) } ?? response
        }

        guard isTokenCountEvent(root),
              let totals = tokenTotals(in: root),
              let date = eventDate ?? state.safeDate ?? directoryDate else {
            return
        }

        let day = calendar.startOfDay(for: date)
        state.coverageDays.insert(day)
        let firstObservation = !state.hasCumulativeObservation
        if firstObservation, state.hasLineageBoundary, day >= firstDay {
            let seed = totals.subtracting(lastTokenUsage(in: root) ?? .zero)
            state.lineageSeedByDay[day] = seed
        }
        state.hasCumulativeObservation = true
        state.highestTotals = state.highestTotals.componentwiseMaximum(totals)
        if day < firstDay {
            state.priorTotals = state.priorTotals.map { $0.componentwiseMaximum(totals) } ?? totals
        } else {
            state.cumulativeByDay[day] = state.cumulativeByDay[day]
                .map { $0.componentwiseMaximum(totals) } ?? totals
            if let last = lastTokenUsage(in: root) {
                state.firstUsageByDay[day] = state.firstUsageByDay[day]
                    .map { $0.componentwiseMaximum(last) } ?? last
            }
        }
        state.latestUsageDay = max(state.latestUsageDay ?? day, day)
    }

    /// 응답과 누계 증거를 스레드별 일일 사용량으로 재조정
    func reconciledDailyPoints(_ rollouts: [TokenRolloutEvidence], generatedAt: Date) -> [TokenUsageDailyPoint] {
        let today = calendar.startOfDay(for: generatedAt)
        let firstDay = calendar.date(byAdding: .day, value: -(aggregator.dayCount - 1), to: today) ?? today
        var threads: [String: ThreadRolloutEvidence] = [:]
        var responseDeduplicator = LocalSessionDeduplicator()

        for rollout in rollouts {
            guard let threadID = rollout.state.logicalThreadID(fileID: rollout.url.path) else { continue }
            var thread = threads[threadID] ?? ThreadRolloutEvidence()
            if let prior = rollout.state.priorTotals {
                thread.priorTotals = thread.priorTotals.map { $0.componentwiseMaximum(prior) } ?? prior
            }
            for (day, totals) in rollout.state.cumulativeByDay where day >= firstDay && day <= today {
                thread.cumulativeByDay[day] = thread.cumulativeByDay[day]
                    .map { $0.componentwiseMaximum(totals) } ?? totals
            }
            for (day, totals) in rollout.state.firstUsageByDay where day >= firstDay && day <= today {
                thread.firstUsageByDay[day] = thread.firstUsageByDay[day]
                    .map { $0.componentwiseMaximum(totals) } ?? totals
            }
            for (day, totals) in rollout.state.lineageSeedByDay where day >= firstDay && day <= today {
                thread.lineageSeedByDay[day] = thread.lineageSeedByDay[day]
                    .map { $0.componentwiseMaximum(totals) } ?? totals
            }
            thread.hasLineageBoundary = thread.hasLineageBoundary || rollout.state.hasLineageBoundary
            thread.hasUnboundedOrigin = thread.hasUnboundedOrigin
                || (!rollout.state.hasLineageBoundary && rollout.state.hasCumulativeObservation)
            if let latest = rollout.state.latestUsageDay {
                thread.latestCumulativeDay = max(thread.latestCumulativeDay ?? latest, latest)
            }
            threads[threadID] = thread
            for response in rollout.state.responses.values { responseDeduplicator.merge(response: response) }
        }

        var responseByThreadDay: [String: [Date: TokenUsageTotals]] = [:]
        for response in responseDeduplicator.mergedResponses where response.timestamp >= firstDay && response.timestamp <= generatedAt {
            let day = calendar.startOfDay(for: response.timestamp)
            responseByThreadDay[response.threadID, default: [:]][day] =
                (responseByThreadDay[response.threadID]?[day] ?? .zero).adding(response.totals)
        }

        var usageByThreadDay: [String: [Date: TokenUsageTotals]] = responseByThreadDay
        var latestUsageDay: [String: Date] = responseByThreadDay.mapValues { $0.keys.max() ?? .distantPast }
        for (threadID, thread) in threads {
            var previous = thread.priorTotals
            var latestFallbackDay: Date?
            for day in thread.cumulativeByDay.keys.sorted() {
                guard let totals = thread.cumulativeByDay[day] else { continue }
                let delta: TokenUsageTotals
                if let previous {
                    delta = totals.subtracting(previous)
                } else if thread.hasUnboundedOrigin {
                    delta = totals
                } else if let seed = thread.lineageSeedByDay[day] {
                    delta = totals.subtracting(seed)
                } else if thread.hasLineageBoundary {
                    delta = thread.firstUsageByDay[day] ?? .zero
                } else {
                    delta = totals
                }
                previous = previous.map { $0.componentwiseMaximum(totals) } ?? totals
                guard responseByThreadDay[threadID]?[day] == nil else { continue }
                if delta.totalTokens > 0 {
                    usageByThreadDay[threadID, default: [:]][day] =
                        (usageByThreadDay[threadID]?[day] ?? .zero).adding(delta)
                    latestFallbackDay = max(latestFallbackDay ?? day, day)
                } else if thread.hasUnboundedOrigin {
                    usageByThreadDay[threadID, default: [:]][day] =
                        usageByThreadDay[threadID]?[day] ?? .zero
                }
            }
            if responseByThreadDay[threadID] == nil {
                if thread.hasLineageBoundary {
                    latestUsageDay[threadID] = latestFallbackDay
                } else if let latest = thread.latestCumulativeDay {
                    latestUsageDay[threadID] = latest
                }
            } else if let latestFallbackDay {
                latestUsageDay[threadID] = max(latestUsageDay[threadID] ?? latestFallbackDay, latestFallbackDay)
            }
        }

        var totalsByDay: [Date: TokenUsageTotals] = [:]
        var sessionsByDay: [Date: Int64] = [:]
        for (threadID, days) in usageByThreadDay {
            for (day, totals) in days {
                totalsByDay[day] = (totalsByDay[day] ?? .zero).adding(totals)
            }
            if let day = latestUsageDay[threadID], day >= firstDay, day <= today {
                sessionsByDay[day] = TokenUsageArithmetic.saturatingAdd(sessionsByDay[day] ?? 0, 1)
            }
        }
        return Set(totalsByDay.keys).union(sessionsByDay.keys).sorted().map { day in
            TokenUsageDailyPoint(date: day, totals: totalsByDay[day] ?? .zero,
                sessionCount: sessionsByDay[day] ?? 0)
        }
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

    /// 응답 ID가 있는 실제 사용량 레코드 추출
    private func responseUsage(in root: [String: Any], eventDate: Date?) -> TokenUsageResponseRecord? {
        guard normalizedType(root["type"]) == "token_usage_record",
              let payload = root["payload"] as? [String: Any],
              let threadID = nonemptyString(root["thread_id"]) ?? nonemptyString(payload["thread_id"]),
              let responseID = nonemptyString(root["response_id"]) ?? nonemptyString(payload["response_id"]),
              let usage = payload["usage"] as? [String: Any],
              let date = eventDate,
              let totals = responseTotals(in: usage) else { return nil }
        return TokenUsageResponseRecord(threadID: threadID, responseID: responseID, timestamp: date, totals: totals)
    }

    /// 실제 응답 사용량과 별도 캐시 입력 하위 집합 추출
    private func responseTotals(in usage: [String: Any]) -> TokenUsageTotals? {
        let input = numericCounter(in: usage, keys: ["input_tokens", "inputTokens"])
        let output = numericCounter(in: usage, keys: ["output_tokens", "outputTokens"])
        guard input != nil || output != nil else { return nil }
        let details = usage["input_tokens_details"] as? [String: Any] ?? [:]
        let cached = numericCounter(in: usage, keys: ["cached_input_tokens", "cachedInputTokens"])
            ?? numericCounter(in: details, keys: ["cached_tokens", "cached_input_tokens"])
        return TokenUsageTotals(inputTokens: input ?? 0, outputTokens: output ?? 0, cachedInputTokens: cached)
    }

    /// 누계 이벤트의 마지막 요청 사용량 추출
    private func lastTokenUsage(in root: [String: Any]) -> TokenUsageTotals? {
        var containers: [[String: Any]] = [root]
        if let payload = root["payload"] as? [String: Any] { containers.append(payload) }
        if let event = root["event_msg"] as? [String: Any] { containers.append(event) }
        for container in containers {
            if let last = container["last_token_usage"] as? [String: Any],
               let totals = responseTotals(in: last) { return totals }
            if let info = container["info"] as? [String: Any],
               let last = info["last_token_usage"] as? [String: Any],
               let totals = responseTotals(in: last) { return totals }
        }
        return nil
    }

    /// 비어 있지 않은 문자열 식별자 추출
    private func nonemptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
    var sessionIDs = Set<String>()
    var parentThreadIDs = Set<String>()
    var responseThreadIDs = Set<String>()
    var hasLineageBoundary = false
    var hasCumulativeObservation = false
    var safeDate: Date?
    var highestTotals = TokenUsageTotals.zero
    var priorTotals: TokenUsageTotals?
    var cumulativeByDay: [Date: TokenUsageTotals] = [:]
    var firstUsageByDay: [Date: TokenUsageTotals] = [:]
    var lineageSeedByDay: [Date: TokenUsageTotals] = [:]
    var coverageDays = Set<Date>()
    var responses: [TokenUsageResponseKey: TokenUsageResponseRecord] = [:]
    var latestUsageDay: Date?

    /// 당일 증분 수집에 필요한 누계 기준점만 유지
    mutating func retain(from day: Date, calendar: Calendar) {
        for (key, totals) in cumulativeByDay where key < day {
            priorTotals = priorTotals.map { $0.componentwiseMaximum(totals) } ?? totals
        }
        cumulativeByDay = cumulativeByDay.filter { $0.key >= day }
        firstUsageByDay = firstUsageByDay.filter { $0.key >= day }
        lineageSeedByDay = lineageSeedByDay.filter { $0.key >= day }
        coverageDays = coverageDays.filter { $0 >= day }
        responses = responses.filter { calendar.startOfDay(for: $0.value.timestamp) >= day }
    }

    /// 응답 ID 또는 유효한 세션 메타데이터에서 스레드 식별
    func logicalThreadID(fileID: String) -> String? {
        if responseThreadIDs.count == 1 { return responseThreadIDs.first }
        guard sessionIDs.count == 1, let sessionID = sessionIDs.first else {
            return sessionIDs.isEmpty && parentThreadIDs.isEmpty ? "file:\(fileID)" : nil
        }
        return parentThreadIDs.contains(sessionID) ? nil : sessionID
    }
}

/// 응답 사용량의 전역 중복 키
struct TokenUsageResponseKey: Hashable, Sendable {
    let threadID: String
    let responseID: String
}

/// 응답 사용량 키와 이벤트 날짜·토큰 수
struct TokenUsageResponseRecord: Sendable {
    let threadID: String
    let responseID: String
    let timestamp: Date
    let totals: TokenUsageTotals

    var key: TokenUsageResponseKey { TokenUsageResponseKey(threadID: threadID, responseID: responseID) }

    /// 동일 응답 충돌 시 날짜는 고정하고 필드별 최댓값 선택
    func merging(_ other: Self) -> Self {
        Self(threadID: threadID, responseID: responseID, timestamp: min(timestamp, other.timestamp),
            totals: totals.componentwiseMaximum(other.totals))
    }
}

/// 홈·파일별로 수집한 원문 비포함 숫자 증거
struct TokenRolloutEvidence: Sendable {
    let url: URL
    let state: TokenRolloutAccumulator
}

/// 스레드 전체에서 병합된 누계 증거
private struct ThreadRolloutEvidence {
    var priorTotals: TokenUsageTotals?
    var cumulativeByDay: [Date: TokenUsageTotals] = [:]
    var firstUsageByDay: [Date: TokenUsageTotals] = [:]
    var lineageSeedByDay: [Date: TokenUsageTotals] = [:]
    var hasLineageBoundary = false
    var hasUnboundedOrigin = false
    var latestCumulativeDay: Date?
}

extension TokenUsageTotals {
    /// 복사된 누계의 필드별 최댓값 선택
    func componentwiseMaximum(_ other: Self) -> Self {
        let cached: Int64?
        if cachedInputTokens == nil && other.cachedInputTokens == nil {
            cached = nil
        } else {
            cached = max(cachedInputTokens ?? 0, other.cachedInputTokens ?? 0)
        }
        return Self(inputTokens: max(inputTokens, other.inputTokens),
            outputTokens: max(outputTokens, other.outputTokens), cachedInputTokens: cached)
    }

    /// 누계 증가분 추출
    func subtracting(_ previous: Self) -> Self {
        let cached: Int64?
        if cachedInputTokens == nil && previous.cachedInputTokens == nil {
            cached = nil
        } else {
            cached = max(0, (cachedInputTokens ?? 0) - (previous.cachedInputTokens ?? 0))
        }
        return Self(inputTokens: max(0, inputTokens - previous.inputTokens),
            outputTokens: max(0, outputTokens - previous.outputTokens), cachedInputTokens: cached)
    }
}
