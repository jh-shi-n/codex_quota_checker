// 목적: Claude API 상태의 정상·장애·미확인 구분 검증
// 이용처: Claude 계정의 서비스 상태 버튼
// 사용방법: swift test --filter ClaudeServiceStatusTests
// 실행 예시: CLAUDE_STATUS_FIXTURE=/tmp/claude-status.json swift test --filter ClaudeServiceStatusTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 공식 응답 형식과 서비스별 상태 분리 검증
@MainActor
final class ClaudeServiceStatusTests: XCTestCase {
    /// API 장애·Code 정상 상태의 독립 표시 검증
    func testAPIOutageAndCodeOperationalStayDistinct() throws {
        let data = Data("{\"components\":[{\"id\":\"api\",\"name\":\"Claude API (api.anthropic.com)\",\"status\":\"partial_outage\"},{\"id\":\"code\",\"name\":\"Claude Code\",\"status\":\"operational\"}]}".utf8)
        let components = try ClaudeServiceStatusClient.decode(data)
        let details = OpenAIServiceStatusDetails(snapshot: .init(checkedAt: Date(), components: components), provider: .claude)
        XCTAssertEqual(details.statusGroups.first?.rows.first?.component.id, "api")
        XCTAssertEqual(details.statusGroups.last?.rows.first?.component.id, "code")
        XCTAssertEqual(details.statusGroups.first?.rows.first?.section, "Claude")
        XCTAssertThrowsError(try ClaudeServiceStatusClient.decode(Data("{\"components\":[]}".utf8)))
    }

    /// 명시한 공식 API 응답을 실제 디코더로 검증
    func testOfficialResponseWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_STATUS_FIXTURE"] else { throw XCTSkip("공식 응답 파일 미지정") }
        let components = try ClaudeServiceStatusClient.decode(Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertTrue(components.contains { $0.name.contains("api.anthropic.com") })
        XCTAssertTrue(components.contains { $0.name == "Claude Code" })
    }
}
