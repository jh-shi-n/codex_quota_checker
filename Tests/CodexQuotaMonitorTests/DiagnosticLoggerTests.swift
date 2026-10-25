// 목적: 진단 JSONL 보관·검증·실패 격리 테스트
// 이용처: CodexQuotaMonitorTests XCTest 대상
// 사용방법: 보관 정책 또는 저장소 동작 변경 시 관련 테스트 실행
// 실행 예: swift test --filter DiagnosticLoggerTests

import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// - 목적: 진단 로그 보관·검증·실패 격리 확인
final class DiagnosticLoggerTests: XCTestCase {
    /// - 목적: 7일 보존 경계의 등호 포함 및 이전 기록 제거 확인
    func testRetentionKeepsExactBoundaryAndRemovesOlderRecords() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = LockedClock(base)
        XCTAssertEqual(DiagnosticLogger.defaultMaximumBytes, 10_000_000)
        XCTAssertEqual(DiagnosticLogger.defaultMaximumAge, 604_800)
        let logger = DiagnosticLogger(directory: directory, now: { clock.read() }, osLogEnabled: false, timerEnabled: false)

        clock.set(base.addingTimeInterval(-604_801))
        logger.record(.probeRequested, operationID: UUID(), fields: [.reason: .identifier("older")])
        clock.set(base.addingTimeInterval(-604_800))
        logger.record(.probeStarted, operationID: UUID(), fields: [.reason: .identifier("boundary")])
        logger.flush()

        clock.set(base)
        logger.maintain()
        logger.flush()

