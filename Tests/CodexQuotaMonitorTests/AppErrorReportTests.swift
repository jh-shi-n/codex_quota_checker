// 목적: 오류 정보 복사에서 다른 작업·원문 비밀정보·전체 일자 로그 제외 검증
// 이용처: 동일 발생 건·작업 진단 추출의 개인정보 경계 회귀 테스트
// 사용방법: swift test --filter AppErrorReportTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 공유용 진단의 정확한 연결과 크기 제한 검증
final class AppErrorReportTests: XCTestCase {
    /// 같은 날·계정의 다른 작업을 제외하고 UUID가 연결된 기록만 복사 검증
    func testReportIncludesOnlyExactOccurrenceOrOperation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = DiagnosticLogger(directory: root, osLogEnabled: false, timerEnabled: false)
        let occurrence = UUID(), operation = UUID(), unrelated = UUID()
        logger.record(.quotaRefreshStarted, operationID: operation, accountID: "C1")
        logger.record(.appFailure, operationID: operation, fields: [.requestID: .identifier(occurrence.uuidString)])
        logger.record(.probeStarted, operationID: unrelated, accountID: "C1", fields: [.requestID: .identifier(unrelated.uuidString)])
        let failure = AppOperationFailure(.cliTimeout, "요청 시간이 초과되었습니다.", occurrenceID: occurrence, operationID: operation)
        let report = await AppErrorReport.make(message: failure.userMessage, failure: failure, logger: logger)
        XCTAssertTrue(report.contains("CLI-002"))
        XCTAssertTrue(report.contains("quotaRefreshStarted"))
        XCTAssertTrue(report.contains(occurrence.uuidString))
        XCTAssertFalse(report.contains("probeStarted"))
        XCTAssertFalse(report.lowercased().contains(unrelated.uuidString.lowercased()))
    }

    /// 로컬 파일의 알 수 없는 추가 필드가 복사 결과로 유출되지 않는지 검증
    func testExportReencodesOnlyAllowlistedFields() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = DiagnosticLogger(directory: root, osLogEnabled: false, timerEnabled: false)
        let id = UUID()
        logger.record(.appFailure, fields: [.requestID: .identifier(id.uuidString)])
        XCTAssertTrue(logger.flush())
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.pathExtension == "jsonl" })
        let line = try XCTUnwrap(Data(contentsOf: file).split(separator: 10).first)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
        object["authentication"] = "private-authentication-secret"
        var fields = try XCTUnwrap(object["fields"] as? [String: [String: Any]])
        fields["requestID"]?["rawError"] = "private-authentication-secret"
        object["fields"] = fields
        var bytes = try JSONSerialization.data(withJSONObject: object)
        bytes.append(10)
        try bytes.write(to: file)
        let records = await logger.relatedRecords(occurrenceID: id)
        XCTAssertEqual(records.count, 1)
        XCTAssertFalse(records.joined().contains("private-authentication-secret"))
        XCTAssertFalse(records.joined().contains("authentication"))
    }

    /// 관련 기록만 존재하더라도 공유 행 수·바이트 상한 적용 검증
    func testRelatedRecordsAreBoundedAndMissingContextDoesNotExportToday() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = DiagnosticLogger(directory: root, osLogEnabled: false, timerEnabled: false)
        let id = UUID()
        for index in 0..<80 {
            logger.record(.appFailure, fields: [.requestID: .identifier(id.uuidString), .attempt: .integer(index)])
        }
        let rows = await logger.relatedRecords(occurrenceID: id)
        XCTAssertEqual(rows.count, 50)
        XCTAssertLessThanOrEqual(rows.joined(separator: "\n").utf8.count, 65_536)
        let report = await AppErrorReport.make(message: "오류 안내", logger: logger)
        XCTAssertTrue(report.contains("관련 진단 없음"))
        XCTAssertFalse(report.contains("appFailure"))
    }
}
