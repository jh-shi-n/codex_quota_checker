import CoreFoundation
import Darwin
import Dispatch
import Foundation

/// A parser summary that contains only structured, non-sensitive facts about
/// the bounded JSONL stream.
public struct UsageWindowProbeParseResult: Equatable, Sendable {
    public let usage: UsageWindowProbeTokenUsage?
    public let sawNonWhitespaceOutput: Bool
    public let sawValidObject: Bool
    public let sawMalformedLine: Bool
    public let sawCompletion: Bool
    public let sawExpectedAssistantOutput: Bool
    public let sawError: Bool
    /// A bounded categorical diagnosis extracted only from an error event.
    /// No source text is retained or exposed.
    public let failureCategoryHint: UsageWindowProbeFailureCategory?

    public init(
        usage: UsageWindowProbeTokenUsage? = nil,
        sawNonWhitespaceOutput: Bool = false,
        sawValidObject: Bool = false,
        sawMalformedLine: Bool = false,
        sawCompletion: Bool = false,
        sawExpectedAssistantOutput: Bool = false,
        sawError: Bool = false,
        failureCategoryHint: UsageWindowProbeFailureCategory? = nil
    ) {
        self.usage = usage
        self.sawNonWhitespaceOutput = sawNonWhitespaceOutput
        self.sawValidObject = sawValidObject
        self.sawMalformedLine = sawMalformedLine
        self.sawCompletion = sawCompletion
        self.sawExpectedAssistantOutput = sawExpectedAssistantOutput
        self.sawError = sawError
        self.failureCategoryHint = failureCategoryHint
    }

    public var isMalformedOnlyOutput: Bool {
        sawNonWhitespaceOutput && sawMalformedLine && !sawValidObject
    }
}

/// Incremental, conservative JSONL parser for `codex exec --json` output.
/// It keeps no source text after each line is inspected.
public struct UsageWindowProbeJSONLParser: Sendable {
    public static let maximumLineBytes = 64 * 1_024
    public static let maximumBufferedBytes = 256 * 1_024

    private var buffer = Data()
    private var usage = UsageWindowProbeTokenUsage()
    private var sawNonWhitespaceOutput = false
    private var sawValidObject = false
    private var sawMalformedLine = false
    private var sawCompletion = false
    private var sawExpectedAssistantOutput = false
    private var sawError = false
    private var failureCategoryHint: UsageWindowProbeFailureCategory?

    public init() {}

