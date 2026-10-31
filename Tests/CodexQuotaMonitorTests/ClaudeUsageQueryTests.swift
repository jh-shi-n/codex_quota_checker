// 목적: 공식 /usage 응답·제한·시간대 및 실계정 신규 조회 검증
// 이용처: Claude 수동·주기 새로고침
// 사용방법: swift test --filter ClaudeUsageQueryTests
// 실행 예시: CLAUDE_QUERY_LIVE_HOME=~/.claude swift test --filter ClaudeUsageQueryTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 텍스트 응답의 방어적 파싱과 실제 조회 검증
final class ClaudeUsageQueryTests: XCTestCase {
    /// 5시간·주간 구간과 시차·분 생략 표시의 독립 변환 검증
    func testOfficialTextAndResetTimeZones() throws {
        let now = Date(timeIntervalSince1970: 1793152800)
        let text = "Current session: 13% used · resets Oct 28 at 3:10pm (Asia/Seoul)\nCurrent week (all models): 2% used · resets Oct 31 at 7pm (Asia/Seoul)"
        let rates = try ClaudeUsageQuery.decode(text: text, now: now)
        XCTAssertEqual(rates["five_hour"]?["used_percentage"], 13)
        XCTAssertEqual(rates["five_hour"]?["resets_at"], 1793167800)
        XCTAssertEqual(rates["seven_day"]?["resets_at"], 1793440800)
        XCTAssertThrowsError(try ClaudeUsageQuery.decode(text: "Showing last-known usage\n" + text, now: now))
        XCTAssertThrowsError(try ClaudeUsageQuery.decode(text: "Usage endpoint is rate limited", now: now))
        XCTAssertThrowsError(try ClaudeUsageQuery.decode(text: "unexpected format", now: now))
    }

    /// 만료된 5시간 구간의 독립 제외와 유효 주간 구간 보존 검증
    func testExpiredWindowDoesNotDiscardValidWeeklyUsage() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-31T08:50:02Z"))
        for reset in ["Oct 31 at 5:50pm", "5:50pm"] {
            let text = "Current session: 42% used · resets \(reset) (Asia/Seoul)\nCurrent week (all models): 13% used · resets Oct 31 at 7pm (Asia/Seoul)"
            let rates = try ClaudeUsageQuery.decode(text: text, now: now)
            XCTAssertNil(rates["five_hour"])
            XCTAssertEqual(rates["seven_day"]?["used_percentage"], 13)
        }
        XCTAssertThrowsError(try ClaudeUsageQuery.decode(text: "Current session: 42% used · resets Oct 31 at 5:50pm (Asia/Seoul)", now: now)) {
            XCTAssertEqual($0 as? ClaudeQuotaError, .staleUsage)
        }
    }

    /// 연말의 다음 해 초기화 시각과 잘못된 시각의 구분 검증
    func testYearBoundaryAndMalformedResetRemainDistinct() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-31T14:00:00Z"))
        let text = "Current session: 1% used · resets Jan 1 at 1am (Asia/Seoul)"
        XCTAssertNotNil(try ClaudeUsageQuery.decode(text: text, now: now)["five_hour"])
        XCTAssertThrowsError(try ClaudeUsageQuery.decode(text: "Current session: 1% used · resets invalid (Asia/Seoul)", now: now))
    }

    /// 명시한 실제 폴더에서 새 조회 시각과 서버 비율 수신 검증
    func testRealOfficialUsageWhenConfigured() async throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_QUERY_LIVE_HOME"] else { throw XCTSkip("실계정 조회 폴더 미지정") }
        let home = URL(fileURLWithPath: path), start = Date()
        try await ClaudeUsageQuery.shared.refresh(home: home, cli: ClaudeCLI())
        let snapshot = try XCTUnwrap(ClaudeQuotaSnapshot.read(home: home))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(snapshot.windows["five_hour"]?.observedAt), start)
        XCTAssertNotNil(snapshot.windows["seven_day"])
        let report: [String: Any] = ["source":"official claude --print /usage", "fresh":true,
            "five_hour_used":try XCTUnwrap(snapshot.windows["five_hour"]?.usedPercentage),
            "seven_day_used":try XCTUnwrap(snapshot.windows["seven_day"]?.usedPercentage)]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: "/private/tmp/claude-official-query-result.json"))
    }
}
