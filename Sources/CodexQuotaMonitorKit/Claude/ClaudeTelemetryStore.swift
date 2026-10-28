// 목적: 공식 OpenTelemetry 토큰 카운터의 계정별 수신·보관
// 이용처: Claude 계정 토큰 그래프와 공식 수집 연결
// 사용방법: ingest(_:home:) 수신 후 usage(home:identity:email:) 조회
// 실행 예시: try await ClaudeTelemetryStore.shared.ingest(data, home: folder)
import CoreFoundation
import CryptoKit
import Foundation

/// 원문·이메일 없이 누적 카운터와 계정 지문·수집일 합계만 저장
public actor ClaudeTelemetryStore {
    public static let shared = ClaudeTelemetryStore()
    private let maximumCounters: Int

    /// 최근 30일 시계열 보관 및 테스트용 최대 개수 지정
    public init(maximumCounters: Int = 32768) { self.maximumCounters = max(1, maximumCounters) }
    private struct Counter: Codable {
        var value: Int64
        var time: UInt64
        let identity: String
    }
    private struct Archive: Codable {
        var counters: [String: Counter] = [:]
        var days: [String: [String: Int64]] = [:]
        var updatedAt: Date = Date()
        var prunedBefore: UInt64?
    }

    /// 선택 폴더의 앱 전용 공식 메트릭 저장 위치
    private func file(home: URL) -> URL { ClaudeQuotaSnapshot.directory(home: home).appendingPathComponent("official-tokens.json") }

    /// 크기 제한을 적용한 기존 카운터 복원
    private func load(home: URL) throws -> Archive {
        let file = file(home: home)
        guard FileManager.default.fileExists(atPath: file.path) else { return Archive() }
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        guard (size?.intValue ?? 0) <= 8_000_000 else { throw ClaudeQuotaError.invalidData }
        return try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
    }

    /// 값·시각·계정 식별을 검증하고 재전송·역순 수신의 중복 합산 방지
    public func ingest(_ data: Data, home: URL, now: Date = Date()) throws {
        guard data.count <= 2_000_000,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resources = root["resourceMetrics"] as? [[String: Any]] else { throw ClaudeQuotaError.invalidData }
        var archive = try load(home: home)
        var received = false
        for resource in resources {
            let resourceAttributes = attributes((resource["resource"] as? [String: Any])?["attributes"])
            for scope in resource["scopeMetrics"] as? [[String: Any]] ?? [] {
                for metric in scope["metrics"] as? [[String: Any]] ?? [] where metric["name"] as? String == "claude_code.token.usage" {
                    guard let sum = metric["sum"] as? [String: Any], sum["aggregationTemporality"] as? Int == 2 else { continue }
                    for point in sum["dataPoints"] as? [[String: Any]] ?? [] {
                        let fields = resourceAttributes.merging(attributes(point["attributes"]), uniquingKeysWith: { _, last in last })
                        guard let email = fields["user.email"], !email.isEmpty,
                              let organization = fields["organization.id"], !organization.isEmpty,
                              let session = fields["session.id"], UUID(uuidString: session) != nil,
                              ["input", "output", "cacheRead", "cacheCreation"].contains(fields["type"] ?? ""),
                              let start = nanos(point["startTimeUnixNano"]), let time = nanos(point["timeUnixNano"]), start <= time,
                              Double(time) / 1e9 <= now.addingTimeInterval(30).timeIntervalSince1970,
                              let value = counter(point["asInt"] ?? point["asDouble"]) else { continue }
                        let identity = hash(Data([email, organization, "claude.ai"].joined(separator: "\n").utf8))
                        let signature = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) + Data("\n\(start)".utf8)
                        let key = hash(signature)
                        if archive.counters[key] == nil, start < (archive.prunedBefore ?? 0) { continue }
                        if let previous = archive.counters[key], time <= previous.time { continue }
                        let old = archive.counters[key]?.value ?? 0
                        guard value >= old else { continue }
                        let delta = value - old
                        let date = AccountUsageCalendar.label(Date(timeIntervalSince1970: Double(time) / 1e9))
                        let total = archive.days[identity]?[date] ?? 0
                        let addition = total.addingReportingOverflow(delta)
                        guard !addition.overflow, addition.partialValue <= 9_007_199_254_740_991 else { continue }
                        archive.days[identity, default: [:]][date] = addition.partialValue
                        archive.counters[key] = Counter(value: value, time: time, identity: identity)
                        received = true
                    }
                }
            }
        }
        guard received else { return }
        prune(&archive, now: now)
        archive.updatedAt = now
        let directory = ClaudeQuotaSnapshot.directory(home: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(archive).write(to: file(home: home), options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(home: home).path)
    }

    /// 누적 합계는 유지하며 오래된 시계열 제거, 제거된 구 프로세스의 재합산 차단
    private func prune(_ archive: inout Archive, now: Date) {
        let cutoff = UInt64(max(0, now.addingTimeInterval(-30 * 86400).timeIntervalSince1970) * 1e9)
        var watermark = max(archive.prunedBefore ?? 0, cutoff)
        archive.counters = archive.counters.filter { $0.value.time >= cutoff }
        if archive.counters.count > maximumCounters {
            let remove = archive.counters.sorted { $0.value.time < $1.value.time }.prefix(archive.counters.count - maximumCounters)
            for (key, value) in remove {
                watermark = max(watermark, value.time)
                archive.counters[key] = nil
            }
        }
        archive.prunedBefore = watermark
    }

    /// 현재 로그인 지문에 해당하는 수신 합계만 기존 그래프 모델로 변환
    public func usage(home: URL, identity: String, email: String?) throws -> AccountTokenUsage {
        let archive = try load(home: home)
        let days = archive.days[identity] ?? [:]
        var total: Int64 = 0
        for value in days.values {
            let sum = total.addingReportingOverflow(value)
            guard !sum.overflow, sum.partialValue <= 9_007_199_254_740_991 else { throw ClaudeQuotaError.invalidData }
            total = sum.partialValue
        }
        let summary: [String: CodexJSONValue] = days.isEmpty ? [:] : ["lifetimeTokens": .number(Double(total)), "peakDailyTokens": .number(Double(days.values.max() ?? 0))]
        return try AccountTokenUsage(result: .object(["summary": .object(summary),
            "dailyUsageBuckets": .array(days.sorted { $0.key < $1.key }.map { .object(["startDate": .string($0.key), "tokens": .number(Double($0.value))]) })]),
            fetchedAt: archive.updatedAt, accountEmail: email, source: .claudeTelemetry)
    }

    /// OTLP 문자열 속성만 허용하며 원문 이벤트는 사용하지 않는 속성 투영
    private func attributes(_ raw: Any?) -> [String: String] {
        var result: [String: String] = [:]
        for item in raw as? [[String: Any]] ?? [] {
            if let key = item["key"] as? String, let value = (item["value"] as? [String: Any])?["stringValue"] as? String { result[key] = value }
        }
        return result
    }

    /// OTLP 나노초 시각의 정밀도 손실 없는 복원
    private func nanos(_ raw: Any?) -> UInt64? {
        if let text = raw as? String { return UInt64(text) }
        if let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { return UInt64(value.stringValue) }
        return nil
    }

    /// 음수·소수·불리언·정밀도 범위 초과 토큰 거부
    private func counter(_ raw: Any?) -> Int64? {
        if let text = raw as? String, let value = Int64(text), (0...9_007_199_254_740_991).contains(value) { return value }
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue >= 0, value.doubleValue <= 9_007_199_254_740_991,
              value.doubleValue.rounded(.towardZero) == value.doubleValue else { return nil }
        return value.int64Value
    }

    /// 계정·시계열의 비식별 저장 키 구성
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