    /// Appends arbitrary stdout chunks. Oversized fragments are treated as a
    /// malformed result and are not retained indefinitely.
    public mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }

        var start = data.startIndex
        while start < data.endIndex {
            guard let newline = data[start..<data.endIndex].firstIndex(of: 0x0A) else {
                appendFragment(data[start..<data.endIndex])
                return
            }

            appendFragment(data[start..<newline])
            consumeBufferedLine()
            start = data.index(after: newline)
        }
    }

    /// Parses a final line without a newline delimiter and returns the safe
    /// structured summary.
    public mutating func finish() -> UsageWindowProbeParseResult {
        if !buffer.isEmpty {
            consumeBufferedLine()
        }
        return parseResult
    }

    public var parseResult: UsageWindowProbeParseResult {
        UsageWindowProbeParseResult(
            usage: usage.hasReportedUsage ? usage : nil,
            sawNonWhitespaceOutput: sawNonWhitespaceOutput,
            sawValidObject: sawValidObject,
            sawMalformedLine: sawMalformedLine,
            sawCompletion: sawCompletion,
            sawExpectedAssistantOutput: sawExpectedAssistantOutput,
            sawError: sawError,
            failureCategoryHint: failureCategoryHint
        )
    }

    private mutating func appendFragment<S: Collection>(_ fragment: S) where S.Element == UInt8 {
        guard !fragment.isEmpty else { return }
        if buffer.count > Self.maximumBufferedBytes - fragment.count {
            buffer.removeAll(keepingCapacity: false)
            sawMalformedLine = true
            sawNonWhitespaceOutput = true
            return
        }
        buffer.append(contentsOf: fragment)
        if !fragment.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
            sawNonWhitespaceOutput = true
        }
        if buffer.count > Self.maximumLineBytes {
            buffer.removeAll(keepingCapacity: false)
            sawMalformedLine = true
        }
    }

    private mutating func consumeBufferedLine() {
        defer { buffer.removeAll(keepingCapacity: false) }
        guard !buffer.isEmpty else { return }
        let line = Data(buffer)
        let trimmed = line.drop(while: { byte in
            byte == 0x20 || byte == 0x09 || byte == 0x0D
        })
        guard !trimmed.isEmpty else { return }

        guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed), options: []),
              let dictionary = object as? [String: Any]
        else {
            sawMalformedLine = true
            return
        }

        sawValidObject = true
        if containsError(in: dictionary) {
            sawError = true
            if let hint = diagnosticHint(in: dictionary) {
                failureCategoryHint = preferredHint(failureCategoryHint, hint)
            }
        }
        if isTurnCompletionEvent(dictionary) {
            sawCompletion = true
        }
        if hasExpectedAssistantOutput(in: dictionary) {
            sawExpectedAssistantOutput = true
        }
        collectUsage(from: dictionary)
    }

    private func containsError(in dictionary: [String: Any]) -> Bool {
        containsError(in: dictionary as Any, depth: 0)
    }

    private func containsError(in value: Any, depth: Int) -> Bool {
        guard depth <= 5 else { return false }
        guard let dictionary = value as? [String: Any] else {
            if let array = value as? [Any] {
                return array.contains { containsError(in: $0, depth: depth + 1) }
            }
            return false
        }
        for (key, value) in dictionary {
            let normalizedKey = canonicalKey(key)
            if ["error", "errors", "failure", "failed"].contains(normalizedKey) {
                if hasMeaningfulErrorValue(value, depth: depth + 1) {
                    return true
                }
            }
            if ["type", "event", "method", "status", "state"].contains(normalizedKey),
               let text = value as? String,
               containsErrorWord(text) {
                return true
            }
            if ["item", "event", "response", "result", "data", "details"].contains(normalizedKey),
               containsError(in: value, depth: depth + 1) {
                return true
            }
        }
        return false
    }

    private func hasMeaningfulErrorValue(_ value: Any, depth: Int) -> Bool {
        guard depth <= 5 else { return false }
        if value is NSNull { return false }
        if let text = value as? String {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.contains { hasMeaningfulErrorValue($0, depth: depth + 1) }
        }
        if let array = value as? [Any] {
            return array.contains { hasMeaningfulErrorValue($0, depth: depth + 1) }
        }
        return false
    }

    private func containsErrorWord(_ value: String) -> Bool {
        let text = value.lowercased()
        return text.contains("error") || text.contains("failed") || text.contains("failure")
    }

    /// 완료된 turn 이벤트만 성공 조건으로 인정하는 판별
    private func isTurnCompletionEvent(_ dictionary: [String: Any]) -> Bool {
        dictionary["type"] as? String == "turn.completed"
    }

    /// item 완료 이벤트의 assistant 출력이 `1`인지 boolean으로만 확인하는 판별
    private func hasExpectedAssistantOutput(in dictionary: [String: Any]) -> Bool {
        guard dictionary["type"] as? String == "item.completed",
              let item = dictionary["item"] as? [String: Any],
              item["type"] as? String == "agent_message",
              let text = item["text"] as? String
        else {
            return false
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    private func diagnosticHint(in dictionary: [String: Any]) -> UsageWindowProbeFailureCategory? {
        var fragments: [String] = []
        collectDiagnosticText(from: dictionary, depth: 0, into: &fragments)
        return UsageWindowProbeDiagnostic.hint(from: fragments.joined(separator: " "))
    }

    private func collectDiagnosticText(
        from value: Any,
        depth: Int,
        into fragments: inout [String]
    ) {
        guard depth <= 4, fragments.count < 32 else { return }
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                let normalizedKey = canonicalKey(key)
                if ["error", "errors", "failure", "failed", "message", "reason", "detail", "code", "type", "status"].contains(normalizedKey) {
                    if let text = nested as? String {
                        fragments.append(text)
                    } else if let number = nested as? NSNumber {
                        fragments.append(number.stringValue)
                    }
                    collectDiagnosticText(from: nested, depth: depth + 1, into: &fragments)
                } else if ["response", "result", "data", "error"].contains(normalizedKey) {
                    collectDiagnosticText(from: nested, depth: depth + 1, into: &fragments)
                }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                collectDiagnosticText(from: nested, depth: depth + 1, into: &fragments)
            }
        }
    }

    private func preferredHint(
        _ current: UsageWindowProbeFailureCategory?,
        _ candidate: UsageWindowProbeFailureCategory
    ) -> UsageWindowProbeFailureCategory {
        guard let current else { return candidate }
        let rank: [UsageWindowProbeFailureCategory: Int] = [
            .unsupportedModel: 3,
            .authenticationFailure: 2,
            .rateLimited: 1,
        ]
        return (rank[candidate] ?? 0) > (rank[current] ?? 0) ? candidate : current
    }

    /// 제한된 JSON 트리에서 사용량 필드를 수집
    private mutating func collectUsage(from root: [String: Any]) {
        var remainingNodes = 2_048
        collectUsage(from: root, depth: 0, remainingNodes: &remainingNodes)
    }

    /// 부모 값을 먼저 적용한 뒤 자식 노드를 순회
    private mutating func collectUsage(
        from value: Any,
        depth: Int,
        remainingNodes: inout Int
    ) {
        guard depth <= 8, remainingNodes > 0 else { return }
        remainingNodes -= 1

        if let dictionary = value as? [String: Any] {
            var input = usage.inputTokens
            var output = usage.outputTokens
            var total = usage.totalTokens
            var children: [Any] = []
            for (key, rawValue) in dictionary {
                let normalizedKey = canonicalKey(key)
                if isInputTokenKey(normalizedKey), let count = tokenCount(rawValue) {
                    input = count
                } else if isOutputTokenKey(normalizedKey), let count = tokenCount(rawValue) {
                    output = count
                } else if isTotalTokenKey(normalizedKey), let count = tokenCount(rawValue) {
                    total = count
                }
                if isUsageContainerKey(normalizedKey) || rawValue is [String: Any] || rawValue is [Any] {
                    children.append(rawValue)
                }
            }
            usage = UsageWindowProbeTokenUsage(
                inputTokens: input,
                outputTokens: output,
                totalTokens: total
            )

            for nested in children {
                collectUsage(from: nested, depth: depth + 1, remainingNodes: &remainingNodes)
            }
        } else if let array = value as? [Any] {
            for nested in array {
                collectUsage(from: nested, depth: depth + 1, remainingNodes: &remainingNodes)
            }
        }
    }

    private func canonicalKey(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func isInputTokenKey(_ key: String) -> Bool {
        ["inputtokens", "prompttokens", "inputtokencount", "prompttokencount", "tokensin"].contains(key)
    }

    private func isOutputTokenKey(_ key: String) -> Bool {
        ["outputtokens", "completiontokens", "outputtokencount", "completiontokencount", "tokensout"].contains(key)
    }

    private func isTotalTokenKey(_ key: String) -> Bool {
        ["totaltokens", "totaltokencount", "tokenstotal"].contains(key)
    }

    private func isUsageContainerKey(_ key: String) -> Bool {
        ["usage", "tokenusage", "tokencounts", "tokens", "response", "result", "data", "turn"].contains(key)
    }

    /// Boolean, 분수, Int 범위 밖의 토큰 수를 거부
    private func tokenCount(_ value: Any) -> Int? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let decimal = number.decimalValue
            guard !decimal.isNaN,
                  decimal >= 0,
                  decimal <= Decimal(Int.max) else { return nil }
            var rounded = Decimal()
            var source = decimal
            NSDecimalRound(&rounded, &source, 0, .plain)
            guard rounded == decimal else { return nil }
            return Int(NSDecimalNumber(decimal: rounded).stringValue)
        }
        if let text = value as? String,
           let parsed = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           parsed >= 0 {
            return parsed
        }
        return nil
    }
}

