// 목적: 공식 OTLP 토큰 수집 환경의 명시적 설치·복원
// 이용처: Claude 계정 연결 및 토큰 사용량 영역의 수집 버튼
// 사용방법: install(home:endpoint:) 또는 remove(home:)
// 실행 예시: try ClaudeTelemetryConnection.install(home: folder, endpoint: localURL)
import Foundation

/// 지정한 토큰 수집 키만 보관하고 다른 CLI 설정 보존
public enum ClaudeTelemetryConnection {
    struct Manifest: Codable {
        let endpoint: String
        let original: [String: String]
        let installed: [String: String]
        let originalEnvPresent: Bool?
        let settingsExisted: Bool?
    }

    /// 폴더별 수집 설정 백업 경로
    private static func file(home: URL) -> URL { ClaudeQuotaSnapshot.directory(home: home).appendingPathComponent("telemetry-connection.json") }

    /// 원본 설정·수집 경로의 정상 백업 복원
    static func read(home: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: file(home: home)), data.count <= 16384 else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    /// 환경 설정의 활성 연결 여부 확인
    public static func isInstalled(home: URL) -> Bool {
        guard let manifest = read(home: home),
              let data = try? Data(contentsOf: home.appendingPathComponent("settings.json")),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = settings["env"] as? [String: String] else { return false }
        return manifest.installed.allSatisfy { env[$0.key] == $0.value }
    }

    /// 기존 OTLP 목적지 변경을 거절하고 공식 메트릭만 로컬 앱에 연결
    public static func install(home: URL, endpoint: URL) throws {
        let settingsURL = home.appendingPathComponent("settings.json")
        let before = try? Data(contentsOf: settingsURL)
        let object = try before.map { try JSONSerialization.jsonObject(with: $0) } ?? [:]
        guard var settings = object as? [String: Any] else { throw ClaudeQuotaError.invalidData }
        guard settings["env"] == nil || settings["env"] is [String: String] else { throw ClaudeQuotaError.invalidData }
        let hadEnv = settings["env"] != nil
        var env = settings["env"] as? [String: String] ?? [:]
        if let prior = read(home: home) {
            guard prior.installed.allSatisfy({ env[$0.key] == $0.value }) else { throw ClaudeQuotaError.settingsChanged }
        } else if env["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"] != nil
            || (env["OTEL_METRICS_EXPORTER"]?.split(separator: ",").contains("otlp") == true) {
            throw ClaudeQuotaError.telemetryConflict
        }
        let exporters = Set((env["OTEL_METRICS_EXPORTER"] ?? "").split(separator: ",").map(String.init).filter { $0 != "none" }).union(["otlp"]).sorted().joined(separator: ",")
        let installed = ["CLAUDE_CODE_ENABLE_TELEMETRY":"1", "OTEL_METRICS_EXPORTER":exporters,
            "OTEL_EXPORTER_OTLP_METRICS_PROTOCOL":"http/json", "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT":endpoint.absoluteString,
            "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE":"cumulative", "OTEL_METRICS_INCLUDE_SESSION_ID":"true",
            "OTEL_METRICS_INCLUDE_ACCOUNT_UUID":"true", "OTEL_METRIC_EXPORT_INTERVAL":"10000"]
        let original = read(home: home)?.original ?? env.filter { installed[$0.key] != nil }
        for (key, value) in installed { env[key] = value }
        settings["env"] = env
        let prior = read(home: home)
        let manifest = Manifest(endpoint: endpoint.absoluteString, original: original, installed: installed,
            originalEnvPresent: prior?.originalEnvPresent ?? hadEnv, settingsExisted: prior?.settingsExisted ?? (before != nil))
        let folder = ClaudeQuotaSnapshot.directory(home: home)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let previous = try? Data(contentsOf: file(home: home))
        do {
            try JSONEncoder().encode(manifest).write(to: file(home: home), options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(home: home).path)
            guard (try? Data(contentsOf: settingsURL)) == before else { throw ClaudeQuotaError.settingsChanged }
            try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: settingsURL, options: [.atomic])
        } catch {
            if let previous { try? previous.write(to: file(home: home), options: [.atomic]) }
            else { try? FileManager.default.removeItem(at: file(home: home)) }
            throw error
        }
    }

    /// 사용자가 변경한 키는 덮어쓰지 않는 설치 환경 복원
    public static func remove(home: URL) throws {
        guard let manifest = read(home: home) else { throw ClaudeQuotaError.invalidData }
        let file = home.appendingPathComponent("settings.json")
        let before = try Data(contentsOf: file)
        guard var settings = try JSONSerialization.jsonObject(with: before) as? [String: Any],
              var env = settings["env"] as? [String: String],
              manifest.installed.allSatisfy({ env[$0.key] == $0.value }) else { throw ClaudeQuotaError.settingsChanged }
        for key in manifest.installed.keys { env[key] = manifest.original[key] }
        settings["env"] = env.isEmpty && manifest.originalEnvPresent != true ? nil : env
        guard try Data(contentsOf: file) == before else { throw ClaudeQuotaError.settingsChanged }
        if settings.isEmpty && manifest.settingsExisted == false { try FileManager.default.removeItem(at: file) }
        else { try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: [.atomic]) }
        try FileManager.default.removeItem(at: Self.file(home: home))
    }
}
