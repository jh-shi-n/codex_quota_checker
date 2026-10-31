// 목적: 폴더별 연결·계정 저장소·활성 세션·화면 통합 검증
// 이용처: Claude 제공자 통합과 실제 폴더 연결 검증
// 사용방법: swift test --filter ClaudeIntegrationTests
// 실행 예시: CLAUDE_QUOTA_LIVE_HOME=~/.claude swift test --filter testLiveClaudeConnection
import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import CodexQuotaMonitorKit

/// 사용자 설정과 분리한 통합 검증
@MainActor
final class ClaudeIntegrationTests: XCTestCase {
    /// 정상·종료·부정확한 PID의 세션 필터 및 대화 원문 미사용 검증
    func testClaudeSessionProjectionRejectsDeadProcesses() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(".claude-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for pid in [42, 43, 44] {
            let object: [String: Any] = ["pid": pid, "kind": "interactive", "entrypoint": "cli", "status": pid == 42 ? "busy" : "idle",
                "sessionId": "00000000-0000-0000-0000-0000000000\(pid)", "updatedAt": Date().timeIntervalSince1970 * 1000,
                "name": pid == 42 ? "Claude quota review" : "prompt/private/path", "procStart": "fixture", "content": "must never appear"]
            try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent("\(pid).json"))
        }
        try Data("secret".utf8).write(to: directory.appendingPathComponent("42.secret.key"))
        let provider = ClaudeSessionActivityProvider(isAlive: { pid, _ in pid != 43 })
        let result = await provider.snapshot(accountID: "C2", home: home)
        XCTAssertEqual(result.state, .available)
        XCTAssertEqual(result.sessions.count, 2)
        XCTAssertEqual(result.sessions.first?.status, .working)
        XCTAssertEqual(result.sessions.first?.taskName, "Claude quota review")
        XCTAssertEqual(result.sessions.last?.taskName, "Claude session")
        XCTAssertTrue(result.sessions.allSatisfy { $0.agents.isEmpty && $0.source == .cli })
    }

    /// 인증 성공·등록 허용 및 공통 할당량 캐시 초기 복원 검증
    func testClaudeSetupAndStoreRestoreSharedQuotaCache() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(".claude-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let suite = "ClaudeIntegration-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(userDefaults: defaults)
        let loader: AccountStateLoader = { config in
            AccountState(id: config.id, email: "claude@example.test", planType: "pro", primaryUsedPercent: 18,
                secondaryUsedPercent: 4, primaryResetAt: Date().addingTimeInterval(1000),
                secondaryResetAt: Date().addingTimeInterval(10000), lastUpdated: Date(), status: .normal, provider: .claude)
        }
        let model = AccountSetupModel(checker: { config in try! await loader(config) })
        model.path = home.path
        await model.checkConnection()
        XCTAssertTrue(model.canFinish)
        XCTAssertEqual(model.detectedProvider, .claude)
        XCTAssertEqual(preferences.registerAccount(path: try XCTUnwrap(model.registrationPath())), "C1")
        let store = AccountStore(configs: AccountConfig.accounts(for: preferences.accountPaths), preferencesStore: preferences, stateLoader: loader)
        XCTAssertEqual(store.states.first?.provider, .claude)
        XCTAssertNil(store.states.first?.email)
        var events = 0
        store.onEarlyQuotaReset = { _ in events += 1 }
        let success = await store.refresh(accountID: "C1")
        XCTAssertTrue(success)
        let state = try XCTUnwrap(store.state(for: "C1"))
        XCTAssertEqual(state.provider, .claude)
        XCTAssertEqual(state.primaryUsedPercent, 18)
        XCTAssertEqual(state.primaryResetObservation, .checking)
        XCTAssertEqual(preferences.quotaSnapshot(for: home)?.provider, .claude)
        let restarted = AccountStore(configs: store.configs, preferencesStore: preferences, stateLoader: loader)
        XCTAssertEqual(restarted.state(for: "C1")?.primaryUsedPercent, 18)
        XCTAssertEqual(restarted.state(for: "C1")?.provider, .claude)
        XCTAssertEqual(restarted.state(for: "C1")?.status, .loading)
        XCTAssertEqual(restarted.state(for: "C1")?.isWaitingForRefresh, true)
        XCTAssertEqual(events, 0)
        XCTAssertEqual(AccountDetailView.statusText(for: AccountState(id: "C1", status: .normal, provider: .claude)), "사용량 대기")
    }

    /// 디스크 재시작 복원·유효 캐시의 단일 조회·로그인 변경 후 정상값 교체 검증
    func testClaudeQuotaDiskCacheSurvivesRestartAndRefreshesIdentity() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(".claude-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let suite = "ClaudeQuotaRestart-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = home.appendingPathComponent("cache.sqlite")
        let config = AccountConfig(id: "C1", home: home, position: .left)
        let original = AccountState(id: "C1", email: "first@example.test", planType: "pro",
            primaryUsedPercent: 42, secondaryUsedPercent: 13,
            primaryResetAt: Date().addingTimeInterval(1000), secondaryResetAt: Date().addingTimeInterval(10000),
            lastUpdated: Date(), status: .normal, provider: .claude)
        let preferences = PreferencesStore(userDefaults: defaults, defaultPaths: [home.path, "", "", ""], quotaDatabaseURL: database)
        let first = AccountStore(configs: [config], preferencesStore: preferences, stateLoader: { _ in original })
        await first.refresh(accountID: "C1")
        await preferences.waitForCacheIO()
        let reloaded = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
        await reloaded.waitForCacheIO()
        let restarted = AccountStore(configs: [config], preferencesStore: reloaded, stateLoader: { _ in
            var updated = original
            updated.lastUpdated = Date()
            updated.primaryUsedPercent = 43
            return updated
        })
        XCTAssertEqual(restarted.state(for: "C1")?.primaryUsedPercent, 42)
        XCTAssertEqual(restarted.state(for: "C1")?.email, original.email)
        XCTAssertEqual(restarted.state(for: "C1")?.provider, .claude)
        let checks = QuotaRefreshCoordinator(store: restarted, sleep: { _ in XCTFail("유효 캐시의 불필요한 재조회") })
        await checks.refresh(accountID: "C1", startup: true)
        XCTAssertEqual(restarted.state(for: "C1")?.primaryUsedPercent, 43)
        XCTAssertEqual(restarted.state(for: "C1")?.status, .normal)
        let switched = AccountStore(configs: [config], preferencesStore: reloaded, stateLoader: { _ in
            var updated = original
            updated.email = "second@example.test"
            updated.primaryUsedPercent = 7
            updated.lastUpdated = Date()
            return updated
        })
        await switched.refresh(accountID: "C1")
        XCTAssertEqual(switched.state(for: "C1")?.email, "second@example.test")
        XCTAssertEqual(reloaded.quotaSnapshot(for: home)?.primaryUsedPercent, 7)
    }

    /// 조회 실패의 유효 캐시 보존 및 다른 제공자·로그인 계정 캐시 차단 검증
    func testClaudeFailureRetainsMatchingCacheAndRejectsDifferentIdentity() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(".claude-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let suite = "ClaudeQuotaFailure-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(userDefaults: defaults, defaultPaths: [home.path, "", "", ""])
        let config = AccountConfig(id: "C1", home: home, position: .left)
        preferences.updateQuotaSnapshot(for: home, snapshot: .init(usedPercent: 42,
            resetAt: Date().addingTimeInterval(1000), lastUpdated: Date(), email: "first@example.test"))
        let otherProvider = AccountStore(configs: [config], preferencesStore: preferences)
        XCTAssertNil(otherProvider.state(for: "C1")?.primaryUsedPercent)
        preferences.updateQuotaSnapshot(for: home, snapshot: .init(usedPercent: 42,
            resetAt: Date().addingTimeInterval(1000), lastUpdated: Date(), email: "first@example.test", provider: .claude))
        let same = AccountStore(configs: [config], preferencesStore: preferences, stateLoader: { _ in
            AccountState(id: "C1", email: "first@example.test", status: .timeout, provider: .claude)
        })
        await same.refresh(accountID: "C1")
        XCTAssertEqual(same.state(for: "C1")?.primaryUsedPercent, 42)
        XCTAssertEqual(same.state(for: "C1")?.status, .timeout)
        let different = AccountStore(configs: [config], preferencesStore: preferences, stateLoader: { _ in
            AccountState(id: "C1", email: "second@example.test", status: .error, provider: .claude)
        })
        await different.refresh(accountID: "C1")
        XCTAssertEqual(different.state(for: "C1")?.email, "second@example.test")
        XCTAssertNil(different.state(for: "C1")?.primaryUsedPercent)
        preferences.updateQuotaSnapshot(for: home, snapshot: .init(usedPercent: 42,
            resetAt: Date().addingTimeInterval(-1), lastUpdated: Date().addingTimeInterval(-10),
            email: "first@example.test", provider: .claude))
        let expired = AccountStore(configs: [config], preferencesStore: preferences)
        XCTAssertEqual(expired.state(for: "C1")?.primaryUsedPercent, 0)
        XCTAssertEqual(expired.state(for: "C1")?.primaryRemainingPercent, 100)
        XCTAssertEqual(expired.state(for: "C1")?.primaryResetObservation, .checking)
    }

    /// 기존 Claude 전용 파일의 인증 확인 결과를 서버 조회 전 공통 캐시로 이관 검증
    func testLegacyClaudeSnapshotMigratesBeforeStartupQuery() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(".claude-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: ClaudeQuotaSnapshot.directory(home: home), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let suite = "ClaudeLegacyRestore-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(userDefaults: defaults, defaultPaths: [home.path, "", "", ""], quotaDatabaseURL: home.appendingPathComponent("cache.sqlite"))
        let cached = AccountState(id: "C1", email: "first@example.test", planType: "pro",
            primaryUsedPercent: 42, primaryResetAt: Date().addingTimeInterval(1000),
            lastUpdated: Date().addingTimeInterval(-30), status: .normal, provider: .claude)
        let config = AccountConfig(id: "C1", home: home, position: .left)
        let executable = home.appendingPathComponent("claude")
        try Data("#!/bin/sh\ncat \"$CLAUDE_CONFIG_DIR/auth-fixture.json\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try JSONSerialization.data(withJSONObject: ["loggedIn": true, "email": "first@example.test", "authMethod": "claude.ai", "subscriptionType": "pro"]).write(to: home.appendingPathComponent("auth-fixture.json"))
        let cli = ClaudeCLI(executable: executable)
        let snapshot = ClaudeQuotaSnapshot(identity: try cli.authentication(home: home).identity, windows: [
            "five_hour": ClaudeQuotaWindow(usedPercentage: 42, resetsAt: try XCTUnwrap(cached.primaryResetAt), observedAt: try XCTUnwrap(cached.lastUpdated))
        ])
        try JSONEncoder().encode(snapshot).write(to: ClaudeQuotaSnapshot.file(home: home))
        let store = AccountStore(configs: [config], preferencesStore: preferences, claudeCacheService: ClaudeQuotaService(cli: cli), stateLoader: { _ in
            var updated = cached
            updated.primaryUsedPercent = 43
            updated.lastUpdated = Date()
            return updated
        })
        await store.waitForInitialCache()
        XCTAssertEqual(store.state(for: "C1")?.primaryUsedPercent, 42)
        XCTAssertEqual(store.state(for: "C1")?.status, .loading)
        XCTAssertEqual(preferences.quotaSnapshot(for: home)?.provider, .claude)
        let checks = QuotaRefreshCoordinator(store: store, sleep: { _ in XCTFail("이관된 유효 캐시의 불필요한 재조회") })
        await checks.refresh(accountID: "C1", startup: true)
        XCTAssertEqual(store.state(for: "C1")?.primaryUsedPercent, 43)
    }

    /// 별도 수집 연결 없는 실제 CLI 조회·앱 저장소·화면 렌더링 검증
    func testLiveClaudeConnection() async throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_QUOTA_LIVE_HOME"] else {
            throw XCTSkip("실계정 폴더를 명시한 경우에만 실행")
        }
        let home = URL(fileURLWithPath: path)
        let model = AccountSetupModel()
        model.path = home.path
        await model.checkConnection()
        XCTAssertEqual(model.connectedAccount?.provider, .claude)
        XCTAssertTrue(model.canFinish)
        let suite = "ClaudeLive-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(userDefaults: defaults)
        XCTAssertEqual(preferences.registerAccount(path: try XCTUnwrap(model.registrationPath())), "C1")
        let store = AccountStore(configs: AccountConfig.accounts(for: preferences.accountPaths), preferencesStore: preferences)
        let deadline = Date().addingTimeInterval(25)
        repeat {
            _ = await store.refresh(accountID: "C1")
            if store.state(for: "C1")?.primaryUsedPercent != nil { break }
            try await Task.sleep(for: .milliseconds(500))
        } while Date() < deadline
        let account = try XCTUnwrap(store.state(for: "C1"))
        XCTAssertEqual(account.status, .normal)
        XCTAssertEqual(account.provider, .claude)
        XCTAssertNotNil(account.email)
        XCTAssertNotNil(account.primaryUsedPercent)
        XCTAssertNotNil(account.secondaryUsedPercent)
        let modelDeadline = Date().addingTimeInterval(5)
        var sessions = await ProviderSessionActivityProvider().snapshot(accountID: "C1", home: home)
        while !sessions.sessions.contains(where: { $0.model != nil }) && Date() < modelDeadline {
            try await Task.sleep(for: .milliseconds(100))
            sessions = await ProviderSessionActivityProvider().snapshot(accountID: "C1", home: home)
        }
        XCTAssertTrue(sessions.sessions.contains(where: { $0.model != nil }))
        XCTAssertEqual(sessions.state, .available)
        XCTAssertFalse(sessions.sessions.isEmpty)
        let report: [String: Any] = ["provider": account.provider.rawValue, "account_verified": account.email != nil,
            "plan": account.planType ?? "", "five_hour_used": try XCTUnwrap(account.primaryUsedPercent),
            "seven_day_used": try XCTUnwrap(account.secondaryUsedPercent), "live_sessions": sessions.sessions.count, "models": sessions.sessions.compactMap(\.model),
            "setup_can_finish": model.canFinish, "registered_slot": "C1", "codex_cache_written": preferences.quotaSnapshot(for: home) != nil]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "/private/tmp/claude-quota-live-result.json"))
        let currentSessions = sessions
        ClaudeTelemetryServer.shared.configure(store.configs)
        let previousLoader = AccountTokenUsageStore.shared.loader
        AccountTokenUsageStore.shared.loader = { current in
            await ClaudeTokenUsageProvider().fetch(for: AccountConfig(id: current.id, home: home, position: .left), expectedEmail: current.email)
        }
        defer {
            AccountTokenUsageStore.shared.invalidateAll()
            AccountTokenUsageStore.shared.loader = previousLoader
        }
        await AccountTokenUsageStore.shared.refresh(for: account, force: true)?.value
        if ProcessInfo.processInfo.environment["CLAUDE_TELEMETRY_EXPECT_DATA"] == "1" {
            XCTAssertGreaterThan(AccountTokenUsageStore.shared.snapshot(for: account)?.lifetimeTokens ?? 0, 0)
        }
        let view = AccountDetailView(account: account, loadSessionActivity: { _ in currentSessions })
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 620)
        hosting.layoutSubtreeIfNeeded()
        if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: "/private/tmp/claude-quota-preview.png"))
            }
        }
    }
}