/// Converts bounded diagnostic text to a small categorical hint. Matching is
/// intentionally conservative and never returns the original text.
private enum UsageWindowProbeDiagnostic {
    static func hint(from data: Data) -> UsageWindowProbeFailureCategory? {
        guard !data.isEmpty else { return nil }
        return hint(from: String(decoding: data, as: UTF8.self))
    }

    static func hint(from text: String) -> UsageWindowProbeFailureCategory? {
        let normalized = text.lowercased()
        let compact = normalized.filter { $0.isLetter || $0.isNumber }

        if normalized.contains("too many requests") ||
            normalized.contains("rate limit") ||
            compact.contains("ratelimit") ||
            normalized.contains("throttl") ||
            normalized.contains("429") {
            return .rateLimited
        }

        let modelMentioned = normalized.contains("model") || compact.contains("unsupportedmodel")
        if modelMentioned && (
            normalized.contains("unsupported") ||
            normalized.contains("not found") ||
            normalized.contains("unknown model") ||
            normalized.contains("invalid model") ||
            normalized.contains("not available") ||
            compact.contains("modeldoesnotexist")
        ) {
            return .unsupportedModel
        }

        if normalized.contains("unauthorized") ||
            normalized.contains("authentication") ||
            normalized.contains("not logged in") ||
            normalized.contains("login required") ||
            normalized.contains("invalid api key") ||
            normalized.contains("api key") && normalized.contains("invalid") ||
            normalized.contains("token expired") {
            return .authenticationFailure
        }
        return nil
    }
}

/// Per-request filesystem roots that expose only the selected account's
/// authentication file to Codex. The source account home is never read or
/// enumerated; its `auth.json` is referenced through a symbolic link.
internal struct UsageWindowProbeExecutionIsolation: Sendable {
    internal let rootURL: URL
    internal let codexHomeURL: URL
    internal let workingDirectoryURL: URL
    internal let modelInstructionsURL: URL

    internal var isolatedCodexHomeURL: URL { codexHomeURL }
    internal var isolatedWorkingDirectoryURL: URL { workingDirectoryURL }

