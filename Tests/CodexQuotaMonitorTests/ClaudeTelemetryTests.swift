// 목적: 공식 토큰 메트릭·계정 격리·HTTP 수신·실제 CLI 연동 검증
// 이용처: Claude 공식 토큰 수집의 회귀 테스트
// 사용방법: swift test --filter ClaudeTelemetryTests
// 실행 예시: CLAUDE_TELEMETRY_LIVE_HOME=~/.claude swift test --filter ClaudeTelemetryTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 원문·대화 기록 없는 공식 카운터 수신 검증
@MainActor
final class ClaudeTelemetryTests: XCTestCase {
    /// 별도 폴더를 사용하는 테스트 상태 초기화
    private func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(".claude-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// 공식 OTLP JSON의 누적 토큰 포인트 구성
    private func metric(value: Int, seconds: Int, email: String = "a@example.test", temporality: Int = 2, start: Int = 1700000000) throws -> Data {
        let fields = ["user.email":email, "organization.id":"org", "session.id":"55555555-5555-5555-5555-555555555555", "type":"input", "model":"claude-opus-5-5", "query_source":"main"]
        let point: [String: Any] = ["attributes":fields.map { ["key":$0.key,"value":["stringValue":$0.value]] },
            "startTimeUnixNano":String(Int64(start) * 1_000_000_000), "timeUnixNano":String(Int64(seconds) * 1_000_000_000), "asInt":String(value)]
        return try JSONSerialization.data(withJSONObject: ["resourceMetrics":[["scopeMetrics":[["metrics":[["name":"claude_code.token.usage","sum":["aggregationTemporality":temporality,"isMonotonic":true,"dataPoints":[point]]]]]]]]])
    }

    /// 재전송·역순·계정별 분리와 누적 카운터 증가분 검증
    func testCumulativeReplayOutOfOrderAndAccountIsolation() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ClaudeTelemetryStore()
        let now = Date(timeIntervalSince1970: 1700000300)
        try await store.ingest(metric(value: 100, seconds: 1700000100), home: home, now: now)
        try await store.ingest(metric(value: 100, seconds: 1700000100), home: home, now: now)
        try await store.ingest(metric(value: 80, seconds: 1700000050), home: home, now: now)
        try await store.ingest(metric(value: 150, seconds: 1700000200), home: home, now: now)
        try await store.ingest(metric(value: 300, seconds: 1700000200, email: "b@example.test"), home: home, now: now)
        let auth = try JSONDecoder().decode(ClaudeAuthentication.self, from: Data("{\"loggedIn\":true,\"email\":\"a@example.test\",\"orgId\":\"org\",\"authMethod\":\"claude.ai\"}".utf8))
        let usage = try await store.usage(home: home, identity: auth.identity, email: auth.email)
        XCTAssertEqual(usage.lifetimeTokens, 150)
        XCTAssertEqual(usage.days?.first?.tokens, 150)
        try await store.ingest(metric(value: 7, seconds: 1700000300, temporality: 1), home: home, now: now)
        let unchanged = try await store.usage(home: home, identity: auth.identity, email: auth.email)
        XCTAssertEqual(unchanged.lifetimeTokens, 150)
        let persisted = try String(contentsOf: ClaudeQuotaSnapshot.directory(home: home).appendingPathComponent("official-tokens.json"), encoding: .utf8)
        XCTAssertFalse(persisted.contains("a@example.test"))
        XCTAssertFalse(persisted.contains("b@example.test"))
    }

