// 목적: wrapper 하위 프로세스 종료와 상속 파이프의 제한시간 검증
import Darwin
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 실제 프로세스를 통한 종료 회귀 검증
final class ProcessGroupTerminationTests: XCTestCase {
    /// TERM 무시 자식의 그룹 강제 종료와 파이프 회수 검증
    func testTerminatesSignalIgnoringDescendantAfterWrapperExits() throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; /bin/sh -c 'trap \"\" TERM; while :; do sleep 1; done' & echo $!; wait"]
        process.standardOutput = pipe
        try process.run()
        try pipe.fileHandleForWriting.close()
        let group = try XCTUnwrap(ProcessGroupTermination.group(of: process))
        let childOutput = pipe.fileHandleForReading.availableData
        let child = try XCTUnwrap(Int32(String(decoding: childOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        _ = kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        XCTAssertEqual(kill(child, 0), 0)
        let started = Date()
        ProcessGroupTermination.terminate(process, group: group, until: Date().addingTimeInterval(0.7))
        var output = Data()
        ProcessGroupTermination.drain(pipe.fileHandleForReading, limit: 1024) { output.append($0) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertFalse(process.isRunning)
        let reapDeadline = Date().addingTimeInterval(0.5)
        while kill(child, 0) == 0 && Date() < reapDeadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(kill(child, 0), -1)
        try pipe.fileHandleForReading.close()
    }

    /// EOF 없는 파이프도 즉시 읽기 종료 보장
    func testDrainDoesNotWaitForInheritedWriter() throws {
        let pipe = Pipe()
        let started = Date()
        ProcessGroupTermination.drain(pipe.fileHandleForReading, limit: 1024) { _ in XCTFail("Unexpected data") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        try pipe.fileHandleForWriting.close()
        try pipe.fileHandleForReading.close()
    }
}