    private init(
        rootURL: URL,
        codexHomeURL: URL,
        workingDirectoryURL: URL,
        modelInstructionsURL: URL
    ) {
        self.rootURL = rootURL
        self.codexHomeURL = codexHomeURL
        self.workingDirectoryURL = workingDirectoryURL
        self.modelInstructionsURL = modelInstructionsURL
    }

    internal static func create(
        configuredAccountHome: URL,
        fileManager: FileManager = .default
    ) throws -> UsageWindowProbeExecutionIsolation {
        let rootURL = fileManager.temporaryDirectory
            .standardizedFileURL
            .appendingPathComponent("codex-quota-probe-\(UUID().uuidString)", isDirectory: true)
        let codexHomeURL = rootURL.appendingPathComponent("codex-home", isDirectory: true)
        let workingDirectoryURL = rootURL.appendingPathComponent("working-directory", isDirectory: true)
        let modelInstructionsURL = rootURL.appendingPathComponent("ping-instructions")
        let privateDirectoryAttributes: [FileAttributeKey: Any] = [
            .posixPermissions: NSNumber(value: Int16(0o700)),
        ]

        do {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: false,
                attributes: privateDirectoryAttributes
            )
            try fileManager.createDirectory(
                at: codexHomeURL,
                withIntermediateDirectories: false,
                attributes: privateDirectoryAttributes
            )
            try fileManager.createDirectory(
                at: workingDirectoryURL,
                withIntermediateDirectories: false,
                attributes: privateDirectoryAttributes
            )

            try Data(UsageWindowProbeCommandBuilder.minimalInstructions.utf8).write(
                to: modelInstructionsURL,
                options: .atomic
            )
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: modelInstructionsURL.path
            )

            let sourceAuthURL = configuredAccountHome.appendingPathComponent("auth.json")
            let isolatedAuthURL = codexHomeURL.appendingPathComponent("auth.json")
            try fileManager.createSymbolicLink(
                at: isolatedAuthURL,
                withDestinationURL: sourceAuthURL
            )
        } catch {
            try? fileManager.removeItem(at: rootURL)
            throw error
        }

        return UsageWindowProbeExecutionIsolation(
            rootURL: rootURL,
            codexHomeURL: codexHomeURL,
            workingDirectoryURL: workingDirectoryURL,
            modelInstructionsURL: modelInstructionsURL
        )
    }

    internal func cleanup(fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        do {
            try fileManager.removeItem(at: rootURL)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // A concurrent cleanup may have removed the root already.
        }
    }
}

/// Live asynchronous Process-backed runner. It runs on a utility queue,
/// captures each stream under a strict byte cap, and terminates a child within
/// bounded graceful and forced windows after timeout.
public final class UsageWindowProbeLiveProcessRunner: UsageWindowProbeProcessRunning, @unchecked Sendable {
    public static let defaultGracefulTerminationTimeout: TimeInterval = 0.25
    public static let defaultForcedTerminationTimeout: TimeInterval = 0.25

    private let inheritedEnvironment: [String: String]
    private let gracefulTerminationTimeout: TimeInterval
    private let forcedTerminationTimeout: TimeInterval

    public init(
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        gracefulTerminationTimeout: TimeInterval = UsageWindowProbeLiveProcessRunner.defaultGracefulTerminationTimeout,
        forcedTerminationTimeout: TimeInterval = UsageWindowProbeLiveProcessRunner.defaultForcedTerminationTimeout
    ) {
        self.inheritedEnvironment = inheritedEnvironment
        self.gracefulTerminationTimeout = max(0, gracefulTerminationTimeout)
        self.forcedTerminationTimeout = max(0, forcedTerminationTimeout)
    }

