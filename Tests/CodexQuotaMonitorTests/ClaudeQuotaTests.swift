// 목적: Claude 할당량 수집·인증 격리·기존 상태 표시줄 보존 검증
// 이용처: Claude 폴더 연결의 데이터 경계 회귀 테스트
// 사용방법: swift test --filter ClaudeQuotaTests
// 실행 예시: swift test --filter ClaudeQuotaTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 수집기와 실제 파일·프로세스 경계의 검증
final class ClaudeQuotaTests: XCTestCase {
    /// 인증 응답을 제어하는 임시 Claude 폴더·CLI 구성
    private func fixture() throws -> (URL, ClaudeCLI) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(".claude-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let cli = home.appendingPathComponent("claude")
        try Data("#!/bin/sh\ncat \"$CLAUDE_CONFIG_DIR/auth-fixture.json\"\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        try authentication(home: home, email: "a@example.test")
        return (home, ClaudeCLI(executable: cli))
    }

    /// 토큰 없이 테스트 계정 표시값만 인증 응답에 기록
    private func authentication(home: URL, email: String) throws {
        let value: [String: Any] = ["loggedIn": true, "email": email, "authMethod": "claude.ai", "orgId": "org", "subscriptionType": "pro"]
        try JSONSerialization.data(withJSONObject: value).write(to: home.appendingPathComponent("auth-fixture.json"))
    }

    /// 테스트 시간 기준의 독립 구간 응답 생성
    private func input(now: Date, five: Double? = 12, week: Double? = 3, session: String = "11111111-1111-1111-1111-111111111111") throws -> Data {
        var rates: [String: Any] = [:]
        if let five { rates["five_hour"] = ["used_percentage": five, "resets_at": now.addingTimeInterval(1000).timeIntervalSince1970] }
        if let week { rates["seven_day"] = ["used_percentage": week, "resets_at": now.addingTimeInterval(100000).timeIntervalSince1970] }
        return try JSONSerialization.data(withJSONObject: ["rate_limits": rates, "session_id": session, "context_window": ["used_percentage": 99]])
    }

    /// 빈 첫 응답의 정상값 보존·구간 독립 병합·계정 전환의 이전 값 차단 검증
    func testMergeMissingWindowsAndIdentityBoundaries() throws {
        let now = Date()
        let original = try XCTUnwrap(ClaudeQuotaSnapshot.merging(input: input(now: now), identity: "a", previous: nil, now: now))
        XCTAssertNil(try ClaudeQuotaSnapshot.merging(input: Data("{\"rate_limits\":null}".utf8), identity: "a", previous: original))
        let later = now.addingTimeInterval(10)
        let partial = try XCTUnwrap(ClaudeQuotaSnapshot.merging(input: input(now: later, five: 15, week: nil), identity: "a", previous: original, now: later))
        XCTAssertEqual(partial.windows["seven_day"], original.windows["seven_day"])
        XCTAssertEqual(partial.windows["five_hour"]?.usedPercentage, 15)
        let switched = try XCTUnwrap(ClaudeQuotaSnapshot.merging(input: input(now: later, five: nil), identity: "b", previous: partial, now: later))
        XCTAssertNil(switched.windows["five_hour"])
        XCTAssertEqual(switched.windows["seven_day"]?.usedPercentage, 3)
        let invalidFive = try ClaudeQuotaSnapshot.merging(input: input(now: now, five: -1), identity: "a", previous: nil, now: now)
        XCTAssertNil(invalidFive?.windows["five_hour"])
        XCTAssertEqual(invalidFive?.windows["seven_day"]?.usedPercentage, 3)
        XCTAssertNil(try ClaudeQuotaSnapshot.merging(input: input(now: now, five: 101, week: nil), identity: "a", previous: nil, now: now))
        XCTAssertNil(try ClaudeQuotaSnapshot.merging(input: Data("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":true,\"resets_at\":9999999999}}}".utf8), identity: "a", previous: nil))
    }

    /// 선택 폴더의 인증·실제 캡처·계정 전환·동일 세션 재귀속 차단 검증
    func testCaptureServiceAndAccountSwitch() throws {
        let (home, cli) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = AccountConfig(id: "C2", home: home, position: .left)
        XCTAssertEqual(cli.executable, home.appendingPathComponent("claude"))
        XCTAssertNil(ClaudeQuotaService(cli: cli).stateSync(for: config).primaryUsedPercent)
        let now = Date()
        try ClaudeQuotaSnapshot.capture(input: input(now: now), home: home, cli: cli, now: now)
        let state = ClaudeQuotaService(cli: cli).stateSync(for: config, now: now)
        XCTAssertEqual(state.provider, .claude)
        XCTAssertEqual(state.email, "a@example.test")
        XCTAssertEqual(state.primaryRemainingPercent, 88)
        XCTAssertEqual(state.secondaryUsedPercent, 3)
        XCTAssertEqual(try XCTUnwrap(state.primaryResetAt).timeIntervalSince1970, now.addingTimeInterval(1000).timeIntervalSince1970, accuracy: 0.001)
        try ClaudeQuotaSnapshot.capture(input: Data("{\"rate_limits\":null}".utf8), home: home, cli: cli)
        XCTAssertEqual(try ClaudeQuotaSnapshot.read(home: home)?.windows["five_hour"]?.usedPercentage, 12)
        try authentication(home: home, email: "b@example.test")
        XCTAssertNil(ClaudeQuotaService(cli: cli).stateSync(for: config).primaryUsedPercent)
        try ClaudeQuotaSnapshot.capture(input: input(now: now, five: 77), home: home, cli: cli, now: now)
        XCTAssertNil(ClaudeQuotaService(cli: cli).stateSync(for: config).primaryUsedPercent)
        try ClaudeQuotaSnapshot.capture(input: input(now: now, five: 8, session: "22222222-2222-2222-2222-222222222222"), home: home, cli: cli, now: now)
        XCTAssertEqual(ClaudeQuotaService(cli: cli).stateSync(for: config).primaryUsedPercent, 8)
        XCTAssertEqual(ClaudeQuotaService(cli: cli).stateSync(for: config, now: now.addingTimeInterval(1001)).primaryUsedPercent, 0)
        XCTAssertEqual(ClaudeQuotaService(cli: cli).stateSync(for: config, now: now.addingTimeInterval(1001)).secondaryUsedPercent, 3)
    }

    /// 리셋 전 누락 응답의 캐시 유지·리셋 후 초기화 표시·신규 구간 대체·계정 격리 검증
    func testMissingUsageWindowAcrossReset() throws {
        let (home, cli) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = AccountConfig(id: "C1", home: home, position: .left)
        let service = ClaudeQuotaService(cli: cli)
        let now = Date(timeIntervalSince1970: 1793152800)
        try ClaudeQuotaSnapshot.capture(input: input(now: now, five: 80), home: home, cli: cli, now: now)
        let original = try XCTUnwrap(ClaudeQuotaSnapshot.read(home: home)?.windows["five_hour"])
        let text = "Current session: 0% used\nCurrent week (all models): 2% used · resets Oct 31 at 7pm (Asia/Seoul)"
        for date in [now.addingTimeInterval(500), original.resetsAt] {
            let rates = try ClaudeUsageQuery.decode(text: text, now: date)
            XCTAssertNil(rates["five_hour"])
            let payload = try JSONSerialization.data(withJSONObject: ["rate_limits": rates,
                "session_id": "11111111-1111-1111-1111-111111111111"])
            try ClaudeQuotaSnapshot.capture(input: payload, home: home, cli: cli, now: date)
            XCTAssertEqual(try ClaudeQuotaSnapshot.read(home: home)?.windows["five_hour"], original)
            let state = service.stateSync(for: config, now: date)
            let expired = date >= original.resetsAt
            XCTAssertEqual(state.primaryUsedPercent, expired ? 0 : 80)
            XCTAssertEqual(state.primaryRemainingPercent, expired ? 100 : 20)
            XCTAssertEqual(state.primaryResetAt, expired ? nil : original.resetsAt)
            XCTAssertEqual(state.primaryResetObservation, expired ? .checking : .stableObserved)
            XCTAssertEqual(state.lastUpdated, expired ? date : now)
            if expired {
                XCTAssertEqual(state.errorMessage, "5시간 한도가 만료되어 새 한도를 확인 중입니다. 확인 전까지 잔여량 100%로 표시합니다.")
            }
        }
        let later = original.resetsAt.addingTimeInterval(10)
        try authentication(home: home, email: "b@example.test")
        let switched = service.stateSync(for: config, now: later)
        XCTAssertNil(switched.primaryUsedPercent)
        XCTAssertNil(switched.secondaryUsedPercent)
        try authentication(home: home, email: "a@example.test")
        try ClaudeQuotaSnapshot.capture(input: input(now: later, five: 7), home: home, cli: cli, now: later)
        XCTAssertEqual(service.stateSync(for: config, now: later).primaryUsedPercent, 7)
        XCTAssertEqual(service.stateSync(for: config, now: later).primaryResetAt, later.addingTimeInterval(1000))
        XCTAssertEqual(try ClaudeQuotaSnapshot.read(home: home)?.windows["five_hour"]?.observedAt, later)
    }

    /// 초기화 근거만 남은 표시·오래된 주간 관측 안내·미래 관측 제외 검증
    func testExpiredWindowMessagesAndObservationValidation() throws {
        let (home, cli) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = AccountConfig(id: "C1", home: home, position: .left)
        let service = ClaudeQuotaService(cli: cli)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try ClaudeQuotaSnapshot.capture(input: input(now: now), home: home, cli: cli, now: now)
        let stale = service.stateSync(for: config, now: now.addingTimeInterval(1000))
        XCTAssertEqual(stale.lastUpdated, now)
        XCTAssertTrue(stale.errorMessage?.contains("마지막으로 확인한 사용량") == true)
        let expired = service.stateSync(for: config, now: now.addingTimeInterval(100000))
        XCTAssertEqual(expired.primaryRemainingPercent, 100)
        XCTAssertNil(expired.secondaryUsedPercent)
        XCTAssertNil(expired.lastUpdated)
        XCTAssertEqual(expired.errorMessage, "5시간 한도가 만료되어 새 한도를 확인 중입니다. 확인 전까지 잔여량 100%로 표시합니다.")
        let future = service.stateSync(for: config, now: now.addingTimeInterval(-31))
        XCTAssertNil(future.primaryUsedPercent)
        XCTAssertNil(future.secondaryUsedPercent)
    }

    /// 만료된 주간 구간 제거와 미래 관측 5시간 구간의 덮어쓰기 차단 유지 검증
    func testMergePreservesExpiredFiveHourObservationGuard() throws {
        let now = Date()
        let five = ClaudeQuotaWindow(usedPercentage: 80, resetsAt: now, observedAt: now.addingTimeInterval(10))
        let previous = ClaudeQuotaSnapshot(identity: "a", windows: ["five_hour": five, "seven_day": five])
        let merged = try XCTUnwrap(ClaudeQuotaSnapshot.merging(input: input(now: now), identity: "a", previous: previous, now: now))
        XCTAssertEqual(merged.windows["five_hour"], five)
        XCTAssertEqual(merged.windows["seven_day"]?.usedPercentage, 3)
        let expired = ClaudeQuotaSnapshot(identity: "a", windows: ["five_hour": five, "seven_day": five])
        let onlyFive = try XCTUnwrap(ClaudeQuotaSnapshot.merging(input: input(now: now.addingTimeInterval(11), week: nil), identity: "a", previous: expired, now: now.addingTimeInterval(11)))
        XCTAssertNil(onlyFive.windows["seven_day"])
        XCTAssertEqual(onlyFive.windows["five_hour"]?.usedPercentage, 12)
    }

    /// 원본 명령·옵션·다른 설정 보존 및 앱 없는 shim의 출력 유지 검증
    func testInstallReinstallFailOpenAndRestore() throws {
        let (home, cli) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent("settings.json")
        let original: [String: Any] = ["statusLine": ["type": "command", "command": "/bin/cat", "padding": 4], "other": ["x": true]]
        try JSONSerialization.data(withJSONObject: original).write(to: settings)
        let missing = home.appendingPathComponent("missing app's $(echo bad)")
        try ClaudeStatusLineConnection.install(home: home, appExecutable: missing, cliExecutable: try XCTUnwrap(cli.executable))
        try ClaudeStatusLineConnection.install(home: home, appExecutable: missing, cliExecutable: try XCTUnwrap(cli.executable))
        XCTAssertTrue(ClaudeStatusLineConnection.isInstalled(home: home))
        let process = Process()
        process.executableURL = ClaudeStatusLineConnection.script(home: home)
        let source = Pipe(), output = Pipe()
        process.standardInput = source; process.standardOutput = output
        try process.run()
        let data = Data("{\"test\":\"literal $(echo bad)\"}\n\n".utf8)
        try source.fileHandleForWriting.write(contentsOf: data)
        try source.fileHandleForWriting.close()
        let captured = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(captured, data)
        try ClaudeStatusLineConnection.remove(home: home)
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? NSDictionary)
        XCTAssertEqual(restored, original as NSDictionary)
    }

