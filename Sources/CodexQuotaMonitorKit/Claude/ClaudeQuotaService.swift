import Foundation
import Security

/// Reads only the usage endpoint. No model requests, token refreshes, or credential copies.
public actor ClaudeQuotaService {
    public static let shared = ClaudeQuotaService()
    public typealias CredentialLoader = @Sendable (URL) throws -> ClaudeUsageCredential
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let credentialLoader: CredentialLoader
    private let transport: Transport
    private let now: @Sendable () -> Date
    private var cached: [String: (state: AccountState, retryAt: Date)] = [:]
    private var inFlight: [String: Task<AccountState, Never>] = [:]

    public init(
        credentialLoader: @escaping CredentialLoader = ClaudeUsageCredential.load,
        transport: @escaping Transport = ClaudeQuotaService.send,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentialLoader = credentialLoader
        self.transport = transport
        self.now = now
    }

    public func state(for config: AccountConfig) async -> AccountState {
        guard config.isConfigured, config.provider == .claude else {
            return AccountState(id: config.id, status: .notConfigured, provider: .claude)
        }
        let key = config.home.path
        if let entry = cached[key], entry.retryAt > now() {
            return Self.forAccount(entry.state, id: config.id)
        }
        if let task = inFlight[key] { return Self.forAccount(await task.value, id: config.id) }
        let credentialLoader = self.credentialLoader
        let transport = self.transport
        let now = self.now
        let task = Task { await Self.fetch(config, credentialLoader: credentialLoader, transport: transport, now: now) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        // Bound manual/automatic refreshes; a throttled endpoint is never retried in a loop.
        cached[key] = (result, now().addingTimeInterval(result.status == .normal ? 60 : 300))
        return result
    }

    private static func forAccount(_ state: AccountState, id: String) -> AccountState {
        AccountState(id: id, email: state.email, planType: state.planType,
                     primaryUsedPercent: state.primaryUsedPercent, secondaryUsedPercent: state.secondaryUsedPercent,
                     primaryResetAt: state.primaryResetAt, secondaryResetAt: state.secondaryResetAt,
                     lastUpdated: state.lastUpdated, status: state.status, errorMessage: state.errorMessage, provider: .claude)
    }

    private static func fetch(
        _ config: AccountConfig, credentialLoader: CredentialLoader,
        transport: Transport, now: @Sendable () -> Date
    ) async -> AccountState {
        do {
            let credential = try credentialLoader(config.home)
            guard credential.expiresAt.map({ $0 > now() }) ?? true else { throw ClaudeUsageError.loginRequired }
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.httpMethod = "GET"
            request.timeoutInterval = 20
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("CodexQuotaChecker/0.0.9", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await transport(request)
            switch response.statusCode {
            case 200: break
            case 401, 403: throw ClaudeUsageError.loginRequired
            case 429: throw ClaudeUsageError.rateLimited
            default: throw ClaudeUsageError.unavailable
            }
            guard data.count <= 256 * 1_024 else { throw ClaudeUsageError.malformedResponse }
            let usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
            let values = try usage.validatedValues()
            return AccountState(id: config.id, email: credential.email, planType: credential.subscriptionType,
                                primaryUsedPercent: values.fiveHour, secondaryUsedPercent: values.sevenDay,
                                primaryResetAt: values.fiveHourReset, secondaryResetAt: values.sevenDayReset,
                                lastUpdated: now(), status: .normal, provider: .claude)
        } catch {
            let failure = error as? ClaudeUsageError
            return AccountState(id: config.id,
                                status: failure == .loginRequired ? .loginRequired : .error,
                                errorMessage: failure?.message ?? "Claude 사용량을 조회하지 못했습니다. 잠시 후 다시 확인해 주세요.",
                                provider: .claude)
        }
    }

    public static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request, delegate: ClaudeNoRedirectDelegate())
        guard let response = response as? HTTPURLResponse else { throw ClaudeUsageError.unavailable }
        return (data, response)
    }
}

private final class ClaudeNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct ClaudeUsageCredential: Sendable {
    public let accessToken: String
    public let expiresAt: Date?
    public let email: String?
    public let subscriptionType: String?

    public init(accessToken: String, expiresAt: Date? = nil, email: String? = nil, subscriptionType: String? = nil) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.email = email
        self.subscriptionType = subscriptionType
    }

    public static func load(home: URL) throws -> Self {
        let defaultHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").standardizedFileURL
        var data: Data?
        if home.standardizedFileURL == defaultHome {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "Claude Code-credentials",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess { data = item as? Data }
            else if status != errSecItemNotFound { throw ClaudeUsageError.keychainUnavailable }
        }
        if data == nil {
            let file = home.appendingPathComponent(".credentials.json")
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 256 * 1_024 else { throw ClaudeUsageError.loginRequired }
            data = try Data(contentsOf: file)
        }
        guard let data, data.count <= 256 * 1_024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { throw ClaudeUsageError.loginRequired }
        let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1_000) }
        var email: String?
        if home.standardizedFileURL == defaultHome {
            let profile = defaultHome.deletingLastPathComponent().appendingPathComponent(".claude.json")
            if let size = try? profile.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_024 * 1_024,
               let profileData = try? Data(contentsOf: profile),
               let root = try? JSONSerialization.jsonObject(with: profileData) as? [String: Any],
               let account = root["oauthAccount"] as? [String: Any] {
                email = account["emailAddress"] as? String
            }
        }
        return Self(accessToken: token, expiresAt: expiresAt, email: email,
                    subscriptionType: oauth["subscriptionType"] as? String)
    }
}

struct ClaudeUsageResponse: Decodable {
    struct Window: Decodable {
        let utilization: Double
        let resets_at: String?
    }
    let five_hour: Window?
    let seven_day: Window?

    func validatedValues() throws -> (fiveHour: Double?, sevenDay: Double?, fiveHourReset: Date?, sevenDayReset: Date?) {
        guard five_hour != nil || seven_day != nil else { throw ClaudeUsageError.malformedResponse }
        func parse(_ window: Window?) throws -> (Double?, Date?) {
            guard let window else { return (nil, nil) }
            guard window.utilization.isFinite, (0...100).contains(window.utilization) else { throw ClaudeUsageError.malformedResponse }
            var reset: Date?
            if let text = window.resets_at {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                reset = formatter.date(from: text)
                if reset == nil {
                    formatter.formatOptions = [.withInternetDateTime]
                    reset = formatter.date(from: text)
                }
                guard reset != nil else { throw ClaudeUsageError.malformedResponse }
            }
            return (window.utilization, reset)
        }
        let primary = try parse(five_hour)
        let secondary = try parse(seven_day)
        return (primary.0, secondary.0, primary.1, secondary.1)
    }
}

enum ClaudeUsageError: Error, Equatable {
    case loginRequired, keychainUnavailable, rateLimited, unavailable, malformedResponse

    var message: String {
        switch self {
        case .loginRequired: "Claude Code에서 구독 계정으로 로그인해 주세요."
        case .keychainUnavailable: "Claude 로그인 정보를 키체인에서 읽지 못했습니다. macOS의 접근 허용 상태를 확인해 주세요."
        case .rateLimited: "Claude 사용량 조회가 제한되었습니다. 5분 뒤 다시 확인합니다."
        case .unavailable: "Claude 사용량 서비스를 사용할 수 없습니다. 잠시 후 다시 확인해 주세요."
        case .malformedResponse: "Claude 사용량 응답 형식을 확인하지 못했습니다."
        }
    }
}