    /// 취소 wakeup과 제한 종료를 포함해 격리 프로세스 실행
    public func run(
        command: UsageWindowProbeCommand,
        timeout: TimeInterval
    ) async throws -> UsageWindowProbeProcessResult {
        let wakeSignal = DispatchSemaphore(value: 0)
        let exitSignal = DispatchSemaphore(value: 0)
        let cancellation = ProcessCancellation(wakeSignal: wakeSignal)
        let operationID = DiagnosticLogContext.operationID
        let logger = DiagnosticLogContext.logger ?? .shared
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<UsageWindowProbeProcessResult, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let result = try DiagnosticLogContext.$logger.withValue(logger) {
                            try DiagnosticLogContext.$operationID.withValue(operationID) {
                                try self.runSynchronously(
                                    command: command, timeout: timeout, cancellation: cancellation,
                                    wakeSignal: wakeSignal, exitSignal: exitSignal
                                )
                            }
                        }
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: {
            cancellation.cancel()
        })
    }

    /// 설치 CLI의 번들 카탈로그를 제한 시간·출력 상한·취소 조건으로 조회
    private func prepareCatalog(command: UsageWindowProbeCommand,
                                isolation: UsageWindowProbeExecutionIsolation,
                                cancellation: ProcessCancellation,
                                timeout: TimeInterval) throws -> URL {
        let started = ProcessInfo.processInfo.systemUptime
        var succeeded = false
        DiagnosticLogContext.record(.catalogStarted)
        defer {
            DiagnosticLogContext.record(.catalogFinished, level: succeeded ? .notice : .error,
                                        fields: [.applied: .boolean(succeeded),
                                                 .durationMS: DiagnosticLogContext.elapsedMS(since: started)])
        }
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let collector = BoundedDataCollector(limit: 4 * 1_024 * 1_024)
        let errorCollector = BoundedDataCollector(limit: 16 * 1_024)
        let ended = DispatchSemaphore(value: 0)
        process.executableURL = command.executableURL
        process.arguments = ["debug", "models", "--bundled"]
        var environment = inheritedEnvironment
        for (key, value) in command.environmentOverrides { environment[key] = value }
        environment["PATH"] = CodexProcess.childPath(inheritedPath: environment["PATH"], executable: command.executableURL)
        environment["CODEX_HOME"] = isolation.codexHomeURL.path
        environment["PWD"] = isolation.workingDirectoryURL.path
        process.environment = environment
        process.currentDirectoryURL = isolation.workingDirectoryURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { handle in collector.append(handle.availableData) }
        errors.fileHandleForReading.readabilityHandler = { handle in errorCollector.append(handle.availableData) }
        process.terminationHandler = { _ in ended.signal() }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            close(pipe: output)
            close(pipe: errors)
        }
        guard !cancellation.isCancelled else { throw UsageWindowProbeProcessError.cancelled }
        do { try process.run() }
        catch { throw UsageWindowProbeProcessError.configurationFailure }
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + min(10, timeout)
        while ended.wait(timeout: .now() + 0.05) == .timedOut {
            if cancellation.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline || collector.exceededLimit {
                terminate(process, exitSignal: ended)
                if cancellation.isCancelled { throw UsageWindowProbeProcessError.cancelled }
                if collector.exceededLimit { throw UsageWindowProbeProcessError.configurationFailure }
                throw UsageWindowProbeProcessError.timeout
            }
        }
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        drain(output.fileHandleForReading, into: collector)
        drain(errors.fileHandleForReading, into: errorCollector)
        guard !cancellation.isCancelled else { throw UsageWindowProbeProcessError.cancelled }
        guard process.terminationStatus == 0, !collector.exceededLimit,
              var catalog = try? JSONSerialization.jsonObject(with: collector.value) as? [String: Any],
              let models = catalog["models"] as? [[String: Any]],
              var model = models.first(where: { $0["slug"] as? String == command.modelIdentifier }),
              model["tool_mode"] != nil, model["apply_patch_tool_type"] != nil,
              model["use_responses_lite"] != nil
        else { throw UsageWindowProbeProcessError.configurationFailure }
        model["tool_mode"] = "direct"
        model["apply_patch_tool_type"] = NSNull()
        model["use_responses_lite"] = false
        catalog["models"] = [model]
        let url = isolation.rootURL.appendingPathComponent("catalog.json")
        do {
            try JSONSerialization.data(withJSONObject: catalog).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw UsageWindowProbeProcessError.configurationFailure }
        succeeded = true
        return url
    }

    private func runSynchronously(
        command: UsageWindowProbeCommand,
        timeout: TimeInterval,
        cancellation: ProcessCancellation,
        wakeSignal: DispatchSemaphore,
        exitSignal: DispatchSemaphore
    ) throws -> UsageWindowProbeProcessResult {
        let processStarted = ProcessInfo.processInfo.systemUptime
        var processFields: [DiagnosticField: DiagnosticValue] = [:]
        var processSucceeded = false
        DiagnosticLogContext.record(.processStarted, fields: [.model: .identifier(command.modelIdentifier)])
        defer {
            processFields[.durationMS] = DiagnosticLogContext.elapsedMS(since: processStarted)
            DiagnosticLogContext.record(.processFinished, level: processSucceeded ? .notice : .error,
                                        fields: processFields)
        }
        let isolation: UsageWindowProbeExecutionIsolation
        do {
            isolation = try UsageWindowProbeExecutionIsolation.create(
                configuredAccountHome: command.configuredAccountHome,
                fileManager: .default
            )
        } catch {
            throw UsageWindowProbeProcessError.launchFailure
        }
        defer {
            try? isolation.cleanup(fileManager: .default)
        }

        let started = ProcessInfo.processInfo.systemUptime
        let catalogURL = try prepareCatalog(command: command, isolation: isolation, cancellation: cancellation, timeout: timeout)
        let remainingTimeout = timeout - (ProcessInfo.processInfo.systemUptime - started)
        guard remainingTimeout > 0 else { throw UsageWindowProbeProcessError.timeout }
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputCollector = BoundedDataCollector(limit: UsageWindowProbeProcessResult.maximumStandardOutputBytes)
        let errorCollector = BoundedDataCollector(limit: UsageWindowProbeProcessResult.maximumStandardErrorBytes)
        process.executableURL = command.executableURL
        let modelInstructionsPath = isolation.modelInstructionsURL.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var processArguments = command.arguments
        let prompt = processArguments.removeLast()
        processArguments.append(contentsOf: [
            "-c",
            "model_instructions_file=\"\(modelInstructionsPath)\"",
        ])
        let catalogPath = catalogURL.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        processArguments.append(contentsOf: ["-c", "model_catalog_json=\"\(catalogPath)\""])
        processArguments.append(prompt)
        process.arguments = processArguments
        var environment = inheritedEnvironment
        for (key, value) in command.environmentOverrides {
            environment[key] = value
        }
        environment["PATH"] = CodexProcess.childPath(
            inheritedPath: environment["PATH"],
            executable: command.executableURL
        )
        environment["CODEX_HOME"] = isolation.codexHomeURL.path
        environment["PWD"] = isolation.workingDirectoryURL.path
        process.environment = environment
        process.currentDirectoryURL = isolation.workingDirectoryURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = {
            _ in
            exitSignal.signal()
            wakeSignal.signal()
        }

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                outputCollector.append(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                errorCollector.append(data)
            }
        }

        guard !cancellation.isCancelled else {
            close(pipe: inputPipe)
            close(pipe: outputPipe)
            close(pipe: errorPipe)
            throw UsageWindowProbeProcessError.cancelled
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            close(pipe: inputPipe)
            close(pipe: outputPipe)
            close(pipe: errorPipe)
            if cancellation.isCancelled {
                throw UsageWindowProbeProcessError.cancelled
            }
            throw UsageWindowProbeProcessError.launchFailure
        }
        // The parent must release its copies of the pipe write ends. Keeping
        // them open would make the post-exit drain wait forever for EOF.
        closeParentWritingHandles(inputPipe: inputPipe, outputPipe: outputPipe, errorPipe: errorPipe)

        let boundedTimeout = max(0.001, remainingTimeout)
        var didTimeout = false
        let waitResult = wakeSignal.wait(timeout: .now() + boundedTimeout)
        if cancellation.isCancelled {
            terminateForCancellation(process, exitSignal: exitSignal)
        } else if waitResult == .timedOut {
            didTimeout = true
            terminate(process, exitSignal: exitSignal)
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        drain(outputPipe.fileHandleForReading, into: outputCollector)
        drain(errorPipe.fileHandleForReading, into: errorCollector)

        let status: Int32? = process.isRunning ? nil : process.terminationStatus
        if let status { processFields[.exitCode] = .integer(Int(status)) }
        if cancellation.isCancelled { processFields[.reason] = .identifier("cancelled") }
        if didTimeout { processFields[.reason] = .identifier("timeout") }
        process.terminationHandler = nil
        close(pipe: inputPipe)
        close(pipe: outputPipe)
        close(pipe: errorPipe)

        if cancellation.isCancelled {
            throw UsageWindowProbeProcessError.cancelled
        }
        if didTimeout {
            throw UsageWindowProbeProcessError.timeout
        }
        guard status != nil else {
            throw UsageWindowProbeProcessError.processFailure
        }
        processSucceeded = status == 0
        return UsageWindowProbeProcessResult(
            exitStatus: status,
            stdout: outputCollector.value,
            stderr: errorCollector.value
        )
    }

    private func terminate(_ process: Process, exitSignal: DispatchSemaphore) {
        guard process.isRunning else { return }
        process.terminate()
        if exitSignal.wait(timeout: .now() + gracefulTerminationTimeout) == .timedOut,
           process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            _ = exitSignal.wait(timeout: .now() + forcedTerminationTimeout)
        }
    }

    /// 취소 wakeup 이후 유예 종료와 강제 종료를 순서대로 수행
    private func terminateForCancellation(_ process: Process, exitSignal: DispatchSemaphore) {
        terminate(process, exitSignal: exitSignal)
    }

    private func drain(_ handle: FileHandle, into collector: BoundedDataCollector) {
        while true {
            let chunk = handle.readData(ofLength: 8 * 1_024)
            guard !chunk.isEmpty else { return }
            collector.append(chunk)
        }
    }

    private func close(pipe: Pipe) {
        try? pipe.fileHandleForWriting.close()
        try? pipe.fileHandleForReading.close()
    }

    private func closeParentWritingHandles(inputPipe: Pipe, outputPipe: Pipe, errorPipe: Pipe) {
        try? inputPipe.fileHandleForWriting.close()
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
    }
}

