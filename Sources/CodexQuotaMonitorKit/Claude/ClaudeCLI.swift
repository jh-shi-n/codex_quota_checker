// 목적: 선택 Claude 폴더의 인증 조회와 제한시간 실행
// 이용처: 계정 연결·할당량 스냅샷의 계정 검증
// 사용방법: ClaudeCLI.authentication(home:) 호출
// 실행 예시: try ClaudeCLI().authentication(home: selectedFolder)
import CryptoKit
import Darwin
import Foundation

/// 인증정보 원문을 포함하지 않는 CLI 실패 구분
public enum ClaudeQuotaError: Error, LocalizedError, Equatable {
    case cliMissing, loginRequired, unsupportedAccount, timeout, invalidData, settingsChanged, rateLimited, liveQueryFailed, staleUsage, telemetryConflict, telemetryUnavailable

    public var errorDescription: String? {
        switch self {
        case .telemetryUnavailable: return "Claude - Token collector failed to start"
        case .telemetryConflict: return "Claude - OpenTelemetry settings conflict"
        case .rateLimited: return "Claude - Usage query rate limited"
        case .staleUsage: return "Claude - Only expired quota returned"
        case .liveQueryFailed: return "Claude - /usage query failed"
        case .cliMissing: return "Claude - Claude cli not found"
        case .loginRequired: return "Claude - Login Required"
        case .unsupportedAccount: return "Claude - Pro·Max subscription required"
        case .timeout: return "Claude - CLI timed out"
        case .invalidData: return "Claude - Invalid quota data"
        case .settingsChanged: return "Claude - Settings changed"
        }
    }
}

/// 계정 표시값과 비밀정보 없는 스냅샷 식별자
public struct ClaudeAuthentication: Decodable, Sendable {
    public let loggedIn: Bool
    public let authMethod: String?
    public let email: String?
    public let orgId: String?
    public let subscriptionType: String?

    public var identity: String {
        let value = [email ?? "", orgId ?? "", authMethod ?? ""].joined(separator: "\n")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public var supportsQuota: Bool {
        authMethod == "claude.ai" && ["pro", "max"].contains(subscriptionType?.lowercased() ?? "")
    }
}

/// GUI 실행 환경의 PATH 누락과 Claude 설정 경로를 처리하는 실행 경계
public struct ClaudeCLI: Sendable {
    public let executable: URL?
    public let timeout: TimeInterval

    /// 실행 파일·제한시간의 테스트 주입 및 기본 CLI 탐색
    public init(executable: URL? = ClaudeCLI.locate(), timeout: TimeInterval = 5) {
        self.executable = executable
        self.timeout = timeout
    }

    /// 셸 실행 없이 PATH·사용자 기본 설치 경로에서 CLI 탐색
    public static func locate() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let paths = (environment["PATH"] ?? "").split(separator: ":").map {
            URL(fileURLWithPath: String($0)).appendingPathComponent("claude")
        } + [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude"),
             URL(fileURLWithPath: "/opt/homebrew/bin/claude"), URL(fileURLWithPath: "/usr/local/bin/claude")]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// 기본 폴더의 키체인 식별 유지 및 커스텀 설정 폴더 격리
    public static func environment(home: URL, inherited: [String: String] = ProcessInfo.processInfo.environment,
                                   userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: String] {
        var environment = inherited
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CONFIG_DIR"] {
            environment.removeValue(forKey: key)
        }
        if home.resolvingSymlinksInPath().standardizedFileURL != userHome.appendingPathComponent(".claude").resolvingSymlinksInPath().standardizedFileURL {
            environment["CLAUDE_CONFIG_DIR"] = home.path
        }
        return environment
    }

    /// API 키 환경 우회를 제거하고 선택 설정 폴더의 로그인 상태만 조회
    public func authentication(home: URL) throws -> ClaudeAuthentication {
        let data = try run(arguments: ["auth", "status"], home: home, limit: timeout)
        guard let authentication = try? JSONDecoder().decode(ClaudeAuthentication.self, from: data) else { throw ClaudeQuotaError.invalidData }
        guard authentication.loggedIn, authentication.email?.isEmpty == false else { throw ClaudeQuotaError.loginRequired }
        return authentication
    }

    /// 표준입력을 닫은 CLI 명령의 크기·시간 제한 실행, 민감 출력의 로그 제외
    func run(arguments: [String], home: URL, limit: TimeInterval) throws -> Data {
        guard let executable else { throw ClaudeQuotaError.cliMissing }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = Self.environment(home: home)
        process.currentDirectoryURL = home
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        process.standardOutput = handle
        try process.run()
        let deadline = Date().addingTimeInterval(limit)
        while process.isRunning && Date() < deadline && !Task.isCancelled {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(0.25)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw ClaudeQuotaError.timeout
        }
        let size = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber
        guard (size?.intValue ?? 0) <= 1_048_576 else { throw ClaudeQuotaError.invalidData }
        return try Data(contentsOf: output)
    }
}
