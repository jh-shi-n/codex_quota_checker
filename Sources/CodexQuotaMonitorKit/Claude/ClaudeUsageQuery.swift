// 목적: 공식 /usage 명령을 통한 계정 사용량의 요청 시 갱신
// 이용처: Claude 계정 연결 확인·수동·주기 새로고침
// 사용방법: ClaudeUsageQuery.shared.refresh(home:cli:) 호출
// 실행 예시: try await ClaudeUsageQuery.shared.refresh(home: folder, cli: ClaudeCLI())
import Foundation

/// 같은 폴더의 동시 조회를 합치는 공식 CLI 조회 경계
public actor ClaudeUsageQuery {
    public static let shared = ClaudeUsageQuery()
    private var requests: [String: Task<Void, Error>] = [:]

    /// 폴더별 요청 공유와 지연 결과 정리
    public func refresh(home: URL, cli: ClaudeCLI) async throws {
        let key = home.resolvingSymlinksInPath().path
        if let request = requests[key] { return try await request.value }
        let request = Task.detached { try Self.run(home: home, cli: cli) }
        requests[key] = request
        defer { requests[key] = nil }
        try await request.value
    }

    /// 0턴·비용 0과 계정 일치 확인 후 신규 조회값 보관·이전 수집 설정 복원
    static func run(home: URL, cli: ClaudeCLI, timeout: TimeInterval = 18) throws {
        let authentication = try cli.authentication(home: home)
        guard authentication.supportsQuota else { throw ClaudeQuotaError.unsupportedAccount }
        let data = try cli.run(arguments: ["--print", "/usage", "--output-format", "json", "--no-session-persistence", "--tools", "", "--strict-mcp-config", "--setting-sources", "user"], home: home, limit: timeout)
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["is_error"] as? Bool != true,
              (envelope["num_turns"] as? Int) == 0,
              (envelope["total_cost_usd"] as? Double) == 0,
              let text = envelope["result"] as? String else { throw ClaudeQuotaError.liveQueryFailed }
        let now = Date()
        let rates = try decode(text: text, now: now)
        guard try cli.authentication(home: home).identity == authentication.identity else { throw ClaudeQuotaError.loginRequired }
        let previous = try? ClaudeQuotaSnapshot.read(home: home)
        let payload = try JSONSerialization.data(withJSONObject: ["rate_limits": rates])
        guard let snapshot = try ClaudeQuotaSnapshot.merging(input: payload, identity: authentication.identity, previous: previous, now: now) else { throw ClaudeQuotaError.invalidData }
        try FileManager.default.createDirectory(at: ClaudeQuotaSnapshot.directory(home: home), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(snapshot).write(to: ClaudeQuotaSnapshot.file(home: home), options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ClaudeQuotaSnapshot.file(home: home).path)
        ClaudeCollectionMigration.restoreLegacySettings(home: home)
    }

    /// 공식 명령의 알려진 표시 형식만 파싱하고 제한·오래된 값·형식 변경 거절
    static func decode(text: String, now: Date) throws -> [String: [String: Double]] {
        let normalized = text.lowercased()
        if normalized.contains("rate limited") || normalized.contains("last-known") || normalized.contains("last known") { throw ClaudeQuotaError.rateLimited }
        let pattern = #"(?im)^\s*(Current session|Current week \(all models\)):\s*([0-9]+(?:\.[0-9]+)?)% used\s*[·•-]\s*resets\s+([^\n]+?)\s*\(([^)]+)\)\s*$"#
        let expression = try NSRegularExpression(pattern: pattern)
        let string = text as NSString
        var result: [String: [String: Double]] = [:]
        for match in expression.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            let title = string.substring(with: match.range(at: 1))
            let key = title.lowercased() == "current session" ? "five_hour" : "seven_day"
            guard result[key] == nil,
                  let percent = Double(string.substring(with: match.range(at: 2))), (0...100).contains(percent),
                  let zone = TimeZone(identifier: string.substring(with: match.range(at: 4))),
                  let reset = resetDate(string.substring(with: match.range(at: 3)), zone: zone, now: now),
                  reset > now, reset.timeIntervalSince(now) <= (key == "five_hour" ? 6 * 3600 : 8 * 86400) else { throw ClaudeQuotaError.invalidData }
            result[key] = ["used_percentage": percent, "resets_at": reset.timeIntervalSince1970]
        }
        guard !result.isEmpty else { throw ClaudeQuotaError.liveQueryFailed }
        return result
    }

    /// 연말 경계·표시 시간대와 분 생략을 고려한 서버 초기화 시각 변환
    private static func resetDate(_ text: String, zone: TimeZone, now: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let year = calendar.component(.year, from: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        for format in ["MMM d 'at' h:mma yyyy", "MMM d 'at' ha yyyy"] {
            formatter.dateFormat = format
            for candidateYear in [year, year + 1] {
                if let value = formatter.date(from: text + " \(candidateYear)"), value > now, value.timeIntervalSince(now) <= 8 * 86400 { return value }
            }
        }
        for format in ["h:mma", "ha"] {
            formatter.dateFormat = format
            if let time = formatter.date(from: text) {
                let parts = calendar.dateComponents([.hour, .minute], from: time)
                if let date = calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: now) {
                    return date > now ? date : calendar.date(byAdding: .day, value: 1, to: date)
                }
            }
        }
        return nil
    }
}