        let reasons = try jsonLines(in: directory).compactMap { ($0["fields"] as? [String: Any])?["reason"] as? [String: Any] }
            .compactMap { $0["value"] as? String }
        XCTAssertEqual(reasons, ["boundary"])
    }

    /// - 목적: 시각 역전과 재시작에도 같은 현지 날짜 파일 재사용 확인
    func testSameLocalDayReusesOneFileForOutOfOrderTimestampsAndRestart() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let times = [
            try date("2027-04-01T18:00:00Z"),
            try date("2027-04-01T09:00:00Z"),
            try date("2027-04-01T22:00:00Z")
        ]
        let clock = LockedClock(times[0])
        let first = DiagnosticLogger(directory: directory, now: { clock.read() }, timeZone: timeZone, osLogEnabled: false, timerEnabled: false)
        for (index, timestamp) in times.enumerated() {
            clock.set(timestamp)
            first.record(.probeFinished, fields: [.reason: .identifier("event-\(index)")])
        }
        first.flush()

        let restarted = DiagnosticLogger(directory: directory, now: { clock.read() }, timeZone: timeZone, osLogEnabled: false, timerEnabled: false)
        clock.set(try date("2027-04-01T02:00:00Z"))
        restarted.record(.probeFinished, fields: [.reason: .identifier("after-restart")])
        restarted.flush()

        let files = try managedFiles(in: directory)
        XCTAssertEqual(files.map(\.lastPathComponent), ["diagnostic-2027-04-01.jsonl"])
        XCTAssertEqual(try jsonLines(in: directory).count, 4)
    }

    /// - 목적: 현지 자정 파일명과 UTC 이벤트 시각의 독립성 확인
    func testLocalMidnightSelectsLocalDateAndLeavesTimestampInUTC() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 10 * 60 * 60))
        let timestamp = try date("2027-04-01T16:05:00Z")
        let logger = DiagnosticLogger(directory: directory, now: { timestamp }, timeZone: timeZone, osLogEnabled: false, timerEnabled: false)

        logger.record(.appStarted)
        logger.flush()

        let files = try managedFiles(in: directory)
        XCTAssertEqual(files.map(\.lastPathComponent), ["diagnostic-2027-04-02.jsonl"])
        let row = try XCTUnwrap(try jsonLines(in: directory).first)
        let eventTimestamp = try XCTUnwrap(row["timestamp"] as? String)
        XCTAssertTrue(eventTimestamp.hasPrefix("2027-04-01T16:05:00"))
        XCTAssertTrue(eventTimestamp.hasSuffix("Z"))
    }

    /// - 목적: 혼합 날짜 레거시 이관의 중복 제거·실패 재시도·식별자 보존 확인
    func testLegacyMigrationDeduplicatesMixedDaysAndRetriesAfterBlockedTarget() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let firstTime = try date("2027-04-01T12:00:00Z")
        let secondTime = try date("2027-04-02T12:00:00Z")
        let now = secondTime.addingTimeInterval(3_600)
        let firstRow = try seedRow(timestamp: firstTime, reason: "first", operationID: "operation-first")
        let existingRow = try seedRow(timestamp: firstTime.addingTimeInterval(60), reason: "existing", operationID: "operation-existing")
        let secondRow = try seedRow(timestamp: secondTime, reason: "second", operationID: "operation-second")
        let firstTarget = directory.appendingPathComponent(dailyFileName(for: firstTime, timeZone: timeZone))
        let blockedTarget = directory.appendingPathComponent(dailyFileName(for: secondTime, timeZone: timeZone))
        let external = directory.deletingLastPathComponent().appendingPathComponent("daily-migration-target-\(UUID().uuidString)")
        let firstLegacy = directory.appendingPathComponent(legacyFileName(for: firstTime))
        let secondLegacy = directory.appendingPathComponent(legacyFileName(for: secondTime))
        try writeRows([firstRow, existingRow], to: firstTarget)
        try writeRows([firstRow], to: firstLegacy)
        try writeRows([secondRow], to: secondLegacy)
        XCTAssertTrue(FileManager.default.createFile(atPath: external.path, contents: Data("protected".utf8)))
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createSymbolicLink(at: blockedTarget, withDestinationURL: external)

        let firstLogger = DiagnosticLogger(directory: directory, now: { now }, timeZone: timeZone, osLogEnabled: false, timerEnabled: false)
        firstLogger.maintain()
        firstLogger.flush()

        XCTAssertEqual(try legacyFiles(in: directory).count, 2)
        XCTAssertEqual(try Data(contentsOf: external), Data("protected".utf8))
        try FileManager.default.removeItem(at: blockedTarget)

        let restarted = DiagnosticLogger(directory: directory, now: { now }, timeZone: timeZone, osLogEnabled: false, timerEnabled: false)
        restarted.flush()

        XCTAssertTrue(try legacyFiles(in: directory).isEmpty)
        let files = try managedFiles(in: directory)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), Set([
            dailyFileName(for: firstTime, timeZone: timeZone),
            dailyFileName(for: secondTime, timeZone: timeZone)
        ]))
        let rows = try jsonLines(in: directory)
        XCTAssertEqual(rows.count, 3)
        let reasons = rows.compactMap { row -> String? in
            guard let fields = row["fields"] as? [String: Any],
                  let reason = fields["reason"] as? [String: Any] else { return nil }
            return reason["value"] as? String
        }
        XCTAssertEqual(Set(reasons), Set(["first", "existing", "second"]))
        XCTAssertTrue(rows.contains { $0["operationID"] as? String == "operation-second" })
        XCTAssertTrue(rows.allSatisfy { $0["sessionID"] as? String == "migration-session" })
    }

    /// - 목적: 용량 상한 적용과 최신 행 보존 확인
    func testSameDayCapacityEvictsOldestRowsAndPreservesNewest() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = LockedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let logger = DiagnosticLogger(directory: directory, now: { clock.read() }, maxBytes: 900, maxAge: 10_000, osLogEnabled: false, timerEnabled: false)

        for index in 0..<30 {
            logger.record(.probeFinished, operationID: UUID(), fields: [.reason: .identifier("record-\(index)")])
            clock.set(clock.read().addingTimeInterval(1))
        }
        logger.flush()

        let files = try managedFiles(in: directory)
        let totalBytes = try files.reduce(0) { partial, url in
            partial + (try Data(contentsOf: url)).count
        }
        let reasons = try jsonLines(in: directory).compactMap { ($0["fields"] as? [String: Any])?["reason"] as? [String: Any] }
            .compactMap { $0["value"] as? String }
        XCTAssertLessThanOrEqual(totalBytes, 900)
        XCTAssertEqual(files.count, 1)
        XCTAssertFalse(reasons.contains("record-0"))
        XCTAssertTrue(reasons.contains("record-29"))
        XCTAssertLessThan(reasons.count, 30)
    }

    /// - 목적: 용량 초과 시 같은 날짜 파일 안에서 오래된 행만 제거 확인
    func testCapacityTrimsOldRowsWithinSingleDailyFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let file = directory.appendingPathComponent(dailyFileName(for: base, timeZone: TimeZone(secondsFromGMT: 0)!))
        try writeSeedDailyFile(to: file, start: base, count: 900, prefix: "row")
        let logger = DiagnosticLogger(
            directory: directory,
            now: { base.addingTimeInterval(900) },
            maxBytes: 80_000,
            maxAge: 10_000,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            osLogEnabled: false,
            timerEnabled: false
        )

        logger.flush()

        let files = try managedFiles(in: directory)
        let totalBytes = try files.reduce(0) { $0 + (try Data(contentsOf: $1)).count }
        let reasons = try jsonLines(in: directory).compactMap { ($0["fields"] as? [String: Any])?["reason"] as? [String: Any] }
            .compactMap { $0["value"] as? String }
        XCTAssertLessThanOrEqual(totalBytes, 80_000)
        XCTAssertEqual(files.count, 1)
        XCTAssertFalse(reasons.contains("row-0"))
        XCTAssertTrue(reasons.contains("newest"))
        XCTAssertGreaterThan(reasons.count, 0)
        XCTAssertLessThan(reasons.count, 900)
    }

    /// - 목적: 재시작 시 만료·잘못된·미완성 행 정리 확인
    func testRestartRemovesExpiredMalformedAndTruncatedRows() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = LockedClock(base)
        let firstLogger = DiagnosticLogger(directory: directory, now: { clock.read() }, maxAge: 100, osLogEnabled: false, timerEnabled: false)
        firstLogger.record(.probeRequested, fields: [.reason: .identifier("expired")])
        clock.set(base.addingTimeInterval(200))
        firstLogger.record(.probeFinished, fields: [.reason: .identifier("recent")])
        firstLogger.flush()

        let activeFile = try XCTUnwrap(try managedFiles(in: directory).first)
        let handle = try FileHandle(forWritingTo: activeFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{broken-json}\n{\"timestamp\":\"truncated".utf8))
        try handle.close()

        let restarted = DiagnosticLogger(directory: directory, now: { clock.read() }, maxAge: 100, osLogEnabled: false, timerEnabled: false)
        restarted.flush()

        let reasons = try jsonLines(in: directory).compactMap { ($0["fields"] as? [String: Any])?["reason"] as? [String: Any] }
            .compactMap { $0["value"] as? String }
        XCTAssertEqual(reasons, ["recent"])
        XCTAssertTrue(try managedFiles(in: directory).allSatisfy { (try Data(contentsOf: $0).last) == 0x0A })
    }

    /// - 목적: 동시 호출의 행 완전성·누락 방지 확인
    func testConcurrentWritesRemainCompleteAndUnique() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = DiagnosticLogger(directory: directory, osLogEnabled: false, timerEnabled: false)
        let group = DispatchGroup()
        let writers = DispatchQueue(label: "DiagnosticLoggerTests.writers", attributes: .concurrent)
        let count = 240

        for index in 0..<count {
            group.enter()
            writers.async {
                logger.record(.processFinished, operationID: UUID(), fields: [.generation: .integer(index)])
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        logger.flush()

        let rows = try jsonLines(in: directory)
        let generations = rows.compactMap { ($0["fields"] as? [String: Any])?["generation"] as? [String: Any] }
            .compactMap { $0["value"] as? Int }
        XCTAssertEqual(rows.count, count)
        XCTAssertEqual(Set(generations).count, count)
        XCTAssertEqual(try managedFiles(in: directory).count, 1)
    }

    /// - 목적: 제어 식별자 검증과 민감 문자열 제외 확인
    func testValidationAndPrivacyExcludeUncontrolledStrings() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = DiagnosticLogger(directory: directory, osLogEnabled: false, timerEnabled: false)

        logger.record(
            .quotaResultApplied,
            operationID: nil,
            accountID: "user@example.com",
            fields: [
                .model: .identifier("gpt-5.6"),
                .reason: .identifier("/Users/private/account"),
                .failure: .identifier("authentication failed: token secret"),
                .requestID: .identifier(String(repeating: "x", count: 81)),
                .generation: .integer(4),
                .applied: .boolean(true),
                .primaryResetBefore: .timestamp(Date(timeIntervalSince1970: .infinity))
            ]
        )
        logger.flush()

        let data = try Data(contentsOf: XCTUnwrap(try managedFiles(in: directory).first))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let row = try XCTUnwrap(try jsonLines(in: directory).first)
        let fields = try XCTUnwrap(row["fields"] as? [String: Any])
        XCTAssertFalse(text.contains("user@example.com"))
        XCTAssertFalse(text.contains("/Users/private/account"))
        XCTAssertFalse(text.contains("authentication failed"))
        XCTAssertFalse(text.contains(String(repeating: "x", count: 81)))
        XCTAssertNil(row["accountID"])
        XCTAssertNil(row["operationID"])
        XCTAssertNotNil(fields["model"])
        XCTAssertNotNil(fields["generation"])
        XCTAssertNotNil(fields["applied"])
        XCTAssertNil(fields["reason"])
        XCTAssertNil(fields["failure"])
        XCTAssertNil(fields["requestID"])
        XCTAssertNil(fields["primaryResetBefore"])
        XCTAssertEqual(row["level"] as? String, DiagnosticLevel.notice.rawValue)
    }

    /// 같은 프로세스의 유지보수 경합이 파일 잠금 대기 한도를 넘어도 기록 보존 검증
    func testSameProcessContentionDoesNotDropQueuedRecord() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let first = DiagnosticLogger(directory: directory, now: {
            entered.signal()
            _ = release.wait(timeout: .now() + 3)
            return Date()
        }, osLogEnabled: false, timerEnabled: false)
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        let second = DiagnosticLogger(directory: directory, osLogEnabled: false, timerEnabled: false)
        second.record(.probeFinished, fields: [.reason: .identifier("after-contention")])
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(700)) { release.signal() }
        XCTAssertTrue(second.flush(timeout: 5))
        XCTAssertTrue(first.flush(timeout: 5))
        let reasons = try jsonLines(in: directory).compactMap { ($0["fields"] as? [String: Any])?["reason"] as? [String: Any] }
            .compactMap { $0["value"] as? String }
        XCTAssertEqual(reasons, ["after-contention"])
    }

    /// - 목적: 같은 디렉터리를 쓰는 두 인스턴스의 기록 충돌 방지 확인
    func testMultipleInstancesSerializeWritesThroughProcessLock() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = DiagnosticLogger(directory: directory, osLogEnabled: false, timerEnabled: false)
        let second = DiagnosticLogger(directory: directory, osLogEnabled: false, timerEnabled: false)
        let group = DispatchGroup()
        let writers = DispatchQueue(label: "DiagnosticLoggerTests.process-lock", attributes: .concurrent)
        let perLogger = 50

        for index in 0..<perLogger {
            group.enter()
            writers.async {
                first.record(.probeFinished, fields: [.reason: .identifier("first-\(index)")])
                group.leave()
            }
            group.enter()
            writers.async {
                second.record(.probeFinished, fields: [.reason: .identifier("second-\(index)")])
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        first.flush()
        second.flush()

        let reasons = try jsonLines(in: directory).compactMap { ($0["fields"] as? [String: Any])?["reason"] as? [String: Any] }
            .compactMap { $0["value"] as? String }
        XCTAssertEqual(reasons.count, perLogger * 2)
        XCTAssertEqual(Set(reasons).count, perLogger * 2)
        XCTAssertEqual(try managedFiles(in: directory).count, 1)
    }

    /// - 목적: 심볼릭 링크 대상 파일의 외부 변경 방지 확인
    func testSymlinkDailyFileIsIgnoredWithoutChangingItsTarget() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let external = directory.deletingLastPathComponent().appendingPathComponent("diagnostic-external-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: external) }
        let original = Data("external-data".utf8)
        XCTAssertTrue(FileManager.default.createFile(atPath: external.path, contents: original))
        let timestamp = try date("2027-01-15T12:00:00Z")
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let symlink = directory.appendingPathComponent(dailyFileName(for: timestamp, timeZone: timeZone))
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: external)
        let logger = DiagnosticLogger(directory: directory, now: { timestamp }, timeZone: timeZone, osLogEnabled: false, timerEnabled: false)

        logger.record(.appStarted)
        logger.flush()

        XCTAssertEqual(try Data(contentsOf: external), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlink.path))
    }

    /// - 목적: 고아 원자 교체 임시 파일만 정리하고 외부 파일 보존 확인
    func testMaintenanceRemovesOnlyOwnedOrphanTemporaryFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let orphan = directory.appendingPathComponent(".diagnostic-tmp-\(UUID().uuidString.lowercased())")
        let malformed = directory.appendingPathComponent(".diagnostic-tmp-not-a-uuid")
        let unrelated = directory.appendingPathComponent("unrelated.txt")
        let symlink = directory.appendingPathComponent(".diagnostic-tmp-\(UUID().uuidString.lowercased())")
        let external = directory.deletingLastPathComponent().appendingPathComponent("diagnostic-temp-target-\(UUID().uuidString)")
        XCTAssertTrue(FileManager.default.createFile(atPath: orphan.path, contents: Data("orphan".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: malformed.path, contents: Data("foreign".utf8)))
        let unrelatedContents = Data("preserve".utf8)
        XCTAssertTrue(FileManager.default.createFile(atPath: unrelated.path, contents: unrelatedContents))
        XCTAssertTrue(FileManager.default.createFile(atPath: external.path, contents: Data("target".utf8)))
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: external)
        let logger = DiagnosticLogger(directory: directory, osLogEnabled: false, timerEnabled: false)

        logger.maintain()
        logger.flush()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformed.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), unrelatedContents)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path), external.path)
    }

    /// - 목적: 디렉터리·로그 파일의 전용 권한 확인
    func testStoragePermissionsAreRestricted() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = DiagnosticLogger(directory: directory, osLogEnabled: false, timerEnabled: false)
        logger.record(.appStarted)
        logger.flush()

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let directoryMode = try XCTUnwrap(directoryAttributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        for file in try managedFiles(in: directory) {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let fileMode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
            XCTAssertEqual(fileMode & 0o777, 0o600)
        }
    }

    /// - 목적: 저장 경로 오류의 호출자 전파 방지와 대상 파일 보존 확인
    func testWriteFailureDoesNotChangeApplicationCallOrUnrelatedFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("not-a-directory")
        let original = Data("preserve".utf8)
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: original))
        let logger = DiagnosticLogger(directory: file, osLogEnabled: false, timerEnabled: false)

        logger.record(.probeFinished, fields: [.reason: .identifier("still-returned")])
        logger.maintain()
        logger.flush()

        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    /// - 목적: 저장 테스트용 전용 임시 디렉터리 생성
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-logger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// - 목적: 디렉터리의 현지 날짜 JSONL 파일 경로 목록 반환
    private func managedFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { Self.isDailyFileName($0.lastPathComponent) }
    }

    /// - 목적: 디렉터리의 이전 UUID JSONL 파일 경로 목록 반환
    private func legacyFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { Self.isLegacyFileName($0.lastPathComponent) }
    }

    /// - 목적: 테스트 시각의 현지 날짜 파일명 생성
    private func dailyFileName(for date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return "diagnostic-\(formatter.string(from: date)).jsonl"
    }

    /// - 목적: 테스트용 ISO 8601 시각 변환
    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }

    /// - 목적: 테스트용 이전 UUID 파일명 생성
    private func legacyFileName(for date: Date) -> String {
        let milliseconds = Int64(date.timeIntervalSince1970 * 1_000)
        return String(format: "diagnostic-%013lld-%@.jsonl", milliseconds, UUID().uuidString.lowercased())
    }

    /// - 목적: 유효한 날짜 파일명 확인
    private static func isDailyFileName(_ name: String) -> Bool {
        name.hasPrefix("diagnostic-") && name.hasSuffix(".jsonl") &&
            name.count == "diagnostic-".count + 10 + ".jsonl".count
    }

    /// - 목적: 기존 UUID 파일명 확인
    private static func isLegacyFileName(_ name: String) -> Bool {
        guard name.hasPrefix("diagnostic-"), name.hasSuffix(".jsonl"), !isDailyFileName(name) else { return false }
        let body = String(name.dropFirst("diagnostic-".count).dropLast(".jsonl".count))
        guard body.count > 37 else { return false }
        let uuidStart = body.index(body.endIndex, offsetBy: -36)
        let separator = body.index(before: uuidStart)
        let uuid = String(body[uuidStart...])
        return body[separator] == "-" && Int64(String(body[..<separator])) != nil && UUID(uuidString: uuid) != nil
    }

    /// - 목적: 검증 가능한 JSONL 행으로 일별 테스트 파일 생성
    private func writeSeedDailyFile(to url: URL, start: Date, count: Int, prefix: String) throws {
        var data = Data()
        for index in 0..<count {
            let reason = index == count - 1 ? "newest" : "\(prefix)-\(index)"
            data.append(try seedRow(timestamp: start.addingTimeInterval(TimeInterval(index)), reason: reason))
            data.append(0x0A)
        }
        try writeBytes(data, to: url)
    }

    /// - 목적: 검증 가능한 JSONL 행 생성
    private func seedRow(timestamp: Date, reason: String, operationID: String? = nil) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var row: [String: Any] = [
            "timestamp": formatter.string(from: timestamp),
            "sessionID": "migration-session",
            "event": DiagnosticEvent.probeFinished.rawValue,
            "level": DiagnosticLevel.notice.rawValue,
            "fields": ["reason": ["type": "identifier", "value": reason]]
        ]
        if let operationID { row["operationID"] = operationID }
        return try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    }

    /// - 목적: JSONL 행을 줄바꿈과 전용 권한으로 파일에 기록
    private func writeRows(_ rows: [Data], to url: URL) throws {
        var data = Data()
        for row in rows {
            data.append(row)
            data.append(0x0A)
        }
        try writeBytes(data, to: url)
    }

    /// - 목적: 파일 생성 후 전용 권한 적용
    private func writeBytes(_ data: Data, to url: URL) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: data))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// - 목적: 날짜별 완전 JSON 행 디코딩
    private func jsonLines(in directory: URL) throws -> [[String: Any]] {
        try managedFiles(in: directory).flatMap { file in
            let data = try Data(contentsOf: file)
            return data.split(separator: 0x0A).compactMap { row in
                (try? JSONSerialization.jsonObject(with: Data(row))) as? [String: Any]
            }
        }
    }
}

/// - 목적: 비동기 로거 테스트용 동기화 시계
private final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    /// - 목적: 기준 시각 초기화
    init(_ date: Date) {
        self.date = date
    }

    /// - 목적: 잠금 아래 현재 시각 반환
    func read() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    /// - 목적: 잠금 아래 기준 시각 변경
    func set(_ date: Date) {
        lock.lock()
        self.date = date
        lock.unlock()
    }
}