    /// 설치·복원의 원본 환경·상태 표시줄 보존과 사용자 변경 보호 검증
    func testConnectionPreservesOtherSettingsAndRestores() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("settings.json")
        let original: [String: Any] = ["env":["CUSTOM":"fixture", "OTEL_METRICS_EXPORTER":"console"], "statusLine":["type":"command","command":"cat"]]
        try JSONSerialization.data(withJSONObject: original).write(to: file)
        try ClaudeTelemetryConnection.install(home: home, endpoint: URL(string: "http://127.0.0.1:43187/test/v1/metrics")!)
        XCTAssertTrue(ClaudeTelemetryConnection.isInstalled(home: home))
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual((settings["env"] as? [String: String])?["OTEL_METRICS_EXPORTER"], "console,otlp")
        try ClaudeTelemetryConnection.remove(home: home)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? NSDictionary, original as NSDictionary)
    }

    /// HTTP 수신 경로 인증과 분할 가능한 표준 요청 처리 검증
    func testLocalHTTPReceiver() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let server = ClaudeTelemetryServer(port: 0)
        server.start()
        defer { server.stop() }
        let deadline = Date().addingTimeInterval(5)
        while server.listeningPort == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(server.listeningPort)
        let endpoint = server.register(home: home)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try metric(value: 42, seconds: Int(Date().timeIntervalSince1970))
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        request.url = endpoint.deletingLastPathComponent().appendingPathComponent("unknown")
        let (_, rejected) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 400)
    }

    /// 실제 CLI의 공식 OTLP 출력에 계정·토큰 카운터가 포함되는지 검증
    func testOfficialCLIExportWhenConfigured() async throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_TELEMETRY_LIVE_HOME"] else { throw XCTSkip("실제 CLI 메트릭 검증 폴더 미지정") }
        let home = URL(fileURLWithPath: path)
        let server = ClaudeTelemetryServer(port: 0)
        server.start()
        defer { server.stop() }
        let ready = Date().addingTimeInterval(5)
        while server.listeningPort == nil && Date() < ready { try await Task.sleep(for: .milliseconds(20)) }
        let endpoint = server.register(home: home)
        let environment: [String: String] = ["CLAUDE_CODE_ENABLE_TELEMETRY":"1","OTEL_METRICS_EXPORTER":"otlp","OTEL_LOGS_EXPORTER":"none",
            "OTEL_EXPORTER_OTLP_METRICS_PROTOCOL":"http/json","OTEL_EXPORTER_OTLP_METRICS_ENDPOINT":endpoint.absoluteString,
            "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE":"cumulative","OTEL_METRIC_EXPORT_INTERVAL":"1000"]
        let settings = String(decoding: try JSONSerialization.data(withJSONObject: ["env":environment]), as: UTF8.self)
        let cli = ClaudeCLI()
        let initialAuth = try await Task.detached { try cli.authentication(home: home) }.value
        let baseline = try await ClaudeTelemetryStore.shared.usage(home: home, identity: initialAuth.identity, email: initialAuth.email).lifetimeTokens ?? 0
        let data = try await Task.detached {
            try cli.run(arguments:["--settings",settings,"--print","Reply only with the JSON object {\"official_telemetry_test\":\"ok\"}.","--output-format","json","--no-session-persistence","--tools","","--strict-mcp-config"],home:home,limit:60)
        }.value
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(envelope["is_error"] as? Bool, false)
        let authentication = try await Task.detached { try cli.authentication(home: home) }.value
        let deadline = Date().addingTimeInterval(8)
        var usage: AccountTokenUsage?
        repeat {
            usage = try await ClaudeTelemetryStore.shared.usage(home: home, identity: authentication.identity, email: authentication.email)
            if (usage?.lifetimeTokens ?? 0) > baseline { break }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        XCTAssertGreaterThan(try XCTUnwrap(usage?.lifetimeTokens), baseline)
        let report: [String: Any] = ["source":"official claude_code.token.usage via OTLP http/json", "account_verified":true,
            "received_tokens":try XCTUnwrap(usage?.lifetimeTokens),"new_tokens":(usage?.lifetimeTokens ?? 0) - baseline,"days":usage?.days?.count ?? 0]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: "/private/tmp/claude-official-telemetry-result.json"))
    }
    /// 포트 충돌 시 사용자 설정에 다른 프로세스의 수집 주소를 쓰지 않는 검증
    func testOccupiedPortDoesNotInstallSettings() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let owner = ClaudeTelemetryServer(port: 0)
        owner.start()
        defer { owner.stop() }
        let deadline = Date().addingTimeInterval(5)
        while owner.listeningPort == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let competitor = ClaudeTelemetryServer(port: try XCTUnwrap(owner.listeningPort))
        defer { competitor.stop() }
        do { try await competitor.setEnabled(true, home: home); XCTFail("점유 포트에 수집 설치 금지") }
        catch { XCTAssertEqual(error as? ClaudeQuotaError, .telemetryUnavailable) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("settings.json").path))
    }

    /// 비지원 포인트가 정상 포인트 수신을 차단하지 않는 검증
    func testInvalidPointDoesNotDropWholeBatch() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: metric(value: 50, seconds: 1700000100)) as? [String: Any])
        var resources = try XCTUnwrap(value["resourceMetrics"] as? [[String: Any]])
        var scopes = try XCTUnwrap(resources[0]["scopeMetrics"] as? [[String: Any]])
        var metrics = try XCTUnwrap(scopes[0]["metrics"] as? [[String: Any]])
        var sum = try XCTUnwrap(metrics[0]["sum"] as? [String: Any])
        var points = try XCTUnwrap(sum["dataPoints"] as? [[String: Any]])
        points.append(["attributes":[],"asInt":"9"])
        sum["dataPoints"] = points; metrics[0]["sum"] = sum; scopes[0]["metrics"] = metrics
        resources[0]["scopeMetrics"] = scopes; value["resourceMetrics"] = resources
        let store = ClaudeTelemetryStore()
        try await store.ingest(JSONSerialization.data(withJSONObject: value), home: home, now: Date(timeIntervalSince1970:1700000300))
        let persisted = try Data(contentsOf: ClaudeQuotaSnapshot.directory(home: home).appendingPathComponent("official-tokens.json"))
        XCTAssertFalse(persisted.isEmpty)
    }

    /// 카운터 상한 도달 후 신규 수집 지속·제거된 시계열의 재합산 차단 검증
    func testCounterPruningKeepsCollectionRunning() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ClaudeTelemetryStore(maximumCounters: 2)
        let now = Date(timeIntervalSince1970: 1700000500)
        for index in 0..<4 {
            try await store.ingest(metric(value: (index + 1) * 10, seconds:1700000100 + index * 20,
                email:"\(index)@example.test", start:1700000090 + index * 20), home: home, now: now)
        }
        try await store.ingest(metric(value:10, seconds:1700000100, email:"0@example.test", start:1700000090), home:home, now:now)
        let auth = try JSONDecoder().decode(ClaudeAuthentication.self, from: Data("{\"loggedIn\":true,\"email\":\"0@example.test\",\"orgId\":\"org\",\"authMethod\":\"claude.ai\"}".utf8))
        let old = try await store.usage(home:home, identity:auth.identity, email:auth.email)
        XCTAssertEqual(old.lifetimeTokens, 10)
        let newest = try JSONDecoder().decode(ClaudeAuthentication.self, from: Data("{\"loggedIn\":true,\"email\":\"3@example.test\",\"orgId\":\"org\",\"authMethod\":\"claude.ai\"}".utf8))
        let fresh = try await store.usage(home:home, identity:newest.identity, email:newest.email)
        XCTAssertEqual(fresh.lifetimeTokens, 40)
    }

}
