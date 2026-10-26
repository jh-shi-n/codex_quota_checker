// 목적: 업데이트 상태의 사용자 전용 권한·보존 제한·준비 신호 일치 검증
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 다음 실행의 상태 소비와 앱 초기화 완료 신호 회귀 검증
final class AppUpdateStateTests: XCTestCase {
    /// 구버전 결과 호환·신규 복구 코드·알림 중복 방지와 단일 소비 검증
    func testLegacyAndRecoveryOutcomesKeepCodesAndNotificationOwnership() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try AppUpdateState.prepareDirectory(root)
        let file = root.appendingPathComponent("result.json")
        try Data(#"{"status":"failed","version":"0.1.2","code":4}"#.utf8).write(to: file)
        let legacy = try XCTUnwrap(AppUpdateState.takeFailure(directory: root))
        XCTAssertTrue(legacy.message.contains("UPD-004"))
        XCTAssertTrue(legacy.shouldAlert)
        XCTAssertNil(AppUpdateState.takeFailure(directory: root))
        let id = UUID().uuidString
        let result: [String: Any] = ["status": "failed", "version": "0.1.3", "code": 12,
                                   "causeCode": 4, "recovery": "launchFailed",
                                   "notificationRequested": true, "occurrenceID": id]
        try JSONSerialization.data(withJSONObject: result).write(to: file)
        try Data("0\n".utf8).write(to: root.appendingPathComponent("notification-\(id).done"))
        let notice = try XCTUnwrap(AppUpdateState.takeFailure(directory: root))
        XCTAssertTrue(notice.message.contains("UPD-012"))
        XCTAssertTrue(notice.message.contains("UPD-004"))
        XCTAssertTrue(notice.message.contains(id))
        XCTAssertFalse(notice.shouldAlert)
        XCTAssertNil(AppUpdateState.takeFailure(directory: root))
    }

    /// 외부 알림 처리 중 결과 보존 및 알림 실패 이후 앱 대화상자 복귀 검증
    func testNotificationFailureCannotSuppressNextAppAlert() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try AppUpdateState.prepareDirectory(root)
        let id = UUID().uuidString
        let file = root.appendingPathComponent("result.json")
        let result: [String: Any] = ["status": "failed", "version": "0.1.3", "code": 12,
                                   "notificationRequested": true, "occurrenceID": id]
        try JSONSerialization.data(withJSONObject: result).write(to: file)
        try Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
            .write(to: root.appendingPathComponent("notification-\(id).pid"))
        XCTAssertNil(AppUpdateState.takeFailure(directory: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try Data("1\n".utf8).write(to: root.appendingPathComponent("notification-\(id).done"))
        let failure = try XCTUnwrap(AppUpdateState.takeFailure(directory: root))
        XCTAssertTrue(failure.shouldAlert)
        XCTAssertTrue(failure.message.contains("UPD-012"))
    }
    /// nonce·버전·설치 경로·실행 경로 일치 조건과 0600 신호 기록 검증
    func testReadinessRequiresMatchingInstallRequest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("CodexQuotaChecker.app")
        let state = root.appendingPathComponent("state")
        let request = try AppUpdateState.begin(version: "0.1.1", target: target, directory: state)
        let executable = target.appendingPathComponent("Contents/MacOS/CodexQuotaMonitor")
        let arguments = [executable.path, "--codex-update-nonce", request.nonce]
        XCTAssertThrowsError(try AppUpdateState.publishReadiness(arguments: arguments, bundle: target,
            executable: executable, version: "0.1.0", pid: 123, directory: state))
        XCTAssertThrowsError(try AppUpdateState.publishReadiness(arguments: arguments, bundle: target,
            executable: root.appendingPathComponent("wrong"), version: "0.1.1", pid: 123, directory: state))
        XCTAssertThrowsError(try AppUpdateState.publishReadiness(arguments: [executable.path, "--codex-update-nonce", UUID().uuidString],
            bundle: target, executable: executable, version: "0.1.1", pid: 123, directory: state))
        try AppUpdateState.publishReadiness(arguments: arguments, bundle: target, executable: executable,
            version: "0.1.1", pid: 123, directory: state)
        let file = state.appendingPathComponent("ready-\(request.nonce).json")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: state.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        let ready = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(ready["pid"] as? Int, 123)
    }

    /// 신규 설치 시도 이후 로그 최대 5개 및 파일별 1MB 보관 검증
    func testLogRetentionLimitsCountAndSize() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try AppUpdateState.prepareDirectory(root)
        for index in 0..<8 {
            try Data(repeating: 1, count: 1_100_000).write(to: root.appendingPathComponent("attempt-\(index).log"))
        }
        _ = try AppUpdateState.begin(version: "0.1.1", target: URL(fileURLWithPath: "/Applications/CodexQuotaChecker.app"), directory: root)
        let logs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension == "log" }
        XCTAssertEqual(logs.count, 5)
        for log in logs {
            XCTAssertLessThanOrEqual(try log.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max, 1_048_576)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? Int, 0o600)
        }
    }
}
