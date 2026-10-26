// 목적: 업데이트 결과·제한 보관 로그와 설치 앱 준비 신호의 영속 전달
// 이용처: 업데이트 helper와 다음 앱 실행 사이의 상태 공유
import Foundation
import Darwin

/// 사용자 전용 디렉터리에 보관하는 인증정보 없는 업데이트 상태
public enum AppUpdateState {
    /// 앱 데이터와 분리한 업데이트 상태 경로
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexQuotaMonitor/Updates", isDirectory: true)
    }

    /// 설치 시도와 새 앱 실행을 연결하는 일회성 요청
    private struct Request: Codable {
        let nonce: String
        let version: String
        let target: String
    }

    /// 실제 실행 정보가 포함된 신규 앱 준비 완료 신호
    private struct Ready: Codable {
        let nonce: String
        let version: String
        let target: String
        let executable: String
        let pid: Int32
    }

    /// helper 종료 후 다음 실행에서 소비하는 제한된 결과
    private struct Outcome: Codable {
        let status: String
        let version: String
        let code: Int
        let causeCode: Int?
        let recovery: String?
        let notificationRequested: Bool?
        let occurrenceID: String?
    }

    /// helper 알림 요청 여부와 다음 실행의 동일 오류 표시 문맥
    struct FailureNotice: Equatable {
        let message: String
        let shouldAlert: Bool
        let failure: AppOperationFailure
    }

    /// 사용자 전용 상태 경로 생성과 이전 로그의 개수·크기 제한
    static func prepareDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let logs = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            .filter { $0.lastPathComponent.hasPrefix("attempt-") && $0.pathExtension == "log" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (index, log) in logs.enumerated() {
            if index >= 4 { try? manager.removeItem(at: log); continue }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
            if (try log.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 1_048_576 {
                let handle = try FileHandle(forWritingTo: log)
                try handle.truncate(atOffset: 1_048_576)
                try handle.close()
            }
        }
    }

    /// 설치 대상·버전·nonce 요청과 작업별 로그 경로 생성
    static func begin(version: String, target: URL, directory: URL = directory) throws -> (nonce: String, log: URL) {
        try prepareDirectory(directory)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("result.json"))
        let nonce = UUID().uuidString
        var committed = false
        defer { if !committed { cancelPending(nonce: nonce, directory: directory) } }
        let request = Request(nonce: nonce, version: version, target: target.resolvingSymlinksInPath().standardizedFileURL.path)
        try write(request, to: directory.appendingPathComponent("pending.json"))
        let log = directory.appendingPathComponent("attempt-\(nonce).log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        committed = true
        return (nonce, log)
    }

    /// 종료 결과의 다음 실행 1회 전달과 로그 보존
    static func consumeFailure(directory: URL = directory) -> String? {
        takeFailure(directory: directory)?.message
    }

    /// 구버전 숫자 코드·복구 원인 및 알림 요청을 호환 해석하는 단일 소비
    static func takeFailure(directory: URL = directory) -> FailureNotice? {
        try? prepareDirectory(directory)
        let file = directory.appendingPathComponent("result.json")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4096,
              let data = try? Data(contentsOf: file), let result = try? JSONDecoder().decode(Outcome.self, from: data) else { return nil }
        let occurrence = result.occurrenceID.flatMap(UUID.init(uuidString:)) ?? UUID()
        let done = directory.appendingPathComponent("notification-\(occurrence.uuidString).done")
        let worker = directory.appendingPathComponent("notification-\(occurrence.uuidString).pid")
        let deliveryCode = (try? String(contentsOf: done, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if result.notificationRequested == true, deliveryCode == nil,
           let value = try? String(contentsOf: worker, encoding: .utf8),
           let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1, kill(pid, 0) == 0 {
            return nil
        }
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: done)
        try? FileManager.default.removeItem(at: worker)
        guard result.status == "failed" else { return nil }
        let code = AppErrorCode.updateExit(result.code)
        var message = code.message("업데이트 실패했습니다.")
        if let cause = result.causeCode, cause != result.code {
            message += "\n최초 오류코드: \(AppErrorCode.updateExit(cause).rawValue)"
        }
        switch result.recovery {
        case "restored": message += "\n구버전 앱을 복원했습니다. 다시 시도해 주세요."
        case "backupPreserved": message += "\n원본 백업을 보존했지만 앱을 복원하지 못했습니다."
        case "launchFailed": message += "\n구버전 파일은 보존했지만 앱을 실행하지 못했습니다."
        default: break
        }
        message += "\n" + code.recoverySuggestion
        message += "\n발생 식별자: \(occurrence.uuidString)"
        let failure = AppOperationFailure(code, "업데이트 실패", occurrenceID: occurrence)
        return FailureNotice(message: message, shouldAlert: deliveryCode != 0, failure: failure)
    }

    /// 복원 앱이 결과 확정 후 자체 오류 대화상자를 표시할 수 있음을 helper에 전달
    static func registerFailureObserver(directory: URL = directory) {
        let pending = directory.appendingPathComponent("pending.json")
        guard let data = try? Data(contentsOf: pending), data.count <= 4096,
              let request = try? JSONDecoder().decode(Request.self, from: data), UUID(uuidString: request.nonce) != nil,
              let executable = Bundle.main.executableURL else { return }
        let target = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard request.target == target else { return }
        try? write(Ready(nonce: request.nonce, version: AppVersion.current, target: target,
                         executable: executable.resolvingSymlinksInPath().standardizedFileURL.path,
                         pid: ProcessInfo.processInfo.processIdentifier),
                   to: directory.appendingPathComponent("observer-\(request.nonce).json"))
    }

    /// 준비 확인 실패·취소에서 현재 요청의 표식만 정리하고 다른 시도 보존
    static func cancelPending(nonce: String, directory: URL = directory) {
        let pending = directory.appendingPathComponent("pending.json")
        guard let data = try? Data(contentsOf: pending), data.count <= 4096,
              let request = try? JSONDecoder().decode(Request.self, from: data), request.nonce == nonce else { return }
        try? FileManager.default.removeItem(at: pending)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("helper-\(nonce).ready"))
    }

    /// 앱 초기화 완료 지점에서 요청된 설치 경로·실행 경로·PID·nonce 확인 후 신호 기록
    public static func publishReadiness() throws {
        guard let executable = Bundle.main.executableURL else { return }
        try publishReadiness(arguments: ProcessInfo.processInfo.arguments, bundle: Bundle.main.bundleURL,
            executable: executable, version: AppVersion.current, pid: ProcessInfo.processInfo.processIdentifier)
    }

    /// 실제 앱 정보와 설치 요청의 일치 검증 및 테스트용 경로 주입
    static func publishReadiness(arguments: [String], bundle: URL, executable: URL, version: String, pid: Int32,
                                 directory: URL = directory) throws {
        guard let index = arguments.firstIndex(of: "--codex-update-nonce"), index + 1 < arguments.count else { return }
        let nonce = arguments[index + 1]
        guard UUID(uuidString: nonce) != nil, pid > 1 else { throw AppUpdateInstallError.invalidApp }
        let pending = directory.appendingPathComponent("pending.json")
        guard (try pending.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 4097) <= 4096 else { throw AppUpdateInstallError.invalidApp }
        let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: pending))
        let target = bundle.resolvingSymlinksInPath().standardizedFileURL.path
        let path = executable.resolvingSymlinksInPath().standardizedFileURL.path
        guard request.nonce == nonce, request.version == version, request.target == target,
              path == target + "/Contents/MacOS/CodexQuotaMonitor" else { throw AppUpdateInstallError.invalidApp }
        try write(Ready(nonce: nonce, version: version, target: target, executable: path, pid: pid),
            to: directory.appendingPathComponent("ready-\(nonce).json"))
    }

    /// 0700 상위 경로 안의 원자적 상태 기록과 최종 0600 권한 보정
    private static func write<T: Encodable>(_ value: T, to file: URL) throws {
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