public typealias LiveUsageWindowProbeProcessRunner = UsageWindowProbeLiveProcessRunner

private final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let wakeSignal: DispatchSemaphore
    private var cancelled = false

    init(wakeSignal: DispatchSemaphore) {
        self.wakeSignal = wakeSignal
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// 취소 상태를 한 번 기록하고 child 종료 대기를 깨움
    func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        lock.unlock()
        wakeSignal.signal()
    }
}

private final class BoundedDataCollector: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private var overflow = false

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = limit - data.count
        if chunk.count > remaining { overflow = true }
        guard remaining > 0 else { return }
        data.append(chunk.prefix(remaining))
    }

    var exceededLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overflow
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Actor-isolated service for one bounded, injectable usage-window request.
/// Calls for the same account are rejected while one is active; different
/// accounts can run independently because each call owns its runner request.
public actor UsageWindowProbeService {
    public static let defaultTimeout: TimeInterval = 60
    public static let overallTimeout: TimeInterval = defaultTimeout

    private let fileSystem: UsageWindowProbeFileSystem
    private let executableLocator: any CodexLocating
    private let processRunner: any UsageWindowProbeProcessRunning
    private let commandBuilder: UsageWindowProbeCommandBuilder
    private let timeout: TimeInterval
    private let clock: @Sendable () -> Date
    private var activeAccountIDs = Set<String>()
    private var states: [String: UsageWindowProbeState] = [:]

    public init(
        fileSystem: UsageWindowProbeFileSystem = .live,
        executableLocator: any CodexLocating = CodexLocator(),
        processRunner: any UsageWindowProbeProcessRunning = UsageWindowProbeLiveProcessRunner(),
        commandBuilder: UsageWindowProbeCommandBuilder = UsageWindowProbeCommandBuilder(),
        timeout: TimeInterval = UsageWindowProbeService.defaultTimeout,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileSystem = fileSystem
        self.executableLocator = executableLocator
        self.processRunner = processRunner
        self.commandBuilder = commandBuilder
        self.timeout = max(0.001, timeout)
        self.clock = clock
    }

    /// 설정 계정의 Ping 실행과 단계별 진단 기록; 한도 재조회·초기화 시각 해석은 호출자 책임
    public func probe(_ config: AccountConfig) async -> UsageWindowProbeResult {
        let startedAt = clock()
        let startedUptime = ProcessInfo.processInfo.systemUptime
        let commandMetadata = commandBuilder.metadata
        guard config.provider == .codex else {
            return UsageWindowProbeResult(accountID: config.id, status: .failure,
                                          startedAt: startedAt, completedAt: clock(),
                                          failureCategory: .notConfigured, commandMetadata: commandMetadata)
        }
        if activeAccountIDs.contains(config.id) {
            DiagnosticLogContext.record(.probeRejected, accountID: config.id,
                                        fields: [.reason: .identifier("already_running")])
            let completedAt = clock()
            return UsageWindowProbeResult(
                accountID: config.id,
                status: .failure,
                startedAt: startedAt,
                completedAt: completedAt,
                failureCategory: .alreadyRunning,
                commandMetadata: commandMetadata
            )
        }

        activeAccountIDs.insert(config.id)
        DiagnosticLogContext.record(.probeStarted, accountID: config.id,
                                    fields: [.model: .identifier(commandMetadata.modelIdentifier)])
        states[config.id] = UsageWindowProbeState(
            accountID: config.id,
            status: .running,
            startedAt: startedAt,
            commandMetadata: commandMetadata
        )

        let result = await execute(config: config, startedAt: startedAt)
        var fields: [DiagnosticField: DiagnosticValue] = [
            .status: .identifier(result.status.rawValue),
            .durationMS: DiagnosticLogContext.elapsedMS(since: startedUptime),
        ]
        if let failure = result.failureCategory { fields[.failure] = .identifier(failure.rawValue) }
        if let count = result.inputTokens { fields[.inputTokens] = .integer(count) }
        if let count = result.outputTokens { fields[.outputTokens] = .integer(count) }
        DiagnosticLogContext.record(.probeFinished, level: result.isSuccess || result.isCancelled ? .notice : .error,
                                    accountID: config.id, fields: fields)
        activeAccountIDs.remove(config.id)
        states[config.id] = UsageWindowProbeState(
            accountID: config.id,
            status: result.isCancelled ? .cancelled : (result.isSuccess ? .success : .failure),
            startedAt: result.startedAt,
            completedAt: result.completedAt,
            result: result,
            commandMetadata: result.commandMetadata
        )
        return result
    }

    public func state(for accountID: String) -> UsageWindowProbeState {
        states[accountID] ?? .idle(accountID: accountID)
    }

    /// 사전 점검부터 runner 완료까지 취소 상태를 유지
    private func execute(
        config: AccountConfig,
        startedAt: Date
    ) async -> UsageWindowProbeResult {
        let metadata = commandBuilder.metadata
        if Task.isCancelled {
            return cancelled(accountID: config.id, startedAt: startedAt, metadata: metadata)
        }
        guard let configuredHome = config.configuredHome else {
            return failure(
                accountID: config.id,
                startedAt: startedAt,
                category: .notConfigured,
                metadata: metadata
            )
        }

        let authMetadata = fileSystem.metadata(config.authFile)
        if Task.isCancelled {
            return cancelled(accountID: config.id, startedAt: startedAt, metadata: metadata)
        }
        guard authMetadata.isUsableAuthenticationFile else {
            return failure(
                accountID: config.id,
                startedAt: startedAt,
                category: .missingAuthentication,
                metadata: metadata
            )
        }

        guard let executable = executableLocator.locate() else {
            return failure(
                accountID: config.id,
                startedAt: startedAt,
                category: .executableUnavailable,
                metadata: metadata
            )
        }
        if Task.isCancelled {
            return cancelled(accountID: config.id, startedAt: startedAt, metadata: metadata)
        }

        let command = commandBuilder.build(
            executable: executable,
            configuredAccountHome: configuredHome
        )

        do {
            let processResult = try await processRunner.run(command: command, timeout: timeout)
            if Task.isCancelled {
                return cancelled(accountID: config.id, startedAt: startedAt, metadata: command.metadata)
            }
            var parser = UsageWindowProbeJSONLParser()
            parser.append(processResult.stdout)
            let parsed = parser.finish()
            let boundedStreamHint = parsed.failureCategoryHint ??
                UsageWindowProbeDiagnostic.hint(from: processResult.stderr)

            guard processResult.exitStatus == 0 else {
                return failure(
                    accountID: config.id,
                    startedAt: startedAt,
                    category: boundedStreamHint ?? .nonZeroExit,
                    metadata: command.metadata
                )
            }

            if parsed.sawError {
                return failure(
                    accountID: config.id,
                    startedAt: startedAt,
                    category: boundedStreamHint ?? .commandFailure,
                    metadata: command.metadata
                )
            }
            if parsed.isMalformedOnlyOutput {
                return failure(
                    accountID: config.id,
                    startedAt: startedAt,
                    category: .malformedOutput,
                    metadata: command.metadata
                )
            }
            guard parsed.sawCompletion else {
                return failure(
                    accountID: config.id,
                    startedAt: startedAt,
                    category: .malformedOutput,
                    metadata: command.metadata
                )
            }

            return UsageWindowProbeResult(
                accountID: config.id,
                status: .success,
                startedAt: startedAt,
                completedAt: clock(),
                usage: parsed.usage,
                commandMetadata: command.metadata
            )
        } catch let error as UsageWindowProbeProcessError {
            if Task.isCancelled {
                return cancelled(accountID: config.id, startedAt: startedAt, metadata: command.metadata)
            }
            let category: UsageWindowProbeFailureCategory
            switch error {
            case .cancelled:
                return cancelled(accountID: config.id, startedAt: startedAt, metadata: command.metadata)
            case .timeout:
                category = .timeout
            case .configurationFailure:
                category = .configurationFailure
            case .launchFailure:
                category = .launchFailure
            case .processFailure:
                category = .processFailure
            }
            return failure(
                accountID: config.id,
                startedAt: startedAt,
                category: category,
                metadata: command.metadata
            )
        } catch {
            if Task.isCancelled {
                return cancelled(accountID: config.id, startedAt: startedAt, metadata: command.metadata)
            }
            return failure(
                accountID: config.id,
                startedAt: startedAt,
                category: .processFailure,
                metadata: command.metadata
            )
        }
    }

    /// 취소 결과를 failure 상태와 분리해 보존
    private func cancelled(
        accountID: String,
        startedAt: Date,
        metadata: UsageWindowProbeCommandMetadata
    ) -> UsageWindowProbeResult {
        UsageWindowProbeResult(
            accountID: accountID,
            status: .cancelled,
            startedAt: startedAt,
            completedAt: clock(),
            commandMetadata: metadata
        )
    }

    private func failure(
        accountID: String,
        startedAt: Date,
        category: UsageWindowProbeFailureCategory,
        metadata: UsageWindowProbeCommandMetadata
    ) -> UsageWindowProbeResult {
        UsageWindowProbeResult(
            accountID: accountID,
            status: .failure,
            startedAt: startedAt,
            completedAt: clock(),
            failureCategory: category,
            commandMetadata: metadata
        )
    }
}
