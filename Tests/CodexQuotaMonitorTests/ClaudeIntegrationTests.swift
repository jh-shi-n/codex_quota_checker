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

    /// 인증 성공·첫 수신 대기·등록 허용 및 제공자별 저장소 분기 검증
    func testClaudeSetupAndStoreKeepProviderWithoutCodexCache() async throws {
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
        XCTAssertNil(preferences.quotaSnapshot(for: home))
        XCTAssertEqual(events, 0)
        XCTAssertEqual(AccountDetailView.statusText(for: AccountState(id: "C1", status: .normal, provider: .claude)), "사용량 대기")
    }

    /// 실제 CLI 폴더의 인증·명시 수집 연결·앱 저장소·화면 렌더링 검증
    func testLiveClaudeConnection() async throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_QUOTA_LIVE_HOME"],
              let executable = ProcessInfo.processInfo.environment["CLAUDE_QUOTA_LIVE_APP"] else {
            throw XCTSkip("실계정 폴더·수집 앱 경로를 명시한 경우에만 실행")
        }
        let home = URL(fileURLWithPath: path)
        let cli = try XCTUnwrap(ClaudeCLI.locate())
        let model = AccountSetupModel()
        model.path = home.path
        await model.checkConnection()
        XCTAssertEqual(model.connectedAccount?.provider, .claude)
        XCTAssertTrue(model.canFinish)
        let wasInstalled = ClaudeStatusLineConnection.isInstalled(home: home)
        model.setClaudeCollectionEnabled(true, appExecutable: URL(fileURLWithPath: executable), cliExecutable: cli)
        XCTAssertTrue(model.isClaudeCollectionInstalled)
        defer { if !wasInstalled { try? ClaudeStatusLineConnection.remove(home: home) } }
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
        let sessions = await ProviderSessionActivityProvider().snapshot(accountID: "C1", home: home)
        XCTAssertEqual(sessions.state, .available)
        XCTAssertFalse(sessions.sessions.isEmpty)
        let report: [String: Any] = ["provider": account.provider.rawValue, "account_verified": account.email != nil,
            "plan": account.planType ?? "", "five_hour_used": try XCTUnwrap(account.primaryUsedPercent),
            "seven_day_used": try XCTUnwrap(account.secondaryUsedPercent), "live_sessions": sessions.sessions.count,
            "setup_can_finish": model.canFinish, "registered_slot": "C1", "codex_cache_written": preferences.quotaSnapshot(for: home) != nil]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "/private/tmp/claude-quota-live-result.json"))
        let view = AccountDetailView(account: account, loadSessionActivity: { _ in sessions })
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
