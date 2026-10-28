// 목적: 별도 수집 연결 없는 Claude 수동 조회와 이전 설정 복원 검증
// 이용처: 우상단 새로고침의 계정 서비스·토큰 조회 경로 회귀 테스트
// 사용방법: swift test --filter ClaudeManualRefreshTests
// 실행 예시: swift test --filter ClaudeManualRefreshTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// CLI 응답과 로컬 기록을 제어한 새로고침 통합 검증
@MainActor
final class ClaudeManualRefreshTests: XCTestCase {
    /// 수집 설정 없이 연속 새로고침의 신규 할당량·로컬 토큰 반영 검증
    func testManualRefreshReadsNewQuotaAndLocalTokensWithoutCollection() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.home) }
        let settings = f.home.appendingPathComponent("settings.json")
        let original = Data("{\"theme\":\"dark\"}".utf8)
        try original.write(to: settings)
        let suite = "ClaudeManualRefresh-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(userDefaults: defaults, defaultPaths: [f.home.path, "", "", ""], quotaDatabaseURL: f.home.appendingPathComponent("quota.sqlite"))
        let store = AccountStore(configs: [f.config], preferencesStore: preferences) { config in
            await AccountQuotaService.state(for: config, claude: ClaudeQuotaService(cli: f.cli))
        }
        let checks = QuotaRefreshCoordinator(store: store, sleep: { _ in })
        let tokens = ClaudeTokenUsageProvider(cli: f.cli)
        try writeUsage(home: f.home, used: 20)
        try writeStats(home: f.home, tokens: 100)
        await checks.refresh(accountID: "C1")
        XCTAssertEqual(store.state(for: "C1")?.primaryRemainingPercent, 80)
        let first = try await tokens.fetch(for: f.config, expectedEmail: "fixture@example.test").get()
        XCTAssertEqual(first.lifetimeTokens, 100)
        try writeUsage(home: f.home, used: 0)
        try writeStats(home: f.home, tokens: 250)
        await checks.refresh(accountID: "C1")
        XCTAssertEqual(store.state(for: "C1")?.primaryRemainingPercent, 100)
        let second = try await tokens.fetch(for: f.config, expectedEmail: "fixture@example.test").get()
        XCTAssertEqual(second.lifetimeTokens, 250)
        XCTAssertFalse(ClaudeStatusLineConnection.isInstalled(home: f.home))
        XCTAssertFalse(ClaudeTelemetryConnection.isInstalled(home: f.home))
        XCTAssertEqual(try Data(contentsOf: settings), original)
    }

    /// 정상 조회 후 이전 앱의 두 수집 연결 제거와 사용자 설정 보존 검증
    func testSuccessfulRefreshRestoresLegacyCollectorsAutomatically() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.home) }
        let settings = f.home.appendingPathComponent("settings.json")
        let original: [String: Any] = ["theme": "dark", "env": ["CUSTOM": "kept"], "statusLine": ["type": "command", "command": "/bin/cat"]]
        try JSONSerialization.data(withJSONObject: original).write(to: settings)
        try installCollectors(f)
        try writeUsage(home: f.home, used: 0)
        let state = await ClaudeQuotaService(cli: f.cli).state(for: f.config)
        XCTAssertEqual(state.status, .normal)
        XCTAssertEqual(state.primaryRemainingPercent, 100)
        XCTAssertFalse(ClaudeStatusLineConnection.isInstalled(home: f.home))
        XCTAssertFalse(ClaudeTelemetryConnection.isInstalled(home: f.home))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? NSDictionary, original as NSDictionary)
    }

    /// 사용자 변경 이후 자동 복원의 설정 덮어쓰기 차단 검증
    func testMigrationPreservesUserModifiedCollectors() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.home) }
        try installCollectors(f)
        let settings = f.home.appendingPathComponent("settings.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        object["statusLine"] = ["type": "command", "command": "user-custom-command"]
        var env = try XCTUnwrap(object["env"] as? [String: String])
        env["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"] = "http://127.0.0.1:9999/custom"
        object["env"] = env
        let modified = try JSONSerialization.data(withJSONObject: object)
        try modified.write(to: settings)
        try writeUsage(home: f.home, used: 10)
        let state = await ClaudeQuotaService(cli: f.cli).state(for: f.config)
        XCTAssertEqual(state.status, .normal)
        XCTAssertEqual(try Data(contentsOf: settings), modified)
    }

    /// 사용량 조회 실패 시 수집 설정 전환 보류 검증
    func testFailedRefreshKeepsLegacyCollectors() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.home) }
        try installCollectors(f)
        try writeEnvelope(home: f.home, text: "Showing last-known usage")
        let state = await ClaudeQuotaService(cli: f.cli).state(for: f.config)
        XCTAssertEqual(state.status, .error)
        XCTAssertTrue(ClaudeStatusLineConnection.isInstalled(home: f.home))
        XCTAssertTrue(ClaudeTelemetryConnection.isInstalled(home: f.home))
    }

    /// 명시한 실계정의 신규 할당량·로컬 토큰·수집 연결 불필요 검증
    func testRealRefreshWithoutCollectorWhenConfigured() async throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_REFRESH_LIVE_HOME"] else {
            throw XCTSkip("실계정 새로고침 폴더 미지정")
        }
        let home = URL(fileURLWithPath: path)
        let config = AccountConfig(id: "C1", home: home, position: .left)
        let start = Date()
        let account = await AccountQuotaService.state(for: config)
        XCTAssertEqual(account.status, .normal)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(account.lastUpdated), start)
        XCTAssertNotNil(account.primaryUsedPercent)
        XCTAssertNotNil(account.secondaryUsedPercent)
        let tokens = try await ClaudeTokenUsageProvider().fetch(for: config, expectedEmail: account.email).get()
        XCTAssertNotNil(tokens.days)
        XCTAssertFalse(ClaudeStatusLineConnection.isInstalled(home: home))
        XCTAssertFalse(ClaudeTelemetryConnection.isInstalled(home: home))
        let report: [String: Any] = ["fresh": true, "five_hour_used": try XCTUnwrap(account.primaryUsedPercent),
            "seven_day_used": try XCTUnwrap(account.secondaryUsedPercent), "token_days": tokens.days?.count ?? 0,
            "collection_required": false]
        try JSONSerialization.data(withJSONObject: report).write(to: URL(fileURLWithPath: "/private/tmp/claude-manual-refresh-live-result.json"))
    }

    /// 계정 조회·사용량 응답만 반환하는 격리 CLI 구성
    private func fixture() throws -> ClaudeRefreshFixture {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(".claude-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let executable = home.appendingPathComponent("claude")
        let script = "#!/bin/sh\nif [ \"$1\" = auth ]; then /bin/cat \"$CLAUDE_CONFIG_DIR/auth-fixture.json\"; else /bin/cat \"$CLAUDE_CONFIG_DIR/usage-fixture.json\"; fi\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try JSONSerialization.data(withJSONObject: ["loggedIn": true, "email": "fixture@example.test", "authMethod": "claude.ai", "orgId": "fixture", "subscriptionType": "pro"]).write(to: home.appendingPathComponent("auth-fixture.json"))
        return ClaudeRefreshFixture(home: home, cli: ClaudeCLI(executable: executable))
    }

    /// 비용·턴 없는 CLI 사용량 응답 구성
    private func writeEnvelope(home: URL, text: String) throws {
        try JSONSerialization.data(withJSONObject: ["is_error": false, "num_turns": 0, "total_cost_usd": 0, "result": text]).write(to: home.appendingPathComponent("usage-fixture.json"))
    }

    /// 미래 초기화 시각을 포함한 공식 사용량 표시 구성
    private func writeUsage(home: URL, used: Int) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM d 'at' h:mma"
        let reset = formatter.string(from: Date().addingTimeInterval(3_600))
        let week = formatter.string(from: Date().addingTimeInterval(86_400))
        try writeEnvelope(home: home, text: "Current session: \(used)% used · resets \(reset) (UTC)\nCurrent week (all models): 4% used · resets \(week) (UTC)")
    }

    /// 과거 완료일의 로컬 Stats 합계 변경 구성
    private func writeStats(home: URL, tokens: Int) throws {
        let day = AccountUsageCalendar.label(Date().addingTimeInterval(-86_400))
        try JSONSerialization.data(withJSONObject: ["version": 5, "dailyModelTokensVersion": 5, "lastComputedDate": day,
            "dailyModelTokens": [["date": day, "tokensByModel": ["claude-test": tokens]]]]).write(to: home.appendingPathComponent("stats-cache.json"))
    }

    /// 복원 검증용 상태 표시줄·토큰 메트릭 연결 설치
    private func installCollectors(_ fixture: ClaudeRefreshFixture) throws {
        try ClaudeStatusLineConnection.install(home: fixture.home, appExecutable: fixture.home.appendingPathComponent("removed-app"), cliExecutable: try XCTUnwrap(fixture.cli.executable))
        try ClaudeTelemetryConnection.install(home: fixture.home, endpoint: URL(string: "http://127.0.0.1:43187/test/v1/metrics")!)
    }
}

/// 조회 작업 사이에 공유하는 불변 테스트 경로
private struct ClaudeRefreshFixture: Sendable {
    let home: URL
    let cli: ClaudeCLI
    var config: AccountConfig { AccountConfig(id: "C1", home: home, position: .left) }
}
