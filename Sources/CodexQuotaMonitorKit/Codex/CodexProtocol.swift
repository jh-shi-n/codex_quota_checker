import CoreFoundation
import Foundation

/// A small Sendable JSON representation used by the app-server wire protocol.
public enum CodexJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CodexJSONValue])
    case object([String: CodexJSONValue])

    public var objectValue: [String: CodexJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    public var arrayValue: [CodexJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    public var numberValue: Double? {
        guard case let .number(value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CodexJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: CodexJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    fileprivate init(foundationValue value: Any) throws {
        switch value {
        case is NSNull:
            self = .null
        case let value as NSNumber:
            let type = String(cString: value.objCType)
            if type == "c" || type == "B" {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(try value.map(CodexJSONValue.init(foundationValue:)))
        case let value as [String: Any]:
            self = .object(try value.mapValues(CodexJSONValue.init(foundationValue:)))
        default:
            throw CodexProtocolParsingError.unsupportedValue
        }
    }

    fileprivate var foundationValue: Any {
        switch self {
        case .null:
            return NSNull()
        case let .bool(value):
            return value
        case let .number(value):
            return value
        case let .string(value):
            return value
        case let .array(value):
            return value.map(\.foundationValue)
        case let .object(value):
            return value.mapValues(\.foundationValue)
        }
    }
}

public struct CodexRequest: Equatable, Sendable {
    public let id: Int?
    public let method: String
    public let params: CodexJSONValue?

    public init(id: Int? = nil, method: String, params: CodexJSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    public func encodedLine() throws -> Data {
        var object: [String: Any] = ["method": method]
        if let id {
            object["id"] = id
        }
        if let params {
            object["params"] = params.foundationValue
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0A)
        return data
    }
}

public struct CodexProtocolError: Equatable, Sendable {
    public let code: Int?
    public let message: String?
    public let data: CodexJSONValue?

    public init(code: Int? = nil, message: String? = nil, data: CodexJSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// One decoded JSON-line message. Notifications have no id and are ignored by response waiters.
public struct CodexMessage: Equatable, Sendable {
    public let id: Int?
    public let method: String?
    public let params: CodexJSONValue?
    public let result: CodexJSONValue?
    public let error: CodexProtocolError?
    public let hasResult: Bool
    public let containsError: Bool

    public init(
        id: Int? = nil,
        method: String? = nil,
        params: CodexJSONValue? = nil,
        result: CodexJSONValue? = nil,
        error: CodexProtocolError? = nil
    ) {
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
        self.hasResult = result != nil
        self.containsError = error != nil
    }

    public init?(line: Data) {
        var line = line
        while line.last == 0x0A || line.last == 0x0D || line.last == 0x20 || line.last == 0x09 {
            line.removeLast()
        }
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line, options: []),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        let id: Int?
        if let rawID = dictionary["id"] {
            guard let parsedID = integerResponseID(from: rawID) else { return nil }
            id = parsedID
        } else {
            id = nil
        }

        let method = dictionary["method"] as? String
        let params: CodexJSONValue?
        if let rawParams = dictionary["params"] {
            guard let decoded = try? CodexJSONValue(foundationValue: rawParams) else { return nil }
            params = decoded
        } else {
            params = nil
        }

        let result: CodexJSONValue?
        if let rawResult = dictionary["result"] {
            guard let decoded = try? CodexJSONValue(foundationValue: rawResult) else { return nil }
            result = decoded
        } else {
            result = nil
        }

        let containsError = dictionary.keys.contains("error")
        let error: CodexProtocolError?
        if let rawError = dictionary["error"] as? [String: Any] {
            let code = (rawError["code"] as? NSNumber)?.intValue
            let message = rawError["message"] as? String
            let data = rawError["data"].flatMap { try? CodexJSONValue(foundationValue: $0) }
            error = CodexProtocolError(code: code, message: message, data: data)
        } else {
            error = nil
        }

        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
        self.hasResult = dictionary.keys.contains("result")
        self.containsError = containsError
    }
}

/// 응답 ID의 정수성, 형식, Int 범위를 손실 없이 검사
private func integerResponseID(from value: Any) -> Int? {
    if let text = value as? String {
        return Int(text)
    }
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let decimal = number.decimalValue
    guard !decimal.isNaN,
          decimal >= Decimal(Int.min),
          decimal <= Decimal(Int.max) else { return nil }
    var rounded = Decimal()
    var source = decimal
    NSDecimalRound(&rounded, &source, 0, .plain)
    guard rounded == decimal else { return nil }
    return Int(NSDecimalNumber(decimal: rounded).stringValue)
}

public enum CodexLineDecoderError: Error, Equatable, Sendable {
    case lineTooLarge(maximumBytes: Int)
    case bufferTooLarge(maximumBytes: Int)
}

extension CodexLineDecoderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .lineTooLarge(maximumBytes):
            return "Codex protocol error: JSON line exceeds \(maximumBytes)-byte limit"
        case let .bufferTooLarge(maximumBytes):
            return "Codex protocol error: receive buffer exceeds \(maximumBytes)-byte limit"
        }
    }
}

public struct CodexLineDecoder: Sendable {
    /// Maximum JSON payload size for one line, excluding its newline delimiter.
    public static let maximumLineBytes = 1_048_576

    /// Maximum size retained while waiting for a newline-delimited message.
    public static let maximumBufferBytes = 4_194_304

    private var buffer = Data()

    public init() {}

    /// Appends arbitrary stdout chunks and returns every complete valid message in them.
    public mutating func append(_ data: Data) throws -> [CodexMessage] {
        var messages: [CodexMessage] = []
        var start = data.startIndex

        while start < data.endIndex {
            guard let newline = data[start..<data.endIndex].firstIndex(of: 0x0A) else {
                let fragment = data[start..<data.endIndex]
                guard !exceedsLimit(fragment.count, limit: Self.maximumBufferBytes) else {
                    clearBuffer()
                    throw CodexLineDecoderError.bufferTooLarge(maximumBytes: Self.maximumBufferBytes)
                }
                buffer.append(contentsOf: fragment)
                return messages
            }

            let line = data[start..<newline]
            guard !exceedsLimit(line.count, limit: Self.maximumLineBytes) else {
                clearBuffer()
                throw CodexLineDecoderError.lineTooLarge(maximumBytes: Self.maximumLineBytes)
            }

            buffer.append(contentsOf: line)
            if let message = CodexMessage(line: buffer) {
                messages.append(message)
            }
            clearBuffer()
            start = data.index(after: newline)
        }

        return messages
    }

    /// Parses a final non-newline-terminated line when the process closes.
    public mutating func finish() throws -> [CodexMessage] {
        guard !buffer.isEmpty else { return [] }
        guard buffer.count <= Self.maximumLineBytes else {
            clearBuffer()
            throw CodexLineDecoderError.lineTooLarge(maximumBytes: Self.maximumLineBytes)
        }

        let line = buffer
        clearBuffer()
        guard let message = CodexMessage(line: line) else { return [] }
        return [message]
    }

    mutating func reset() {
        clearBuffer()
    }

    private func exceedsLimit(_ additionalBytes: Int, limit: Int) -> Bool {
        buffer.count > limit || additionalBytes > limit - buffer.count
    }

    private mutating func clearBuffer() {
        buffer.removeAll(keepingCapacity: false)
    }
}

public enum CodexProtocol {
    public static let initializeRequest = CodexRequest(
        id: 0,
        method: "initialize",
        params: .object([
            "clientInfo": .object([
                "name": .string("codex_quota_notch_monitor"),
                "title": .string("LLM Quota Checker"),
                "version": .string("1.0"),
            ])
        ])
    )

    public static let postInitializeRequests: [CodexRequest] = [
        CodexRequest(method: "initialized", params: .object([:])),
        CodexRequest(
            id: 1,
            method: "account/read",
            params: .object(["refreshToken": .bool(false)])
        ),
        CodexRequest(id: 2, method: "account/rateLimits/read", params: .null),
    ]
}

fileprivate enum CodexProtocolParsingError: Error {
    case unsupportedValue
}
