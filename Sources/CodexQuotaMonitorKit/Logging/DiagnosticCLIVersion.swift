// 목적: 앱 실행 시 설치 CLI 버전의 제한된 진단 기록
// 이용처: 빌드·CLI 호환성에 따른 간헐 오류 구분
// 사용방법: DiagnosticLogContext.recordCLIVersion() 1회 호출
// 실행 예시: 앱 시작 이벤트 이후 비동기 버전 확인
import Darwin
import Foundation

extension DiagnosticLogContext {
    /// 원문 출력·경로 저장 없이 최대 2초 동안 CLI 버전 확인
    public static func recordCLIVersion() {
        let logger = Self.logger ?? .shared
        DispatchQueue.global(qos: .utility).async {
            guard let executable = CodexLocator().locate() else {
                logger.record(.cliDetected, fields: [.reason: .identifier("executable_unavailable")])
                return
            }
            let process = Process()
            let output = Pipe()
            let capture = DiagnosticVersionCapture()
            let ended = DispatchSemaphore(value: 0)
            process.executableURL = executable
            process.arguments = ["--version"]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = CodexProcess.childPath(inheritedPath: environment["PATH"], executable: executable)
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in ended.signal() }
            output.fileHandleForReading.readabilityHandler = { capture.append($0.availableData) }
            defer {
                output.fileHandleForReading.readabilityHandler = nil
                try? output.fileHandleForReading.close()
                try? output.fileHandleForWriting.close()
                process.terminationHandler = nil
            }
            do { try process.run() }
            catch {
                logger.record(.cliDetected, level: .error, fields: [.reason: .identifier("launch_failure")])
                return
            }
            try? output.fileHandleForWriting.close()
            if ended.wait(timeout: .now() + 2) == .timedOut {
                if process.isRunning {
                    process.terminate()
                    if ended.wait(timeout: .now() + 0.25) == .timedOut, process.isRunning {
                        _ = kill(process.processIdentifier, SIGKILL)
                        _ = ended.wait(timeout: .now() + 0.25)
                    }
                }
                logger.record(.cliDetected, level: .error, fields: [.reason: .identifier("timeout")])
                return
            }
            output.fileHandleForReading.readabilityHandler = nil
            let descriptor = output.fileHandleForReading.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            if flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
               let remaining = try? output.fileHandleForReading.read(upToCount: 512) {
                capture.append(remaining)
            }
            let parts = capture.value.split(whereSeparator: { $0.isWhitespace })
            guard process.terminationStatus == 0, parts.count == 2, parts[0] == "codex-cli",
                  parts[1].first?.isNumber == true else {
                logger.record(.cliDetected, level: .error, fields: [.reason: .identifier("unrecognized_version")])
                return
            }
            logger.record(.cliDetected, fields: [.cliVersion: .identifier(String(parts[1]))])
        }
    }
}

/// 콜백·종료 후 수집 사이의 최대 512바이트 버퍼 보호
private final class DiagnosticVersionCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    /// 추가 출력의 초과 부분을 보관하지 않는 수집
    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk.prefix(max(0, 512 - data.count)))
    }

    /// 버전 파싱용 제한 문자열 반환
    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
