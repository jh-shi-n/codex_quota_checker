import Foundation

public enum CodexQuotaServiceError: Error, Equatable, Sendable {
    case notConfigured
    case loginRequired
    case codexNotFound
    case timeout
    case cancelled
    case processCrashed(Int32?)
    case malformedResponse(String)
    case protocolError(String)
    case transport(String)
}

extension CodexQuotaServiceError: LocalizedError {
    public var errorDescription: String? {
        appErrorCode.message(failureSummary)
    }

    /// 외부 응답·프로토콜 원문 대신 고정된 사용자 안내 반환
    private var failureSummary: String {
        switch self {
        case .notConfigured:
            return "Account not configured"
        case .loginRequired:
            return "Login required"
        case .codexNotFound:
            return "Codex executable not found"
        case .timeout:
            return "Codex app-server timed out"
        case .cancelled:
            return "Codex app-server request was cancelled"
        case let .processCrashed(status):
            if let status { return "Codex app-server exited with status \(status)" }
            return "Codex app-server exited unexpectedly"
        case .malformedResponse:
            return "Codex 응답을 해석하지 못했습니다."
        case .protocolError:
            return "Codex 요청 처리에 실패했습니다."
        case .transport:
            return "Codex 연결에 실패했습니다."
        }
    }
}

/// A quota snapshot containing the rolling five-hour primary quota and the
/// overall secondary quota when the server supplies it.
public struct CodexQuota: Equatable, Sendable {
    public let resetCredits: RateLimitResetCredits?
    public let email: String?
    public let planType: String?
    public let primaryResetAt: Date?
    public let secondaryResetAt: Date?
    let primaryWindowIsOverall: Bool
    private let normalizedPrimaryUsedPercent: Double
    private let normalizedSecondaryUsedPercent: Double?

    public var primaryUsedPercent: Double { normalizedPrimaryUsedPercent }
    public var primaryRemainingPercent: Double { AccountState.clampPercent(100 - normalizedPrimaryUsedPercent) }
    public var secondaryUsedPercent: Double? { normalizedSecondaryUsedPercent }
    public var secondaryRemainingPercent: Double? {
        normalizedSecondaryUsedPercent.map { AccountState.clampPercent(100 - $0) }
    }

    public var usedPercent: Double { primaryUsedPercent }
    public var remainingPercent: Double { primaryRemainingPercent }
    public var resetAt: Date? { primaryResetAt }

    public init(
        email: String? = nil,
        planType: String? = nil,
        primaryUsedPercent: Double,
        secondaryUsedPercent: Double? = nil,
        primaryResetAt: Date? = nil,
        secondaryResetAt: Date? = nil,
        resetCredits: RateLimitResetCredits? = nil
    ) {
        self.init(
            email: email,
            planType: planType,
            primaryUsedPercent: primaryUsedPercent,
            primaryWindowIsOverall: false,
            secondaryUsedPercent: secondaryUsedPercent,
            primaryResetAt: primaryResetAt,
            secondaryResetAt: secondaryResetAt,
            resetCredits: resetCredits
        )
    }

    init(
        email: String? = nil,
        planType: String? = nil,
        primaryUsedPercent: Double,
        primaryWindowIsOverall: Bool,
        secondaryUsedPercent: Double? = nil,
        primaryResetAt: Date? = nil,
        secondaryResetAt: Date? = nil,
        resetCredits: RateLimitResetCredits? = nil
    ) {
        self.resetCredits = resetCredits
        self.email = email
        self.planType = planType
        self.primaryResetAt = primaryResetAt
        self.secondaryResetAt = secondaryResetAt
        self.primaryWindowIsOverall = primaryWindowIsOverall
        self.normalizedPrimaryUsedPercent = AccountState.clampPercent(primaryUsedPercent)
        self.normalizedSecondaryUsedPercent = secondaryUsedPercent.map(AccountState.clampPercent)
    }

    public init(
        email: String? = nil,
        planType: String? = nil,
        usedPercent: Double,
        resetAt: Date? = nil
    ) {
        self.init(
            email: email,
            planType: planType,
            primaryUsedPercent: usedPercent,
            secondaryUsedPercent: usedPercent,
            primaryResetAt: resetAt,
            secondaryResetAt: resetAt
        )
    }
}

public typealias CodexProcessFactory = @Sendable () -> any CodexProcessTransport

