import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

final class ClaudeQuotaServiceTests: XCTestCase, @unchecked Sendable {
    private let home = URL(fileURLWithPath: "/test/claude-account")
    private var config: AccountConfig { AccountConfig(id: "C2", home: home, position: .left, provider: .claude) }
    private let payload = Data(#"{"five_hour":{"utilization":27.5,"resets_at":"2030-01-02T03:04:05.123456+00:00"},"seven_day":{"utilization":43,"resets_at":"2030-01-06T07:08:09.654321+00:00"}}"#.utf8)

    func testReadOnlyUsageQueryMapsRemainingQuotaAndFractionalResetDates() async throws {
        let payload = self.payload
        let recorder = RequestRecorder()
        let service = ClaudeQuotaService(credentialLoader: { _ in
            ClaudeUsageCredential(accessToken: "test-secret", email: "test@example.com", subscriptionType: "max")
        }, transport: { request in
            await recorder.record(request)
            return (payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let state = await service.state(for: config)
        XCTAssertEqual(state.provider, .claude)
        XCTAssertEqual(state.status, .normal)
        XCTAssertEqual(AccountDashboardFormatting.subscriptionBadgeText(state.planType), "Max")
        XCTAssertEqual(state.primaryRemainingPercent, 72.5)
        XCTAssertEqual(state.secondaryRemainingPercent, 57)
        XCTAssertNotNil(state.primaryResetAt)
        XCTAssertNotNil(state.secondaryResetAt)
        XCTAssertNil(state.resetCredits)
        let requests = await recorder.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
    }

    func testMissingWindowRemainsUnknownAndMalformedWindowsFail() throws {
        let weeklyOnly = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(#"{"five_hour":null,"seven_day":{"utilization":43}}"#.utf8))
        let values = try weeklyOnly.validatedValues()
        XCTAssertNil(values.fiveHour)
        XCTAssertEqual(values.sevenDay, 43)
        for text in [#"{}"#, #"{"five_hour":{"utilization":-1}}"#,
                     #"{"five_hour":{"utilization":101}}"#,
                     #"{"five_hour":{"utilization":42,"resets_at":"bad-date"}}"#] {
            let decoded = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(text.utf8))
            XCTAssertThrowsError(try decoded.validatedValues())
        }
    }

    func testExpiredLoginAndCodexAccountsNeverMakeRequests() async {
        let service = ClaudeQuotaService(credentialLoader: { _ in
            ClaudeUsageCredential(accessToken: "test-secret", expiresAt: .distantPast)
        }, transport: { _ in
            XCTFail("Expired credentials must not be sent")
            throw URLError(.cancelled)
        })
        let expired = await service.state(for: config)
        XCTAssertEqual(expired.status, .loginRequired)
        let codex = await service.state(for: AccountConfig(id: "C1", home: home, position: .left))
        XCTAssertEqual(codex.status, .notConfigured)
    }

    func testThrottlingIsNotRetriedAndServerBodyIsNotDisplayed() async {
        let recorder = RequestRecorder()
        let service = ClaudeQuotaService(credentialLoader: { _ in ClaudeUsageCredential(accessToken: "test-secret") }, transport: { request in
            await recorder.record(request)
            return (Data("server-private-error-test-secret".utf8), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!)
        })
        let first = await service.state(for: config)
        let second = await service.state(for: config)
        let requests = await recorder.requests
        XCTAssertEqual(first.status, .error)
        XCTAssertEqual(second, first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(first.errorMessage?.contains("test-secret") ?? true)
        XCTAssertTrue(first.errorMessage?.contains("5분") ?? false)
    }

    func testSharedHomeCacheKeepsEachSlotIdentity() async {
        let payload = self.payload
        let recorder = RequestRecorder()
        let service = ClaudeQuotaService(credentialLoader: { _ in ClaudeUsageCredential(accessToken: "test-secret") }, transport: { request in
            await recorder.record(request)
            return (payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let first = await service.state(for: config)
        let nextConfig = AccountConfig(id: "C3", home: home, position: .right, provider: .claude)
        let second = await service.state(for: nextConfig)
        XCTAssertEqual(first.id, "C2")
        XCTAssertEqual(second.id, "C3")
        XCTAssertEqual(second.primaryUsedPercent, first.primaryUsedPercent)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testUnauthorizedResponseRequestsLoginWithoutLeakingBody() async {
        let service = ClaudeQuotaService(credentialLoader: { _ in ClaudeUsageCredential(accessToken: "test-secret") }, transport: { request in
            (Data("test-secret".utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        })
        let state = await service.state(for: config)
        XCTAssertEqual(state.status, .loginRequired)
        XCTAssertFalse(state.errorMessage?.contains("test-secret") ?? true)
    }

    @MainActor
    func testProviderSettingsPersistAndReconfigureTheSamePath() async throws {
        let suite = "ClaudeProviderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fs = AccountPathFileSystem { _ in AccountPathFileMetadata(exists: true, isDirectory: true, isReadable: true) }
        let preferences = PreferencesStore(userDefaults: defaults, fileSystem: fs)
        XCTAssertTrue(preferences.accountProviders.isEmpty)
        XCTAssertTrue(preferences.registerAccountPaths([home.path, "", "", ""]))
        let store = AccountStore(configs: AccountConfig.accounts(for: preferences.accountPaths), preferencesStore: preferences)
        let oldGeneration = store.states[0].configurationGeneration
        XCTAssertTrue(preferences.updateAccountProviders(["C1": .claude]))
        store.reconfigure(pathStrings: preferences.accountPaths)
        XCTAssertEqual(store.configs[0].provider, .claude)
        XCTAssertGreaterThan(store.states[0].configurationGeneration, oldGeneration)
        let restored = PreferencesStore(userDefaults: defaults, fileSystem: fs)
        XCTAssertEqual(restored.accountProviders, ["C1": .claude])
        XCTAssertEqual(restored.accountPaths[0], home.path)
    }

    func testLegacyCodexSnapshotStillDecodes() throws {
        let config = try JSONDecoder().decode(AccountConfig.self, from: Data(#"{"id":"C1","home":"file:///test/codex","position":"left","isConfigured":true}"#.utf8))
        let state = try JSONDecoder().decode(AccountState.self, from: Data(#"{"id":"C1","status":"normal","primaryUsedPercent":20}"#.utf8))
        XCTAssertEqual(config.provider, .codex)
        XCTAssertEqual(state.provider, .codex)
        XCTAssertEqual(state.primaryRemainingPercent, 80)
    }

    @MainActor
    func testClaudeNeverQualifiesForAutomaticModelPing() {
        let state = AccountState(id: "C2", primaryRemainingPercent: 100, secondaryRemainingPercent: 100,
                                 status: .normal, provider: .claude)
        XCTAssertFalse(AutomaticResetPingCoordinator.canSend(state))
    }

    func testClaudeCannotEnterTheCodexModelProbe() async {
        let result = await UsageWindowProbeService().probe(config)
        XCTAssertEqual(result.failureCategory, .notConfigured)
        XCTAssertFalse(result.isSuccess)
    }
}

private actor RequestRecorder {
    var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
}
