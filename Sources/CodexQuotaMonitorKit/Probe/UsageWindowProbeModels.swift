import Foundation

/// The small, user-safe set of failure categories exposed by a usage-window
/// probe. Raw process output and operating-system errors are intentionally not
/// represented here.
public enum UsageWindowProbeFailureCategory: String, Codable, Equatable, Sendable {
    case notConfigured
    case missingAuthentication
    case executableUnavailable
    case alreadyRunning
    case timeout
    case configurationFailure
    case launchFailure
    case processFailure
    case nonZeroExit
    case unsupportedModel
    case authenticationFailure
    case rateLimited
    case commandFailure
    case malformedOutput

    /// Compatibility spellings useful to hosts that use shorter labels.
    public static var missingAuth: Self { .missingAuthentication }
    public static var authMissing: Self { .missingAuthentication }
    public static var executableMissing: Self { .executableUnavailable }
    public static var executableNotFound: Self { .executableUnavailable }
    public static var alreadyInProgress: Self { .alreadyRunning }
    public static var nonzeroExit: Self { .nonZeroExit }
    public static var malformedOnlyOutput: Self { .malformedOutput }

    /// A deliberately generic message suitable for presentation in the app.
    public var userMessage: String {
        appErrorCode.message(failureSummary)
    }

    /// CLI 원문을 제외한 실패 원인 안내
    private var failureSummary: String {
        switch self {
        case .notConfigured:
            return "이 계정은 설정되지 않았습니다."
        case .missingAuthentication:
            return "이 계정의 Codex 로그인 정보를 찾을 수 없습니다."
        case .executableUnavailable:
            return "Codex 실행 파일을 찾을 수 없습니다."
        case .alreadyRunning:
            return "이 계정의 사용량 확인이 이미 실행 중입니다."
        case .timeout:
            return "사용량 확인 시간이 초과되었습니다."
        case .configurationFailure:
            return "설치된 CLI의 최소 Ping 구성을 만들지 못했습니다. CLI와 모델 카탈로그 지원을 확인해 주세요."
        case .launchFailure:
            return "Codex 사용량 확인을 시작하지 못했습니다."
        case .processFailure:
            return "Codex 사용량 확인 프로세스를 완료하지 못했습니다."
        case .nonZeroExit:
            return "Codex 사용량 확인이 완료되지 않았습니다."
        case .unsupportedModel:
            return "현재 Codex에서 Luna Light 모델을 사용할 수 없습니다."
        case .authenticationFailure:
            return "Codex 인증에 실패했습니다. 로그인 상태를 확인해 주세요."
        case .rateLimited:
            return "Codex 요청이 제한되었습니다. 잠시 후 다시 시도해 주세요."
        case .commandFailure:
            return "Codex가 사용량 확인 요청을 처리하지 못했습니다."
        case .malformedOutput:
            return "Codex 사용량 확인 결과를 해석하지 못했습니다."
        }
    }
}

public enum UsageWindowProbeResultStatus: String, Codable, Equatable, Sendable {
    case success
    case failure
    case cancelled
}

/// Counts reported by Codex. A missing field stays nil; the probe never
/// fabricates a count from an unrelated output value.
public struct UsageWindowProbeTokenUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let totalTokens: Int?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        totalTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }

    public var hasReportedUsage: Bool {
        inputTokens != nil || outputTokens != nil || totalTokens != nil
    }

    /// A convenience for hosts that want to display a total when the server
    /// supplied both components but omitted its own total field.
    public var totalTokensIncludingComponents: Int? {
        if let totalTokens { return totalTokens }
        guard let inputTokens, let outputTokens else { return nil }
        let (sum, overflow) = inputTokens.addingReportingOverflow(outputTokens)
        return overflow ? nil : sum
    }

    // Common compatibility aliases for UI code.
    public var promptTokens: Int? { inputTokens }
    public var completionTokens: Int? { outputTokens }
}

/// Public command metadata safe to keep in UI state. It contains no account
/// path, authentication information, prompt, or process output.
public struct UsageWindowProbeCommandMetadata: Codable, Equatable, Sendable {
    public static let displayName = "Luna Light"
    public static let modelIdentifier = "gpt-5.6-luna"

    public let displayName: String
    public let modelIdentifier: String
    public let sandbox: String
    public let isEphemeral: Bool
    public let skipsGitRepositoryCheck: Bool
    public let ignoresRules: Bool

    public init(
        displayName: String = Self.displayName,
        modelIdentifier: String = Self.modelIdentifier,
        sandbox: String = "read-only",
        isEphemeral: Bool = true,
        skipsGitRepositoryCheck: Bool = true,
        ignoresRules: Bool = true
    ) {
        self.displayName = displayName
        self.modelIdentifier = modelIdentifier
        self.sandbox = sandbox
        self.isEphemeral = isEphemeral
        self.skipsGitRepositoryCheck = skipsGitRepositoryCheck
        self.ignoresRules = ignoresRules
    }

    public static let `default` = Self()
}

public typealias UsageWindowProbeCommandContractMetadata = UsageWindowProbeCommandMetadata
public typealias UsageWindowProbeTokenCounts = UsageWindowProbeTokenUsage

