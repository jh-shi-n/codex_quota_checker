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
        case .telemetryUnavailable: return "공식 토큰 수집기를 실행하지 못했습니다. 로컬 포트 사용 상태를 확인한 뒤 다시 연결해 주세요."
        case .telemetryConflict: return "기존 OpenTelemetry 수집 설정이 있어 유지했습니다. 기존 수집 경로를 해제한 뒤 다시 연결해 주세요."
        case .rateLimited: return "Claude 사용량 조회가 제한되었습니다. 잠시 후 다시 시도해 주세요. 표시된 값은 마지막 수신값입니다."
        case .staleUsage: return "Claude가 만료된 한도만 반환했습니다. 새 한도를 다시 확인해 주세요."
        case .liveQueryFailed: return "Claude 공식 /usage 조회를 완료하지 못했습니다. CLI 로그인 상태를 확인해 주세요."
        case .cliMissing: return "Claude CLI를 찾지 못했습니다."
        case .loginRequired: return "선택한 폴더의 Claude CLI에 로그인해 주세요."
        case .unsupportedAccount: return "Claude Pro·Max 구독의 할당량만 지원합니다. API 계정은 별도 과금입니다."
        case .timeout: return "Claude CLI 응답 대기 시간이 초과되었습니다. 잠시 후 다시 시도해 주세요."
        case .invalidData: return "Claude 할당량 또는 설정 파일을 읽을 수 없습니다."
        case .settingsChanged: return "수집 연결 이후 Claude 설정이 변경되었습니다. 현재 설정을 보존했습니다."
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
