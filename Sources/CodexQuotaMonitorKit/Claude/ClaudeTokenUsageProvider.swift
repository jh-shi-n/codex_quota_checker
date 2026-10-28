// 목적: 공식 수집 토큰의 현재 로그인 계정 연결
// 이용처: 계정 토큰 저장소의 Claude 제공자 분기
// 사용방법: fetch(for:expectedEmail:) 호출
// 실행 예시: await ClaudeTokenUsageProvider().fetch(for: config, expectedEmail: account.email)
import Foundation

/// 대화 로그를 읽지 않는 공식 카운터 조회 제공자
public struct ClaudeTokenUsageProvider: Sendable {
    public let cli: ClaudeCLI

    /// 인증 경계의 테스트 주입
    public init(cli: ClaudeCLI = ClaudeCLI()) { self.cli = cli }

    /// 인증된 계정의 수집값만 반환하고 계정 전환·수신 오류 구분
    public func fetch(for config: AccountConfig, expectedEmail: String?) async -> Result<AccountTokenUsage, CodexQuotaServiceError> {
        do {
            let authentication = try await Task.detached { try cli.authentication(home: config.home) }.value
            guard authentication.email == expectedEmail else { return .failure(.cancelled) }
            return .success(try await ClaudeTelemetryStore.shared.usage(home: config.home, identity: authentication.identity, email: authentication.email))
        } catch { return .failure(.protocolError("공식 Claude 토큰 수집값을 확인하지 못했습니다.")) }
    }
}