/// The bounded result returned to callers. It deliberately contains only
/// metadata needed by the UI and never exposes stdout, stderr, prompts, paths,
/// authentication data, or account email addresses.
public struct UsageWindowProbeResult: Codable, Equatable, Sendable {
    public let accountID: String
    public let status: UsageWindowProbeResultStatus
    public let startedAt: Date
    public let completedAt: Date
    public let usage: UsageWindowProbeTokenUsage?
    public let failureCategory: UsageWindowProbeFailureCategory?
    public let userMessage: String
    public let commandMetadata: UsageWindowProbeCommandMetadata

    public init(
        accountID: String,
        status: UsageWindowProbeResultStatus,
        startedAt: Date,
        completedAt: Date,
        usage: UsageWindowProbeTokenUsage? = nil,
        failureCategory: UsageWindowProbeFailureCategory? = nil,
        userMessage: String? = nil,
        commandMetadata: UsageWindowProbeCommandMetadata = .default
    ) {
        self.accountID = accountID
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.usage = usage
        self.failureCategory = failureCategory
        self.userMessage = userMessage ?? failureCategory?.userMessage ??
            (status == .cancelled ? "사용량 확인이 취소되었습니다." : "사용량 확인이 완료되었습니다.")
        self.commandMetadata = commandMetadata
    }

    public var isSuccess: Bool { status == .success }
    public var isCancelled: Bool { status == .cancelled }
    public var succeeded: Bool { isSuccess }
    public var failure: UsageWindowProbeFailureCategory? { failureCategory }

    public var inputTokens: Int? { usage?.inputTokens }
    public var outputTokens: Int? { usage?.outputTokens }
    public var totalTokens: Int? { usage?.totalTokens }
}

public enum UsageWindowProbeStateStatus: String, Codable, Equatable, Sendable {
    case idle
    case running
    case success
    case failure
    case cancelled
}

/// Latest per-account state retained by the service for UI observation.
public struct UsageWindowProbeState: Codable, Equatable, Sendable {
    public let accountID: String
    public let status: UsageWindowProbeStateStatus
    public let startedAt: Date?
    public let completedAt: Date?
    public let result: UsageWindowProbeResult?
    public let commandMetadata: UsageWindowProbeCommandMetadata

    public init(
        accountID: String,
        status: UsageWindowProbeStateStatus,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        result: UsageWindowProbeResult? = nil,
        commandMetadata: UsageWindowProbeCommandMetadata = .default
    ) {
        self.accountID = accountID
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.result = result
        self.commandMetadata = commandMetadata
    }

    public static func idle(accountID: String) -> Self {
        Self(accountID: accountID, status: .idle)
    }

    public var usage: UsageWindowProbeTokenUsage? { result?.usage }
    public var failureCategory: UsageWindowProbeFailureCategory? { result?.failureCategory }
    public var userMessage: String? { result?.userMessage }
}

/// Metadata for account-home authentication checks. The live implementation
/// queries this metadata only; it never opens auth.json.
public struct UsageWindowProbeFileMetadata: Equatable, Sendable {
    public let exists: Bool
    public let isRegularFile: Bool
    public let isReadable: Bool

    public init(
        exists: Bool,
        isRegularFile: Bool = true,
        isReadable: Bool = true
    ) {
        self.exists = exists
        self.isRegularFile = isRegularFile
        self.isReadable = isReadable
    }

    public var isUsableAuthenticationFile: Bool {
        exists && isRegularFile && isReadable
    }
}

public struct UsageWindowProbeFileSystem: Sendable {
    public let metadata: @Sendable (URL) -> UsageWindowProbeFileMetadata

    public init(metadata: @escaping @Sendable (URL) -> UsageWindowProbeFileMetadata) {
        self.metadata = metadata
    }

    public static let live = Self { url in
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let attributes = exists ? try? fileManager.attributesOfItem(atPath: url.path) : nil
        let isRegularFile = exists && !isDirectory.boolValue &&
            ((attributes?[.type] as? FileAttributeType) == .typeRegular)
        return UsageWindowProbeFileMetadata(
            exists: exists,
            isRegularFile: isRegularFile,
            isReadable: exists && fileManager.isReadableFile(atPath: url.path)
        )
    }
}

/// Errors thrown by the injected process runner. The cases intentionally do
/// not carry raw OS messages that could expose local paths or CLI output.
public enum UsageWindowProbeProcessError: Error, Equatable, Sendable {
    case timeout
    case configurationFailure
    case launchFailure
    case processFailure
    case cancelled
}

/// Bounded process data passed to the JSONL parser. The initializer truncates
/// both streams as a second safety boundary for injected runners.
public struct UsageWindowProbeProcessResult: Equatable, Sendable {
    public static let maximumStandardOutputBytes = 256 * 1_024
    public static let maximumStandardErrorBytes = 64 * 1_024

    public let exitStatus: Int32?
    public let stdout: Data
    public let stderr: Data

    public init(
        exitStatus: Int32?,
        stdout: Data = Data(),
        stderr: Data = Data()
    ) {
        self.exitStatus = exitStatus
        self.stdout = Data(stdout.prefix(Self.maximumStandardOutputBytes))
        self.stderr = Data(stderr.prefix(Self.maximumStandardErrorBytes))
    }

    public var exitCode: Int32? { exitStatus }
    public var standardOutput: Data { stdout }
    public var standardError: Data { stderr }
}

public typealias UsageWindowProbeProcessOutput = UsageWindowProbeProcessResult

public protocol UsageWindowProbeProcessRunning: Sendable {
    func run(
        command: UsageWindowProbeCommand,
        timeout: TimeInterval
    ) async throws -> UsageWindowProbeProcessResult
}
