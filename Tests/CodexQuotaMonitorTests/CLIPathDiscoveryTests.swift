// 목적: 버전 관리자·로그인 셸 PATH의 CLI 탐색과 자식 프로세스 Node 경로 보정 검증
// 이용처: GUI 실행 환경의 CLI 미탐지 회귀 테스트
// 사용방법: swift test --filter CLIPathDiscoveryTests
// 실행 예시: swift test --filter CLIPathDiscoveryTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

final class CLIPathDiscoveryTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: home)
    }

    /// 실행 권한을 가진 임시 파일 생성
    @discardableResult
    private func executable(_ relativePath: String, content: String = "#!/bin/sh\n") throws -> URL {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: url.path)
        return url
    }

    /// 외부 경로를 배제한 Codex 탐색기
    private func codexLocator(loginShellPath: @escaping @Sendable () -> String? = { nil }) -> CodexLocator {
        CodexLocator(pathEnvironment: nil, candidatePaths: [], homeDirectory: home, loginShellPath: loginShellPath)
    }

    func testCodexLocatorFindsNewestNvmVersionNumerically() throws {
        try executable(".nvm/versions/node/v9.11.2/bin/codex")
        let newest = try executable(".nvm/versions/node/v22.3.0/bin/codex")
        XCTAssertEqual(codexLocator().locate(), newest)
    }

    func testCodexLocatorPrefersNvmDefaultAlias() throws {
        let selected = try executable(".nvm/versions/node/v20.1.0/bin/codex")
        try executable(".nvm/versions/node/v22.3.0/bin/codex")
        try executable(".nvm/versions/node/v2.0.0/bin/codex")
        let alias = home.appendingPathComponent(".nvm/alias/default")
        try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("20\n".utf8).write(to: alias)
        XCTAssertEqual(codexLocator().locate(), selected)
    }

    func testCodexLocatorFallsBackToOtherNvmVersionWhenAliasVersionLacksCLI() throws {
        try executable(".nvm/versions/node/v20.1.0/bin/node")
        let installed = try executable(".nvm/versions/node/v18.0.0/bin/codex")
        let alias = home.appendingPathComponent(".nvm/alias/default")
        try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("v20.1.0\n".utf8).write(to: alias)
        XCTAssertEqual(codexLocator().locate(), installed)
    }

    func testCodexLocatorFindsOtherManagerDirectories() throws {
        for path in [
            ".volta/bin/codex",
            ".asdf/shims/codex",
            ".npm-global/bin/codex",
            ".local/share/fnm/aliases/default/bin/codex",
            "Library/Application Support/fnm/aliases/default/bin/codex",
        ] {
            let url = try executable(path)
            XCTAssertEqual(codexLocator().locate(), url, path)
            try FileManager.default.removeItem(at: url)
        }
    }

    func testCodexLocatorUsesLoginShellPathOnlyAsLastResort() throws {
        let shellDirectory = home.appendingPathComponent("custom/bin")
        let shellCodex = try executable("custom/bin/codex")
        let shellPath = shellDirectory.path
        XCTAssertEqual(codexLocator(loginShellPath: { shellPath }).locate(), shellCodex)

        let nvmCodex = try executable(".nvm/versions/node/v22.3.0/bin/codex")
        XCTAssertEqual(codexLocator(loginShellPath: {
            XCTFail("앞선 탐색 성공 시 로그인 셸 실행 금지")
            return shellPath
        }).locate(), nvmCodex)
    }

    func testInheritedPathTakesPrecedenceOverManagers() throws {
        try executable(".nvm/versions/node/v22.3.0/bin/codex")
        let inherited = try executable("inherited/codex")
        let locator = CodexLocator(
            pathEnvironment: inherited.deletingLastPathComponent().path,
            candidatePaths: [],
            homeDirectory: home,
            loginShellPath: { nil }
        )
        XCTAssertEqual(locator.locate(), inherited)
    }

    func testClaudeLocateFindsNvmInstall() throws {
        let installed = try executable(".nvm/versions/node/v22.3.0/bin/claude")
        XCTAssertEqual(
            ClaudeCLI.locate(environment: [:], homeDirectory: home, candidatePaths: [], loginShellPath: { nil }),
            installed
        )
    }

    func testChildPathFollowsSymlinkChainToNodeDirectory() throws {
        let bin = home.appendingPathComponent(".nvm/versions/node/v22.3.0/bin")
        try executable(".nvm/versions/node/v22.3.0/bin/node")
        let script = try executable(".nvm/versions/node/v22.3.0/lib/node_modules/@openai/codex/bin/codex.js")
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("codex").path, withDestinationPath: "../lib/node_modules/@openai/codex/bin/codex.js")
        let links = home.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        let link = links.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bin.appendingPathComponent("codex"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script.path))

        let path = CodexProcess.childPath(inheritedPath: "/usr/bin:/bin", executable: link, homeDirectory: home)
            .split(separator: ":").map(String.init)
        XCTAssertEqual(path.first, links.path)
        XCTAssertTrue(path.contains(bin.path), path.joined(separator: ":"))
    }

    func testChildPathFindsNodeForDirectLinkToPackageScript() throws {
        let bin = home.appendingPathComponent(".nvm/versions/node/v22.3.0/bin")
        try executable(".nvm/versions/node/v22.3.0/bin/node")
        let script = try executable(".nvm/versions/node/v22.3.0/lib/node_modules/@openai/codex/bin/codex.js")
        let links = home.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        let link = links.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: script)

        let path = CodexProcess.childPath(inheritedPath: "/usr/bin:/bin", executable: link, homeDirectory: home)
            .split(separator: ":").map(String.init)
        XCTAssertTrue(path.contains(bin.path), path.joined(separator: ":"))
    }

    func testChildPathAppendsManagerNodeWhenNoNodeIsReachable() throws {
        let cli = try executable(".npm-global/bin/codex")
        let nvmBin = home.appendingPathComponent(".nvm/versions/node/v22.3.0/bin")
        try executable(".nvm/versions/node/v22.3.0/bin/node")

        let reachable = CodexProcess.childPath(
            inheritedPath: "/usr/bin:/bin", executable: cli, homeDirectory: home, systemDirectories: []
        ).split(separator: ":").map(String.init)
        XCTAssertEqual(reachable.last, nvmBin.path)
    }

    func testChildPathDoesNotAppendManagerWhenNodeIsAlreadyReachable() throws {
        let cli = try executable(".nvm/versions/node/v22.3.0/bin/codex")
        try executable(".nvm/versions/node/v22.3.0/bin/node")
        try executable(".nvm/versions/node/v18.0.0/bin/node")

        let path = CodexProcess.childPath(inheritedPath: "/usr/bin:/bin", executable: cli, homeDirectory: home)
        XCTAssertFalse(path.contains("v18.0.0"), path)
    }

    func testClaudeAuthenticationFindsNodeNextToExecutable() throws {
        let json = #"{"loggedIn":true,"authMethod":"claude.ai","email":"fixture@example.com","subscriptionType":"max"}"#
        let claude = try executable("nvm-bin/claude", content: "#!/usr/bin/env node\n")
        try executable("nvm-bin/node", content: "#!/bin/sh\nprintf '%s' '\(json)'\n")

        let authentication = try ClaudeCLI(executable: claude, timeout: 5).authentication(home: home)
        XCTAssertEqual(authentication.email, "fixture@example.com")
    }

    func testReadLoginShellPathExtractsValueBetweenMarkersFromNoisyShell() throws {
        // 실제 셸 설정 파일의 출력이 앞뒤에 섞이는 상황 재현
        let shell = try executable("shell", content: """
        #!/bin/sh
        echo 'welcome banner'
        eval "$2"
        echo 'goodbye'
        """)
        let value = CLIPathDiscovery.readLoginShellPath(
            shell: shell, environment: ["PATH": "/fixture/one:/fixture/two"], timeout: 2
        )
        XCTAssertEqual(value, "/fixture/one:/fixture/two")
    }

    func testReadLoginShellPathReturnsNilWhenShellHangs() throws {
        let shell = try executable("shell", content: "#!/bin/sh\n/bin/sleep 30\n")
        let start = Date()
        XCTAssertNil(CLIPathDiscovery.readLoginShellPath(shell: shell, environment: [:], timeout: 0.2))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testReadLoginShellPathReturnsNilWithoutMarkers() throws {
        let shell = try executable("shell", content: "#!/bin/sh\necho '/not/a/marked/path'\n")
        XCTAssertNil(CLIPathDiscovery.readLoginShellPath(shell: shell, environment: [:], timeout: 2))
    }
}
