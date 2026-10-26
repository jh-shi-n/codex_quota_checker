// 목적: 배포 파일 검증과 실제 앱 번들 교체·원상복구 검증
// 이용처: 사용자 앱·계정 데이터와 분리된 앱 내 업데이트 회귀 테스트
// 사용방법: swift test --filter AppUpdateInstallerTests
import CryptoKit
import XCTest
@testable import CodexQuotaMonitorKit

/// 임시 서명 앱과 실제 보조 스크립트의 파일 작업 검증
final class AppUpdateInstallerTests: XCTestCase {
    /// 정상 SHA-256 허용과 파일 변조·크기 불일치·검증 정보 누락 차단 검증
    func testDownloadRequiresCorrectSizeAndDigest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("update-fixture".utf8)
        let archive = root.appendingPathComponent("update.zip")
        try data.write(to: archive)
        let digest = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let url = URL(string: "https://github.com/jh-shi-n/codex_quota_checker/releases/download/v0.1.0/update.zip")!
        let asset = AppReleaseAsset(name: "update.zip", url: url, size: Int64(data.count), digest: digest)
        XCTAssertNoThrow(try AppUpdateInstaller.validateDownload(archive, asset: asset))
        XCTAssertThrowsError(try AppUpdateInstaller.validateDownload(archive,
            asset: AppReleaseAsset(name: "update.zip", url: url, size: 1, digest: digest)))
        XCTAssertThrowsError(try AppUpdateInstaller.validateDownload(archive,
            asset: AppReleaseAsset(name: "update.zip", url: url, size: Int64(data.count), digest: nil)))
        try Data("changed-fixture".utf8).write(to: archive)
        XCTAssertThrowsError(try AppUpdateInstaller.validateDownload(archive, asset: asset))
    }

    /// 배포 ZIP 압축 해제와 버전 상승·서명 검증 검증
    func testSignedArchiveIsPreparedAndTamperedAppIsRejected() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let archive = fixture.root.appendingPathComponent("update.zip")
        try fixture.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", fixture.candidate.path, archive.path])
        let destination = fixture.root.appendingPathComponent("CodexQuotaChecker-update-unpack")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let prepared = try AppUpdateInstaller.unpack(archive, directory: destination, version: "0.1.0", installedVersion: "0.0.9")
        XCTAssertEqual(try fixture.version(prepared.app), "0.1.0")
        XCTAssertThrowsError(try AppUpdateInstaller.validateApp(prepared.app, expectedVersion: "0.2.0", installedVersion: "0.0.9"))
        XCTAssertThrowsError(try AppUpdateInstaller.validateApp(prepared.app, expectedVersion: "0.1.0", installedVersion: "0.1.0"))
        try Data("tampered".utf8).write(to: prepared.app.appendingPathComponent("Contents/MacOS/CodexQuotaMonitor"))
        XCTAssertThrowsError(try AppUpdateInstaller.validateApp(prepared.app, expectedVersion: "0.1.0", installedVersion: "0.0.9"))
    }

    /// 실제 교체 성공 뒤 신규 앱 유지·구버전 제거·사용자 데이터 보존 검증
    func testHelperReplacesAppAndCleansBackup() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let status = try fixture.executeHelper(failOpen: false)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(try fixture.version(fixture.target), "0.1.0")
        XCTAssertEqual(try String(contentsOf: fixture.userData, encoding: .utf8), "preserve-user-data")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspace.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.target.deletingLastPathComponent().path)
            .contains { $0.hasPrefix(".CodexQuotaChecker") })
    }

    /// 설치 후 실행 실패에서 원본 앱·데이터 복원 및 스테이징 정리 검증
    func testHelperRestoresOriginalAppWhenRelaunchFails() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let status = try fixture.executeHelper(failOpen: true)
        XCTAssertNotEqual(status, 0)
        XCTAssertEqual(try fixture.version(fixture.target), "0.0.9")
        XCTAssertEqual(try String(contentsOf: fixture.userData, encoding: .utf8), "preserve-user-data")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.target.deletingLastPathComponent().path)
            .contains { $0.hasPrefix(".CodexQuotaChecker") })
    }

    /// open 성공 응답 이후 실제 프로세스가 없으면 기존 앱 복원 검증
    func testHelperRestoresWhenUpdatedProcessNeverAppears() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        XCTAssertNotEqual(try fixture.executeHelper(failOpen: false, showProcess: false), 0)
        XCTAssertEqual(try fixture.version(fixture.target), "0.0.9")
    }

    /// 기존 앱이 종료되지 않으면 원본 교체 없이 종료 검증
    func testHelperDoesNotReplaceRunningApp() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        XCTAssertNotEqual(try fixture.executeHelper(failOpen: false, oldProcessAlive: true), 0)
        XCTAssertEqual(try fixture.version(fixture.target), "0.0.9")
    }

    /// 번들 밖 파일을 가리키는 심볼릭 링크 차단 검증
    func testExternalBundleSymlinkIsRejected() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createSymbolicLink(at: fixture.candidate.appendingPathComponent("Contents/outside"), withDestinationURL: fixture.userData)
        XCTAssertThrowsError(try AppUpdateInstaller.validateApp(fixture.candidate, expectedVersion: "0.1.0", installedVersion: "0.0.9")) { error in
            guard case AppUpdateInstallError.invalidApp = error else { return XCTFail("번들 외부 링크 차단 실패") }
        }
    }
}

