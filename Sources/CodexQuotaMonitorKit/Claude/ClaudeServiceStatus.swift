// 목적: Claude 공개 API·제품 서비스 상태 조회
// 이용처: Claude 계정 배지 옆 상태 버튼과 주기 새로고침
// 사용방법: ClaudeServiceStatus.shared.refresh() 호출
// 실행 예시: await ClaudeServiceStatus.shared.refresh().value
import Foundation

/// 계정·인증정보 전송 없이 공식 상태 목록만 조회하는 클라이언트
public enum ClaudeServiceStatusClient {
    public static let endpoint = URL(string: "https://status.claude.com/api/v2/components.json")!

    /// 제한시간 10초·응답 크기 2MB의 공개 상태 조회
    public static func fetch() async throws -> [OpenAIServiceComponent] {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              data.count <= 2_000_000 else { throw URLError(.badServerResponse) }
        return try decode(data)
    }

    /// 공용 상태 항목 검증을 재사용하며 API·Code 항목의 실제 존재 확인
    static func decode(_ data: Data) throws -> [OpenAIServiceComponent] {
        let components = try OpenAIServiceStatusClient.decode(data)
        guard components.contains(where: { $0.name.contains("api.anthropic.com") || $0.name == "Claude API" }),
              components.contains(where: { $0.name == "Claude Code" }) else { throw URLError(.cannotParseResponse) }
        return components
    }
}

/// Claude 계정 사이의 중복 요청·성공값·실패 상태 공유
@MainActor
public enum ClaudeServiceStatus {
    public static let shared = OpenAIServiceStatusStore(fetch: ClaudeServiceStatusClient.fetch)
}
