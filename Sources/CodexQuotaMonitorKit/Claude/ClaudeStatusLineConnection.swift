// 목적: 기존 Claude 상태 표시줄을 보존하는 수집 연결 설치·제거
// 이용처: 계정 연결 화면의 명시적 수집 연결 버튼
// 사용방법: install(home:appExecutable:cliExecutable:) 또는 remove(home:)
// 실행 예시: try ClaudeStatusLineConnection.install(home: folder, appExecutable: app, cliExecutable: cli)
import Foundation

/// 사용자 수정 감지용 원본·설치값의 별도 보관
public enum ClaudeStatusLineConnection {
    private struct Manifest: Codable {
        let original: Data?
        let installed: Data
        let settingsExisted: Bool
    }

    /// 선택 폴더의 기존 명령을 보존하는 고정 shim 경로 반환
    public static func script(home: URL) -> URL {
        ClaudeQuotaSnapshot.directory(home: home).appendingPathComponent("statusline.sh")
    }

    /// 앱 수집 연결이 현재 설정값과 일치하는지 확인
    public static func isInstalled(home: URL) -> Bool {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("settings.json")),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = settings["statusLine"] as? [String: Any],
              let command = status["command"] as? String else { return false }
        return command == shellQuote(script(home: home).path)
    }

    /// 셸 인자 내부의 공백·따옴표·명령 치환을 리터럴로 보존
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    /// 사용자 확인 버튼에서만 호출하는 설정 백업·기존 명령 체인 설치
    public static func install(home: URL, appExecutable: URL, cliExecutable: URL) throws {
        try install(home: home, appExecutable: appExecutable, cliExecutable: cliExecutable, willWriteSettings: {})
    }

    /// 설정 변경 경합을 재현할 수 있는 설치 트랜잭션 경계
    static func install(home: URL, appExecutable: URL, cliExecutable: URL, willWriteSettings: () throws -> Void) throws {
        let manager = FileManager.default
        let settingsURL = home.appendingPathComponent("settings.json")
        let originalData = try? Data(contentsOf: settingsURL)
        let object = try originalData.map { try JSONSerialization.jsonObject(with: $0) } ?? [:]
        guard var settings = object as? [String: Any] else { throw ClaudeQuotaError.invalidData }
        let directory = ClaudeQuotaSnapshot.directory(home: home)
        let manifestURL = directory.appendingPathComponent("connection.json")
        let oldManifest = try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        if let oldManifest {
            guard let status = settings["statusLine"],
                  try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]) == oldManifest.installed
            else { throw ClaudeQuotaError.settingsChanged }
        }
        let original: Data?
        if let oldManifest { original = oldManifest.original }
        else {
            original = try settings["statusLine"].map {
                try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
            }
        }
        let oldStatus = try original.map { try JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        if settings["statusLine"] != nil && oldManifest == nil {
            guard let current = settings["statusLine"] as? [String: Any],
                  current["type"] as? String == "command", current["command"] is String else { throw ClaudeQuotaError.invalidData }
        }
        let oldCommand = oldStatus?["command"] as? String
        guard oldManifest != nil || oldCommand != shellQuote(script(home: home).path) else { throw ClaudeQuotaError.settingsChanged }
        var installed = oldStatus ?? [:]
        installed["type"] = "command"
        installed["command"] = shellQuote(script(home: home).path)
        let manifest = Manifest(original: original,
            installed: try JSONSerialization.data(withJSONObject: installed, options: [.sortedKeys]),
            settingsExisted: oldManifest?.settingsExisted ?? (originalData != nil))
        let body = """
        #!/bin/sh
        # 목적: 앱 수집 실패와 무관한 기존 Claude 상태 표시줄 보존
        quota_input=$(/usr/bin/mktemp -t claude-quota-input) || exit 0
        trap '/bin/rm -f "$quota_input"' EXIT HUP INT TERM
        /bin/cat > "$quota_input"
        \(oldCommand.map { "/bin/sh -c " + shellQuote($0) + " < \"$quota_input\"" } ?? "/usr/bin/printf 'Claude\\n'")
        if [ -x \(shellQuote(appExecutable.path)) ]; then
          exec 3< "$quota_input"
          \(shellQuote(appExecutable.path)) --claude-quota-capture \(shellQuote(home.path)) \(shellQuote(cliExecutable.path)) <&3 >/dev/null 2>&1 &
        fi
        exit 0
        """
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let priorScript = try? Data(contentsOf: script(home: home))
        let priorManifest = try? Data(contentsOf: manifestURL)
        do {
            try Data(body.utf8).write(to: script(home: home), options: [.atomic])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script(home: home).path)
            try JSONEncoder().encode(manifest).write(to: manifestURL, options: [.atomic])
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
            try willWriteSettings()
            guard (try? Data(contentsOf: settingsURL)) == originalData else { throw ClaudeQuotaError.settingsChanged }
            settings["statusLine"] = installed
            try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: settingsURL, options: [.atomic])
        } catch {
            if let priorScript { try? priorScript.write(to: script(home: home), options: [.atomic]) }
            else { try? manager.removeItem(at: script(home: home)) }
            if let priorManifest { try? priorManifest.write(to: manifestURL, options: [.atomic]) }
            else { try? manager.removeItem(at: manifestURL) }
            throw error
        }
    }

    /// 설치 후 사용자가 수정한 값은 덮어쓰지 않는 원본 상태 표시줄 복원
    public static func remove(home: URL) throws {
        let settingsURL = home.appendingPathComponent("settings.json")
        let manifestURL = ClaudeQuotaSnapshot.directory(home: home).appendingPathComponent("connection.json")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let before = try Data(contentsOf: settingsURL)
        guard var settings = try JSONSerialization.jsonObject(with: before) as? [String: Any],
              let current = settings["statusLine"],
              try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]) == manifest.installed
        else { throw ClaudeQuotaError.settingsChanged }
        settings["statusLine"] = try manifest.original.map { try JSONSerialization.jsonObject(with: $0) }
        guard try Data(contentsOf: settingsURL) == before else { throw ClaudeQuotaError.settingsChanged }
        if settings.isEmpty && !manifest.settingsExisted {
            try FileManager.default.removeItem(at: settingsURL)
        } else {
            try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: settingsURL, options: [.atomic])
        }
        try FileManager.default.removeItem(at: manifestURL)
        try FileManager.default.removeItem(at: script(home: home))
    }
}
