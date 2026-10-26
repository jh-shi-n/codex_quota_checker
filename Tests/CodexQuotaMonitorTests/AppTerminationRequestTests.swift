// 목적: 실제 AppKit 프로세스에서 업데이트 종료와 비동기 정리의 진행 보장
// 이용처: Task 내부 terminateLater 교착 및 취소된 종료 요청 회귀 검사
// 사용방법: swift test --filter AppTerminationRequestTests
import Foundation
import XCTest

/// 제품 종료 요청 소스를 직접 연결한 별도 앱의 종료 검증
final class AppTerminationRequestTests: XCTestCase {
    /// 정상 요청의 정리 완료와 취소 조건의 종료 억제를 실제 AppKit으로 검증
    func testTaskTerminationCompletesAsyncCleanupAndChecksCancellation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("TerminationProbe.app")
        let contents = app.appendingPathComponent("Contents")
        let binary = contents.appendingPathComponent("MacOS/TerminationProbe")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "com.shinjh.termination-regression", "CFBundleExecutable": "TerminationProbe",
                    "CFBundlePackageType": "APPL", "LSUIElement": "1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let source = root.appendingPathComponent("main.swift")
        let code = #"""
        import AppKit
        @MainActor func record(_ value: String) { FileHandle.standardOutput.write(Data((value + "\n").utf8)) }
        @MainActor final class Delegate: NSObject, NSApplicationDelegate {
            var calls = 0
            func applicationDidFinishLaunching(_ notification: Notification) {
                let cancelled = CommandLine.arguments.last == "cancelled"
                Task { @MainActor in
                    await Task.yield()
                    AppTerminationRequest.schedule(when: { !cancelled })
                    if cancelled {
                        RunLoop.main.perform(inModes: [.common, .default]) {
                            MainActor.assumeIsolated {
                                guard self.calls == 0 else { exit(20) }
                                record("cancelled request skipped")
                                NSApplication.shared.terminate(nil)
                            }
                        }
                    }
                    record("request task returned")
                }
            }
            func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
                calls += 1
                record("should terminate")
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(20))
                    record("cleanup completed")
                    sender.reply(toApplicationShouldTerminate: true)
                }
                return .terminateLater
            }
            func applicationWillTerminate(_ notification: Notification) { record("will terminate") }
        }
        @main enum Probe {
            @MainActor static func main() {
                let application = NSApplication.shared
                application.setActivationPolicy(.accessory)
                let delegate = Delegate()
                application.delegate = delegate
                withExtendedLifetime(delegate) { application.run() }
            }
        }
        """#
        try code.write(to: source, atomically: true, encoding: .utf8)
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let implementation = project.appendingPathComponent("Sources/CodexQuotaMonitorKit/Service/AppTerminationRequest.swift")
        let compiled = try execute("/usr/bin/swiftc", ["-parse-as-library", implementation.path, source.path, "-o", binary.path],
                                   root: root, name: "compile", timeout: 60)
        XCTAssertEqual(compiled.code, 0, compiled.output)
        guard compiled.code == 0 else { return }
        for mode in ["normal", "cancelled"] {
            let result = try execute(binary.path, [mode], root: root, name: mode, timeout: 8)
            XCTAssertEqual(result.code, 0, result.output)
            XCTAssertTrue(result.output.contains("request task returned"), result.output)
            XCTAssertTrue(result.output.contains("cleanup completed"), result.output)
            XCTAssertTrue(result.output.contains("will terminate"), result.output)
            if mode == "cancelled" { XCTAssertTrue(result.output.contains("cancelled request skipped"), result.output) }
        }
    }

    /// 검증 프로세스의 출력 저장과 상한 시간·종료 상태 확인
    private func execute(_ executable: String, _ arguments: [String], root: URL, name: String,
                         timeout: TimeInterval) throws -> (code: Int32, output: String) {
        let output = root.appendingPathComponent(name + ".log")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            XCTFail("프로세스 종료 시간 초과: \(name)")
        }
        process.waitUntilExit()
        return (process.terminationStatus, try String(contentsOf: output, encoding: .utf8))
    }
}