/// 시스템 앱 실행만 대체하고 파일 이동·서명 검증을 그대로 수행하는 fixture
private final class InstallerFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let workspace: URL
    let candidate: URL
    let target: URL
    let userData: URL

    /// 사용자 앱 밖의 원본·후보 앱과 보존 대상 데이터 생성
    init() throws {
        let directory = root
        workspace = directory.appendingPathComponent("CodexQuotaChecker-update-fixture")
        candidate = workspace.appendingPathComponent("extracted/CodexQuotaChecker.app")
        target = directory.appendingPathComponent("Applications/CodexQuotaChecker.app")
        userData = directory.appendingPathComponent("account-data.txt")
        try makeApp(target, version: "0.0.9")
        try makeApp(candidate, version: "0.1.0")
        try Data("preserve-user-data".utf8).write(to: userData)
    }

    /// 실제 codesign 검증이 가능한 최소 Mach-O 앱 생성
    private func makeApp(_ app: URL, version: String) throws {
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"),
            to: contents.appendingPathComponent("MacOS/CodexQuotaMonitor"))
        let info = ["CFBundleIdentifier": "com.example.codexquotamonitor", "CFBundleExecutable": "CodexQuotaMonitor",
            "CFBundleName": "CodexQuotaChecker", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version,
            "CFBundleVersion": version == "0.0.9" ? "9" : "10"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", "--timestamp=none", app.path])
    }

    /// 실제 보조 스크립트를 소싱하되 open·프로세스 목록·대기만 테스트 경계로 교체
    func executeHelper(failOpen: Bool, showProcess: Bool = true, oldProcessAlive: Bool = false) throws -> Int32 {
        let helper = try XCTUnwrap(AppUpdateInstaller.helperURL)
        let script = """
        function /usr/bin/open() { return \(failOpen ? 1 : 0); }
        function /bin/ps() { \(showProcess ? "builtin print -r -- \"$$ $target_app/Contents/MacOS/CodexQuotaMonitor\"" : "return 0"); }
        function /bin/sleep() { return 0; }
        \(oldProcessAlive ? "function kill() { return 0; }" : "")
        source "$1" "${@:2}"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", script, "test-helper", helper.path, "2147483647", target.path,
            candidate.path, workspace.path, "0.1.0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// 앱 버전의 실제 파일 상태 조회
    func version(_ app: URL) throws -> String {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        return try XCTUnwrap(info["CFBundleShortVersionString"] as? String)
    }

    /// 테스트용 시스템 도구 실행 및 실패 전달
    func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
    }

    /// 임시 앱·사용자 데이터 fixture 제거
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