/// Queries one account through the Codex app-server JSON-line protocol.
public struct CodexQuotaService: Sendable {
    public static let overallTimeout: TimeInterval = 12

    /// 확인된 단일 사용 시도 실행; 응답 유실 시 동일 키로만 재시도
    public func consumeResetCredit(
        for config: AccountConfig, creditID: String, idempotencyKey: String
    ) async -> Result<ResetCreditOutcome, CodexQuotaServiceError> {
        await Task.detached {
            self.consumeResetCreditSync(for: config, creditID: creditID, idempotencyKey: idempotencyKey)
        }.value
    }

    /// 계정별 app-server 초기화 후 선택 리셋권 사용 요청 1회 전송
    func consumeResetCreditSync(
        for config: AccountConfig, creditID: String, idempotencyKey: String
    ) -> Result<ResetCreditOutcome, CodexQuotaServiceError> {
        guard config.isConfigured else { return .failure(.notConfigured) }
        guard !creditID.isEmpty, !idempotencyKey.isEmpty else {
            return .failure(.protocolError("리셋권 식별자 또는 요청 키가 없습니다."))
        }
        guard FileManager.default.fileExists(atPath: config.authFile.path) else { return .failure(.loginRequired) }
        guard let executable = locator.locate() else { return .failure(.codexNotFound) }
        let deadline = Date().addingTimeInterval(Self.overallTimeout)
        let process = processFactory()
        defer { process.terminate(until: deadline) }
        do {
            try process.launch(executable: executable, home: config.home)
            try process.send(CodexProtocol.initializeRequest)
            guard let response = try process.readResponses(for: [0], until: deadline)[0] else {
                throw CodexQuotaServiceError.timeout
            }
            try validateResponse(response, requestName: "initialize")
            try process.send(CodexRequest(method: "initialized", params: .object([:])))
            try process.send(CodexRequest(id: 3, method: "account/rateLimitResetCredit/consume", params: .object([
                "creditId": .string(creditID), "idempotencyKey": .string(idempotencyKey),
            ])))
            guard let response = try process.readResponses(for: [3], until: deadline)[3] else {
                throw CodexQuotaServiceError.timeout
            }
            try validateResponse(response, requestName: "account/rateLimitResetCredit/consume")
            guard let raw = response.result?.objectValue?["outcome"]?.stringValue,
                  let outcome = ResetCreditOutcome(rawValue: raw) else {
                throw CodexQuotaServiceError.malformedResponse("리셋권 사용 결과를 확인할 수 없습니다.")
            }
            return .success(outcome)
        } catch let error as CodexQuotaServiceError {
            return .failure(error)
        } catch let error as CodexProcessError {
            return .failure(map(error))
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    private let locator: any CodexLocating
    private let processFactory: CodexProcessFactory

    public init(
        locator: any CodexLocating = CodexLocator(),
        processFactory: @escaping CodexProcessFactory = { CodexProcess() }
    ) {
        self.locator = locator
        self.processFactory = processFactory
    }

    /// 호출자 취소를 detached 조회와 transport에 전달
    public func fetch(for config: AccountConfig) async -> Result<CodexQuota, CodexQuotaServiceError> {
        if Task.isCancelled { return .failure(.cancelled) }
        let cancellation = CodexQuotaFetchCancellation()
        let execution = Task.detached(priority: nil) {
            self.fetchSync(for: config, cancellation: cancellation)
        }
        return await withTaskCancellationHandler {
            let result = await execution.value
            return Task.isCancelled ? .failure(.cancelled) : result
        } onCancel: {
            execution.cancel()
            cancellation.cancel()
        }
    }

    /// Synchronous core used by the async wrapper and deterministic transport tests.
    public func fetchSync(for config: AccountConfig) -> Result<CodexQuota, CodexQuotaServiceError> {
        fetchSync(for: config, cancellation: nil)
    }

    /// 취소 token을 확인하며 동기 프로토콜 조회 수행
    private func fetchSync(
        for config: AccountConfig,
        cancellation: CodexQuotaFetchCancellation?
    ) -> Result<CodexQuota, CodexQuotaServiceError> {
        guard cancellation?.isCancelled != true else { return .failure(.cancelled) }
        guard config.isConfigured else {
            return .failure(.notConfigured)
        }
        guard FileManager.default.fileExists(atPath: config.authFile.path) else {
            return .failure(.loginRequired)
        }
        guard let executable = locator.locate() else {
            return .failure(.codexNotFound)
        }

        let deadline = Date().addingTimeInterval(Self.overallTimeout)
        let process = processFactory()
        cancellation?.install(process)
        defer { process.terminate(until: deadline) }
        guard cancellation?.isCancelled != true else { return .failure(.cancelled) }

        do {
            try process.launch(executable: executable, home: config.home)

            // The initialize request is deliberately sent alone. Some app-server
            // versions do not process later requests until its response is read.
            try process.send(CodexProtocol.initializeRequest)
            let initializeResponses = try process.readResponses(for: [0], until: deadline)
            guard let initializeResponse = initializeResponses[0] else {
                throw CodexQuotaServiceError.timeout
            }
            try validateResponse(initializeResponse, requestName: "initialize")

            for request in CodexProtocol.postInitializeRequests {
                try process.send(request)
            }

            let responses = try process.readResponses(for: [1, 2], until: deadline)
            guard let accountResponse = responses[1] else {
                throw CodexQuotaServiceError.timeout
            }
            guard let rateLimitsResponse = responses[2] else {
                throw CodexQuotaServiceError.timeout
            }
            try validateResponse(accountResponse, requestName: "account/read")
            try validateResponse(rateLimitsResponse, requestName: "account/rateLimits/read")

            if cancellation?.isCancelled == true { throw CodexProcessError.cancelled }
            return .success(try parseQuota(accountResponse: accountResponse, rateLimitsResponse: rateLimitsResponse))
        } catch let error as CodexQuotaServiceError {
            return .failure(cancellation?.isCancelled == true ? .cancelled : error)
        } catch let error as CodexProcessError {
            return .failure(cancellation?.isCancelled == true ? .cancelled : map(error))
        } catch {
            return .failure(cancellation?.isCancelled == true ? .cancelled : .transport(error.localizedDescription))
        }
    }

    /// 할당량 조회와 독립된 읽기 전용 계정 토큰 요청 및 취소 전파
    public func fetchTokenUsage(for config: AccountConfig) async -> Result<AccountTokenUsage, CodexQuotaServiceError> {
        if Task.isCancelled { return .failure(.cancelled) }
        let cancellation = CodexQuotaFetchCancellation()
        let execution = Task.detached { self.fetchTokenUsageSync(for: config, cancellation: cancellation) }
        return await withTaskCancellationHandler {
            let result = await execution.value
            return Task.isCancelled ? .failure(.cancelled) : result
        } onCancel: {
            execution.cancel()
            cancellation.cancel()
        }
    }

    /// 초기화 완료 후 토큰 RPC 한 번만 전송; 기존 할당량 경로와 수명 분리
    func fetchTokenUsageSync(
        for config: AccountConfig, cancellation: CodexQuotaFetchCancellation? = nil
    ) -> Result<AccountTokenUsage, CodexQuotaServiceError> {
        guard cancellation?.isCancelled != true else { return .failure(.cancelled) }
        guard config.isConfigured else { return .failure(.notConfigured) }
        guard FileManager.default.fileExists(atPath: config.authFile.path) else { return .failure(.loginRequired) }
        guard let executable = locator.locate() else { return .failure(.codexNotFound) }
        let deadline = Date().addingTimeInterval(Self.overallTimeout)
        let process = processFactory()
        cancellation?.install(process)
        defer { process.terminate(until: deadline) }
        do {
            guard cancellation?.isCancelled != true else { throw CodexProcessError.cancelled }
            try process.launch(executable: executable, home: config.home)
            try process.send(CodexProtocol.initializeRequest)
            guard let response = try process.readResponses(for: [0], until: deadline)[0] else {
                throw CodexQuotaServiceError.timeout
            }
            try validateResponse(response, requestName: "initialize")
            try process.send(CodexRequest(method: "initialized", params: .object([:])))
            try process.send(CodexRequest(id: 1, method: "account/read", params: .object(["refreshToken": .bool(false)])))
            try process.send(CodexRequest(id: 4, method: "account/usage/read"))
            let responses = try process.readResponses(for: [1, 4], until: deadline)
            guard let accountResponse = responses[1], let response = responses[4] else {
                throw CodexQuotaServiceError.timeout
            }
            try validateResponse(accountResponse, requestName: "account/read")
            try validateResponse(response, requestName: "account/usage/read")
            guard cancellation?.isCancelled != true else { throw CodexProcessError.cancelled }
            guard let result = response.result else { throw CodexQuotaServiceError.malformedResponse("Missing usage result") }
            let email = accountResponse.result?.objectValue?["account"]?.objectValue?["email"]?.stringValue
            return .success(try AccountTokenUsage(result: result, accountEmail: email))
        } catch let error as CodexQuotaServiceError { return .failure(error) }
        catch let error as CodexProcessError { return .failure(map(error)) }
        catch { return .failure(.transport(error.localizedDescription)) }
    }

    /// 계정 상태 조회와 호출자 취소 전파
    public func state(for config: AccountConfig) async -> AccountState {
        let result = await fetch(for: config)
        guard !Task.isCancelled else { return AccountState.loading(id: config.id) }
        return state(from: result, for: config)
    }

    public func stateSync(for config: AccountConfig) -> AccountState {
        state(from: fetchSync(for: config), for: config)
    }

    /// 취소된 조회는 이전 실패 상태를 새 결과처럼 보이지 않도록 loading으로 반환
    private func state(
        from result: Result<CodexQuota, CodexQuotaServiceError>,
        for config: AccountConfig
    ) -> AccountState {
        switch result {
        case let .success(quota):
            let primaryIsOverall = quota.primaryWindowIsOverall
            return AccountState(
                id: config.id,
                email: quota.email,
                planType: quota.planType,
                primaryUsedPercent: primaryIsOverall ? nil : quota.primaryUsedPercent,
                secondaryUsedPercent: primaryIsOverall
                    ? quota.secondaryUsedPercent ?? quota.primaryUsedPercent
                    : quota.secondaryUsedPercent,
                primaryResetAt: primaryIsOverall ? nil : quota.primaryResetAt,
                secondaryResetAt: primaryIsOverall
                    ? quota.secondaryResetAt ?? quota.primaryResetAt
                    : quota.secondaryResetAt,
                resetCredits: quota.resetCredits,
                lastUpdated: Date(),
                status: .normal
            )
        case let .failure(error):
            if error == .notConfigured {
                return AccountState.notConfigured(id: config.id)
            }
            if error == .cancelled {
                return AccountState.loading(id: config.id)
            }
            let status: AccountStatus
            switch error {
            case .notConfigured:
                // Handled above so the presentation state does not carry an
                // error message for a deliberate empty settings slot.
                status = .notConfigured
            case .loginRequired:
                status = .loginRequired
            case .codexNotFound:
                status = .codexNotFound
            case .timeout:
                status = .timeout
            case .processCrashed, .malformedResponse, .protocolError, .transport, .cancelled:
                status = .error
            }
            return AccountState(
                id: config.id,
                status: status,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func validateResponse(_ message: CodexMessage, requestName: String) throws {
        if message.containsError {
            guard let error = message.error else {
                throw CodexQuotaServiceError.malformedResponse("Invalid error object for \(requestName)")
            }
            throw CodexQuotaServiceError.protocolError(
                error.message ?? "Request \(requestName) failed"
            )
        }
        guard message.hasResult else {
            throw CodexQuotaServiceError.malformedResponse("Missing result for \(requestName)")
        }
    }

    private func parseQuota(
        accountResponse: CodexMessage,
        rateLimitsResponse: CodexMessage
    ) throws -> CodexQuota {
        var email: String?
        var planType: String?

        if let accountValue = accountResponse.result?.objectValue?["account"], accountValue != .null {
            guard let account = accountValue.objectValue else {
                throw CodexQuotaServiceError.malformedResponse("account is not an object")
            }
            email = account["email"]?.stringValue
            planType = account["planType"]?.stringValue
        }

        guard let result = rateLimitsResponse.result?.objectValue else {
            throw CodexQuotaServiceError.malformedResponse("Missing rate limit result")
        }
        let limits = result["rateLimits"]?.objectValue ?? [:]
        let limitsByID = result["rateLimitsByLimitId"]?.objectValue
        let candidates = [
            classifyLimit(
                key: "primary",
                values: limit(key: "primary", historicalLimits: limits, limitsByID: limitsByID)
            ),
            classifyLimit(
                key: "secondary",
                values: limit(key: "secondary", historicalLimits: limits, limitsByID: limitsByID)
            ),
        ].compactMap { $0 }
        let primary = selectLimit(candidates, window: .fiveHour)
        let secondary = selectLimit(candidates, window: .overall)
        guard let selected = primary ?? secondary,
              let selectedUsedPercent = finiteUsedPercent(in: selected.values) else {
            throw CodexQuotaServiceError.malformedResponse("Missing rateLimits.primary.usedPercent")
        }

        return CodexQuota(
            email: email,
            planType: planType,
            primaryUsedPercent: selectedUsedPercent,
            primaryWindowIsOverall: primary == nil && secondary != nil,
            secondaryUsedPercent: secondary.flatMap { finiteUsedPercent(in: $0.values) },
            primaryResetAt: primary.flatMap { resetDate(in: $0.values) },
            secondaryResetAt: secondary.flatMap { resetDate(in: $0.values) },
            resetCredits: RateLimitResetCredits.parse(result["rateLimitResetCredits"])
        )
    }

    private enum QuotaWindow: Equatable {
        case fiveHour
        case overall
    }

    private struct ClassifiedLimit {
        let window: QuotaWindow
        let values: [String: CodexJSONValue]
        let usesExplicitDuration: Bool
    }

    private func classifyLimit(
        key: String,
        values: [String: CodexJSONValue]?
    ) -> ClassifiedLimit? {
        guard let values else { return nil }
        if let duration = values["windowDurationMins"]?.numberValue {
            guard duration.isFinite else { return nil }
            if duration == 300 {
                return ClassifiedLimit(window: .fiveHour, values: values, usesExplicitDuration: true)
            }
            if duration == 10080 {
                return ClassifiedLimit(window: .overall, values: values, usesExplicitDuration: true)
            }
            return nil
        }

        let window: QuotaWindow = key == "primary" ? .fiveHour : .overall
        return ClassifiedLimit(window: window, values: values, usesExplicitDuration: false)
    }

    private func selectLimit(
        _ candidates: [ClassifiedLimit],
        window: QuotaWindow
    ) -> ClassifiedLimit? {
        candidates.first { $0.window == window && $0.usesExplicitDuration }
            ?? candidates.first { $0.window == window }
    }

    private func finiteUsedPercent(in values: [String: CodexJSONValue]) -> Double? {
        values["usedPercent"]?.numberValue.flatMap { $0.isFinite ? $0 : nil }
    }

    private func resetDate(in values: [String: CodexJSONValue]) -> Date? {
        values["resetsAt"]?.numberValue.map(Date.init(timeIntervalSince1970:))
    }

    /// Prefer historical fields, then the metered Codex bucket used by newer
    /// app-server versions. No other product bucket is eligible.
    private func limit(
        key: String,
        historicalLimits: [String: CodexJSONValue],
        limitsByID: [String: CodexJSONValue]?
    ) -> [String: CodexJSONValue]? {
        if let historical = historicalLimits[key], historical != .null {
            return historical.objectValue
        }

        return limitsByID?["codex"]?.objectValue?[key]?.objectValue
    }

    private func map(_ error: CodexProcessError) -> CodexQuotaServiceError {
        switch error {
        case .timeout:
            return .timeout
        case .cancelled:
            return .cancelled
        case let .processExited(status):
            return .processCrashed(status)
        case let .launchFailed(message):
            return .transport(message)
        case .notRunning:
            return .processCrashed(nil)
        case let .writeFailed(message), let .readFailed(message):
            return .transport(message)
        }
    }
}

final class CodexQuotaFetchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var transport: (any CodexProcessTransport)?
    private var transportCancellationSent = false

    /// 잠금 안의 취소 상태 조회
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// 조회 transport를 등록하고 선행 취소를 한 번 전달
    func install(_ transport: any CodexProcessTransport) {
        lock.lock()
        self.transport = transport
        let shouldCancel = cancelled && !transportCancellationSent
        if shouldCancel { transportCancellationSent = true }
        lock.unlock()
        if shouldCancel { transport.cancel() }
    }

    /// 동기 read를 깨울 transport 취소를 중복 없이 전달
    func cancel() {
        lock.lock()
        cancelled = true
        let transport = self.transport
        let shouldCancel = transport != nil && !transportCancellationSent
        if shouldCancel { transportCancellationSent = true }
        lock.unlock()
        if shouldCancel { transport?.cancel() }
    }
}
