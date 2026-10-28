// 목적: Stats·세션 기록 토큰의 현재 로그인 계정 연결
// 이용처: 계정 토큰 저장소의 Claude 제공자 분기
// 사용방법: fetch(for:expectedEmail:) 호출
// 실행 예시: await ClaudeTokenUsageProvider().fetch(for: config, expectedEmail: account.email)
import Foundation

/// 현재 인증 확인과 로컬 폴더 사용량을 연결하는 제공자
public struct ClaudeTokenUsageProvider: Sendable {
    public let cli: ClaudeCLI
    public let reader: ClaudeLocalTokenUsageReader

    /// 인증 경계의 테스트 주입
    public init(cli: ClaudeCLI = ClaudeCLI(), reader: ClaudeLocalTokenUsageReader = .shared) {
        self.cli = cli
        self.reader = reader
    }

    /// 조회 전후 로그인 일치 확인 및 연결 폴더의 기록 반환
    public func fetch(for config: AccountConfig, expectedEmail: String?) async -> Result<AccountTokenUsage, CodexQuotaServiceError> {
        do {
            let authentication = try await Task.detached { try cli.authentication(home: config.home) }.value
            guard authentication.email == expectedEmail else { return .failure(.cancelled) }
            let result = try await reader.snapshot(home: config.home, email: authentication.email)
            try Task.checkCancellation()
            let current = try await Task.detached { try cli.authentication(home: config.home) }.value
            guard current.identity == authentication.identity else { return .failure(.cancelled) }
            return .success(result)
        } catch is CancellationError { return .failure(.cancelled) }
        catch { return .failure(.protocolError("Claude 로컬 토큰 사용량을 확인하지 못했습니다.")) }
    }
}