    /// 원본 상태 표시줄이 없던 재설치의 재귀 체인 방지·파일 복원 검증
    func testReinstallWithoutOriginalAndUserChanges() throws {
        let (home, cli) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent("settings.json")
        for _ in 0..<2 { try ClaudeStatusLineConnection.install(home: home, appExecutable: home, cliExecutable: try XCTUnwrap(cli.executable)) }
        try ClaudeStatusLineConnection.remove(home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path))
        try ClaudeStatusLineConnection.install(home: home, appExecutable: home, cliExecutable: try XCTUnwrap(cli.executable))
        let edited = Data("{\"statusLine\":{\"type\":\"command\",\"command\":\"custom\"}}".utf8)
        try edited.write(to: settings)
        XCTAssertThrowsError(try ClaudeStatusLineConnection.remove(home: home))
        XCTAssertEqual(try Data(contentsOf: settings), edited)
        XCTAssertThrowsError(try ClaudeStatusLineConnection.install(home: home, appExecutable: home, cliExecutable: try XCTUnwrap(cli.executable)))
    }

    /// 비정상 로그인과 실행 제한시간의 안전한 실패 검증
    func testAuthenticationFailureAndTimeout() throws {
        let (home, cli) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("{\"loggedIn\":false}".utf8).write(to: home.appendingPathComponent("auth-fixture.json"))
        XCTAssertEqual(ClaudeQuotaService(cli: cli).stateSync(for: AccountConfig(id: "C1", home: home, position: .left)).status, .loginRequired)
        let script = try XCTUnwrap(cli.executable)
        try Data("#!/bin/sh\nexec /bin/sleep 10\n".utf8).write(to: script)
        XCTAssertThrowsError(try ClaudeCLI(executable: script, timeout: 0.1).authentication(home: home)) { error in
            XCTAssertEqual(error as? ClaudeQuotaError, .timeout)
        }
    }
    /// 기본 Claude 폴더의 키체인 식별자와 커스텀 폴더 환경 격리 검증
    func testDefaultHomeKeepsKeychainIdentity() {
        let user = URL(fileURLWithPath: "/test/user")
        let inherited = ["CLAUDE_CONFIG_DIR": "/wrong", "ANTHROPIC_API_KEY": "fixture"]
        let normal = ClaudeCLI.environment(home: user.appendingPathComponent(".claude"), inherited: inherited, userHome: user)
        XCTAssertNil(normal["CLAUDE_CONFIG_DIR"])
        XCTAssertNil(normal["ANTHROPIC_API_KEY"])
        XCTAssertEqual(ClaudeCLI.environment(home: user.appendingPathComponent("other"), inherited: inherited, userHome: user)["CLAUDE_CONFIG_DIR"], "/test/user/other")
    }

    /// 설치 도중 사용자 설정 변경 시 shim·manifest 롤백과 재설치 가능 검증
    func testInstallationConflictRollsBackAndRejectsOrphanShim() throws {
        let (home, cli) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent("settings.json")
        let edited = Data("{\"changed\":true}".utf8)
        XCTAssertThrowsError(try ClaudeStatusLineConnection.install(home: home, appExecutable: home, cliExecutable: try XCTUnwrap(cli.executable), willWriteSettings: {
            try edited.write(to: settings)
        }))
        XCTAssertEqual(try Data(contentsOf: settings), edited)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ClaudeQuotaSnapshot.directory(home: home).appendingPathComponent("connection.json").path))
        try ClaudeStatusLineConnection.install(home: home, appExecutable: home, cliExecutable: try XCTUnwrap(cli.executable))
        try FileManager.default.removeItem(at: ClaudeQuotaSnapshot.directory(home: home).appendingPathComponent("connection.json"))
        XCTAssertThrowsError(try ClaudeStatusLineConnection.install(home: home, appExecutable: home, cliExecutable: try XCTUnwrap(cli.executable)))
    }

    /// 이전 수집 실행파일 소실과 무관한 정상 사용량 표시 검증
    func testMissingLegacyCollectorDoesNotBlockQuotaDisplay() throws {
        let (home, cli) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = AccountConfig(id: "C1", home: home, position: .left)
        let now = Date()
        try ClaudeQuotaSnapshot.capture(input: input(now: now), home: home, cli: cli, now: now)
        try ClaudeStatusLineConnection.install(home: home, appExecutable: home.appendingPathComponent("removed-app"), cliExecutable: try XCTUnwrap(cli.executable))
        XCTAssertTrue(ClaudeStatusLineConnection.needsRepair(home: home))
        let state = ClaudeQuotaService(cli: cli).stateSync(for: config)
        XCTAssertEqual(state.primaryUsedPercent, 12)
        XCTAssertFalse(state.errorMessage?.contains("수집 실행파일") == true)
        try ClaudeStatusLineConnection.remove(home: home)
        XCTAssertFalse(ClaudeStatusLineConnection.needsRepair(home: home))
    }

    /// 할당량 응답 전에도 공식 모델 수신·변경·잘못된 식별자 거부 검증
    func testOfficialModelCaptureWithoutQuota() throws {
        let (home, cli) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let id = "33333333-3333-3333-3333-333333333333"
        let data = Data("{\"session_id\":\"\(id)\",\"model\":{\"id\":\"claude-opus-5-5\"},\"effort\":{\"level\":\"high\"}}".utf8)
        try ClaudeQuotaSnapshot.capture(input: data, home: home, cli: cli)
        XCTAssertNil(try ClaudeQuotaSnapshot.read(home: home))
        XCTAssertEqual(ClaudeSessionMetadata.read(home: home, sessionID: id)?.model, "claude-opus-5-5")
        XCTAssertEqual(ClaudeSessionMetadata.read(home: home, sessionID: id)?.effort, "high")
        let changed = Data("{\"session_id\":\"\(id)\",\"model\":{\"id\":\"claude-sonnet-5\"}}".utf8)
        try ClaudeQuotaSnapshot.capture(input: changed, home: home, cli: cli)
        XCTAssertEqual(ClaudeSessionMetadata.read(home: home, sessionID: id)?.model, "claude-sonnet-5")
        XCTAssertNil(ClaudeSessionMetadata.read(home: home, sessionID: "../unsafe"))
    }

}
