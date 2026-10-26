// 목적: 배포 파일 검증과 실제 앱 번들 교체·원상복구 검증
// 이용처: 사용자 앱·계정 데이터와 분리된 앱 내 업데이트 회귀 테스트
// 사용방법: swift test --filter AppUpdateInstallerTests
import CryptoKit
import Darwin
import XCTest
@testable import CodexQuotaMonitorKit

/// 임시 서명 앱과 실제 보조 스크립트의 파일 작업 검증
final class AppUpdateInstallerTests: XCTestCase {
    /// helper가 즉시 실패하면 앱 종료 단계로 넘어가지 않고 준비 상태 정리 검증
    func testRejectedHelperHandshakeKeepsOriginalAppAndClearsPending() async throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let invalid = fixture.root.appendingPathComponent("invalid-helper.sh")
        try Data("#!/bin/zsh\nexit 2\n".utf8).write(to: invalid)
        let state = fixture.root.appendingPathComponent("HandshakeState")
        let prepared = PreparedAppUpdate(directory: fixture.workspace, app: fixture.candidate, version: "0.1.0")
        do {
            try await AppUpdateInstaller.launchPrepared(prepared, target: fixture.target, helper: invalid, stateDirectory: state)
            XCTFail("준비 실패 helper 승인")
        } catch let failure as AppOperationFailure {
            XCTAssertEqual(failure.code, .updateHelperStart)
        }
        XCTAssertEqual(try fixture.version(fixture.target), "0.0.9")
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("pending.json").path))
    }
    /// 개발 번들이 있어도 설치 앱의 helper 선택 및 누락 시 혼용 차단 검증
    func testInstalledHelperTakesPriorityAndNeverFallsBackToBuildResources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundle = root.appendingPathComponent("CodexQuotaMonitor_CodexQuotaMonitorKit.bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = bundle.appendingPathComponent("app-update.sh")
        try Data("installed helper".utf8).write(to: helper)
        let selected = try XCTUnwrap(AppUpdateInstaller.helperResourceURL(installedResources: root, isApplication: true))
        XCTAssertEqual(selected.standardizedFileURL, helper.standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), "installed helper")
        let missing = root.appendingPathComponent("missing")
        XCTAssertNil(AppUpdateInstaller.helperResourceURL(installedResources: missing, isApplication: true))
        XCTAssertNil(AppUpdateInstaller.helperResourceURL(installedResources: nil, isApplication: true))
        XCTAssertNotNil(AppUpdateInstaller.helperResourceURL(installedResources: missing, isApplication: false))
    }

    /// 같은 metadata SHA로 바꾼 ZIP도 고정 서명키 없이는 설치 불가 검증
    func testIndependentReleaseSignatureRejectsTamperingAndOtherKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("release.zip")
        let bytes = Data("signed release fixture".utf8)
        try bytes.write(to: archive)
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: Data(SHA256.hash(data: bytes)))
        XCTAssertNoThrow(try AppUpdateInstaller.verifyReleaseSignature(archive, signature: signature, publicKey: key.publicKey.rawRepresentation))
        XCTAssertThrowsError(try AppUpdateInstaller.verifyReleaseSignature(archive, signature: signature))
        try Data("attacker archive".utf8).write(to: archive)
        XCTAssertThrowsError(try AppUpdateInstaller.verifyReleaseSignature(archive, signature: signature, publicKey: key.publicKey.rawRepresentation))
    }

    /// 실제 자식 실행의 제한시간과 취소 시 그룹 종료 검증
    func testValidationSubprocessHasDeadlineAndCancellation() async throws {
        let started = Date()
        XCTAssertThrowsError(try AppUpdateInstaller.run("/bin/sh", ["-c", "trap '' TERM; sleep 60"], timeout: 0.05))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        let task = Task.detached { try AppUpdateInstaller.run("/bin/sleep", ["60"]) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do { _ = try await task.value; XCTFail("취소 미전파") }
        catch is CancellationError { }
    }

    /// 실제 ditto ZIP의 선언 총량·항목수·local/central 불일치 사전 차단 검증
    func testArchiveLimitsAndLocalHeaderMismatchAreRejected() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let archive = fixture.root.appendingPathComponent("update.zip")
        try fixture.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", fixture.candidate.path, archive.path])
        let destination = fixture.root.appendingPathComponent("limit-extracted")
        XCTAssertThrowsError(try BoundedZipExtractor.extract(archive, to: destination, maximumBytes: 10))
        XCTAssertThrowsError(try BoundedZipExtractor.extract(archive, to: destination, maximumCount: 1))
        var bytes = try Data(contentsOf: archive)
        bytes[8] = bytes[8] == 0 ? 8 : 0
        try bytes.write(to: archive)
        XCTAssertThrowsError(try BoundedZipExtractor.extract(archive, to: destination))
    }

    /// ZIP 내 심볼릭 링크의 추출 전 거부 검증
    func testArchiveSymlinkIsRejectedBeforeExtraction() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createSymbolicLink(at: fixture.candidate.appendingPathComponent("Contents/link"), withDestinationURL: fixture.userData)
        let archive = fixture.root.appendingPathComponent("link.zip")
        try fixture.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", fixture.candidate.path, archive.path])
        let destination = fixture.root.appendingPathComponent("no-extraction")
        XCTAssertThrowsError(try BoundedZipExtractor.extract(archive, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// Content-Length가 없는 응답의 실제 수신 초과·불완전 전송 차단 검증
    func testStreamingDownloadRejectsOversizedAndIncompleteBodies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateDownloadURLProtocol.self]
        for (index, count) in [80, 10, 64].enumerated() {
            UpdateDownloadURLProtocol.payload = Data(repeating: 1, count: count)
            let session = URLSession(configuration: configuration)
            let destination = root.appendingPathComponent("download-\(index)")
            do {
                try await AppUpdateInstaller.download(URL(string: "https://update.test/release")!, to: destination,
                    maximumBytes: 64, expectedSize: 64, session: session)
                XCTAssertEqual(count, 64)
            } catch {
                XCTAssertNotEqual(count, 64)
            }
            let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            XCTAssertLessThanOrEqual(size, 64)
        }
    }

    /// 패키징 스크립트 산출 ZIP·독립 서명·리소스 번들·codesign 통합 검증
    func testPackagedReleaseArchiveWhenProvided() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEX_UPDATE_ARCHIVE_SMOKE"] else { throw XCTSkip("배포 ZIP 경로 미지정") }
        let archive = URL(fileURLWithPath: path)
        let signature = try Data(contentsOf: URL(fileURLWithPath: path + ".sig"))
        try AppUpdateInstaller.verifyReleaseSignature(archive, signature: signature)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodexQuotaChecker-update-smoke-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let version = environment["CODEX_UPDATE_ARCHIVE_VERSION"] ?? "0.1.0"
        let prepared = try AppUpdateInstaller.unpack(archive, directory: directory, version: version, installedVersion: "0.0.0")
        let resources = prepared.app.appendingPathComponent("Contents/Resources/CodexQuotaMonitor_CodexQuotaMonitorKit.bundle")
        XCTAssertTrue(FileManager.default.fileExists(atPath: resources.path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: prepared.app.appendingPathComponent("Contents/MacOS/CodexQuotaMonitor").path))
        let helper = try XCTUnwrap(AppUpdateInstaller.helperResourceURL(
            installedResources: prepared.app.appendingPathComponent("Contents/Resources"), isApplication: true))
        XCTAssertEqual(helper.standardizedFileURL, resources.appendingPathComponent("app-update.sh").standardizedFileURL)
    }

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

    /// ps와 준비 신호를 대체하지 않은 실제 native 프로세스의 교체 승인 검증
    func testHelperAcceptsReadinessFromRealNativeProcess() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        XCTAssertEqual(try fixture.executeHelperWithRealProcess(), 0)
        XCTAssertEqual(try fixture.version(fixture.target), "0.1.0")
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

    /// 신규 실행의 첫 오류 이후 재시도로 업데이트 유지 검증
    func testTransientLaunchFailureRetriesBeforeRollback() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        XCTAssertEqual(try fixture.executeHelper(failOpen: false, failuresBeforeSuccess: 1), 0)
        XCTAssertEqual(try fixture.version(fixture.target), "0.1.0")
        let counter = fixture.root.appendingPathComponent("UpdateState/open-updated.count")
        XCTAssertEqual(try String(contentsOf: counter, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "2")
    }

    /// 복원 앱 실행도 재시도하고 실패 단계·최초 원인·알림 보존 검증
    func testFailedRecoveryReportsBothCodesAndExternalAlert() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        XCTAssertEqual(try fixture.executeHelper(failOpen: true), 12)
        XCTAssertEqual(try fixture.version(fixture.target), "0.0.9")
        let state = fixture.root.appendingPathComponent("UpdateState")
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: state.appendingPathComponent("result.json"))) as? [String: Any])
        XCTAssertEqual(result["code"] as? Int, 12)
        XCTAssertEqual(result["causeCode"] as? Int, 4)
        let message = try XCTUnwrap(AppUpdateState.consumeFailure(directory: state))
        XCTAssertTrue(message.contains("UPD-012"))
        XCTAssertTrue(message.contains("UPD-004"))
        let notification = try String(contentsOf: state.appendingPathComponent("notification.txt"), encoding: .utf8)
        XCTAssertTrue(notification.contains("업데이트 실패했습니다"))
        XCTAssertTrue(notification.contains("UPD-012"))
    }

    /// 복원 실행 요청 성공만으로 미실행 상태를 성공 처리하지 않는지 검증
    func testRecoveryRequiresActualProcessAfterAcceptedOpen() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        XCTAssertEqual(try fixture.executeHelper(failOpen: false, showProcess: false), 13)
        XCTAssertEqual(try fixture.version(fixture.target), "0.0.9")
        let message = try XCTUnwrap(AppUpdateState.consumeFailure(directory: fixture.root.appendingPathComponent("UpdateState")))
        XCTAssertTrue(message.contains("UPD-013"))
        XCTAssertTrue(message.contains("UPD-005"))
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

    /// 프로세스가 보여도 앱 준비 신호가 없으면 원본 복원과 다음 실행 실패 전달 검증
    func testHelperRestoresWhenReadinessNeverArrivesAndRetainsResult() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        XCTAssertNotEqual(try fixture.executeHelper(failOpen: false, emitReadiness: false), 0)
        XCTAssertEqual(try fixture.version(fixture.target), "0.0.9")
        let directory = fixture.root.appendingPathComponent("UpdateState")
        XCTAssertNotNil(AppUpdateState.consumeFailure(directory: directory))
        XCTAssertNil(AppUpdateState.consumeFailure(directory: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspace.path))
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
    func executeHelper(failOpen: Bool, showProcess: Bool = true, oldProcessAlive: Bool = false, emitReadiness: Bool = true, failuresBeforeSuccess: Int = 0, rollbackFailures: Int = 0) throws -> Int32 {
        let helper = try XCTUnwrap(AppUpdateInstaller.helperURL)
        let stateDirectory = root.appendingPathComponent("UpdateState")
        let state = try AppUpdateState.begin(version: "0.1.0", target: target, directory: stateDirectory)
        let readiness: [String: Any] = ["nonce": state.nonce, "version": "0.1.0", "target": target.path,
            "executable": target.appendingPathComponent("Contents/MacOS/CodexQuotaMonitor").path, "pid": 2147483646]
        try JSONSerialization.data(withJSONObject: readiness).write(to: stateDirectory.appendingPathComponent("template.json"))
        let script = """
        function /usr/bin/osascript() { print -r -- "$*" > "$state_directory/notification.txt"; }
        function /usr/bin/open() {
            local kind="restored"
            [[ "$*" != *--codex-update-nonce* ]] || kind="updated"
            local counter="$state_directory/open-$kind.count"
            local count=0
            [[ ! -f "$counter" ]] || count="$(<"$counter")"
            (( count += 1 ))
            print -r -- "$count" > "$counter"
            \(failOpen ? "return 1" : "")
            if [[ "$kind" == "updated" && "$count" -le \(failuresBeforeSuccess) ]]; then return 1; fi
            if [[ "$kind" == "restored" && "$count" -le \(rollbackFailures) ]]; then return 1; fi
            print -r -- "$kind" > "$state_directory/started"
            if [[ "$kind" == "updated" && "\(emitReadiness ? "yes" : "no")" == "yes" ]]; then
                /bin/cp "$state_directory/template.json" "$ready"
            fi
            return 0
        }
        function /bin/ps() {
            [[ -f "$state_directory/started" ]] || return 0
            \(showProcess ? "if [[ \"$1\" == \"-p\" ]]; then builtin print -r -- \"$executable\"; else builtin print -r -- \"2147483646 $executable\"; fi" : "return 0")
        }
        function /bin/sleep() { command /bin/sleep 0.001; }
        function kill() {
            \(oldProcessAlive ? "return 0" : "if [[ \"$2\" == \"2147483646\" ]]; then if [[ \"$1\" != \"-0\" ]]; then /bin/rm -f \"$state_directory/started\"; fi; return 0; fi; builtin kill \"$@\"")
        }
        source "$1" "${@:2}"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", script, "test-helper", helper.path, "2147483647", target.path,
            candidate.path, workspace.path, "0.1.0", stateDirectory.path, state.nonce]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let notification = stateDirectory.appendingPathComponent("notification-\(state.nonce).done")
        if FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent("notification-\(state.nonce).pid").path) {
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: notification.path) { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        return process.terminationStatus
    }

    /// GUI 실행 진입점만 실제 native fixture 실행으로 연결하는 통합 검증
    func executeHelperWithRealProcess() throws -> Int32 {
        let source = root.appendingPathComponent("readiness.c")
        let code = #"""
        #include <stdio.h>
        #include <unistd.h>
        #include <limits.h>
        int main(int argc, char **argv) {
            if (argc != 4) return 2;
            char ready[PATH_MAX], marker[PATH_MAX];
            snprintf(ready, sizeof(ready), "%s/ready-%s.json", argv[2], argv[1]);
            snprintf(marker, sizeof(marker), "%s/child.pid", argv[2]);
            FILE *pidfile = fopen(marker, "w");
            fprintf(pidfile, "%d", getpid()); fclose(pidfile);
            FILE *file = fopen(ready, "w");
            fprintf(file, "{\"nonce\":\"%s\",\"version\":\"0.1.0\",\"target\":\"%s\",\"executable\":\"%s/Contents/MacOS/CodexQuotaMonitor\",\"pid\":%d}", argv[1], argv[3], argv[3], getpid());
            fclose(file);
            sleep(60);
            return 0;
        }
        """#
        try code.write(to: source, atomically: true, encoding: .utf8)
        let executable = candidate.appendingPathComponent("Contents/MacOS/CodexQuotaMonitor")
        try run("/usr/bin/clang", [source.path, "-o", executable.path])
        try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", "--timestamp=none", candidate.path])
        let stateDirectory = root.appendingPathComponent("RealUpdateState")
        let request = try AppUpdateState.begin(version: "0.1.0", target: target, directory: stateDirectory)
        defer {
            if let text = try? String(contentsOf: stateDirectory.appendingPathComponent("child.pid"), encoding: .utf8), let pid = Int32(text) {
                _ = kill(pid, SIGKILL)
            }
        }
        let script = """
        function /usr/bin/open() {
            if [[ "$1" == "-n" ]]; then
                "$target_app/Contents/MacOS/CodexQuotaMonitor" "$nonce" "$state_directory" "$target_app" &
            fi
            return 0
        }
        source "$1" "${@:2}"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", script, "real-helper", try XCTUnwrap(AppUpdateInstaller.helperURL).path,
            "2147483647", target.path, candidate.path, workspace.path, "0.1.0", stateDirectory.path, request.nonce]
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

/// 무제한 Content-Length 응답을 재현하는 다운로드 전용 경계
private final class UpdateDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var payload = Data()

    /// 테스트 전용 HTTPS 요청 처리 허용
    override class func canInit(with request: URLRequest) -> Bool { true }
    /// 요청 URL의 원형 유지
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    /// 길이 헤더 없는 body 전달
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    /// 동기 fixture 완료 이후 추가 정리 없음
    override func stopLoading() { }
}
