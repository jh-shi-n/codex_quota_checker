// 목적: 연결 폴더별 Codex·Claude 할당량 조회 분기
// 이용처: 최초 연결 확인과 계정 저장소의 공통 로더
// 사용방법: state(for:) 호출
// 실행 예시: await AccountQuotaService.state(for: account)
import Foundation

/// 기존 Codex 서비스의 동작을 보존하는 제공자 분기
public enum AccountQuotaService {
    /// 실제 폴더의 제공자에 따라 독립 서비스 호출
    public static func state(for config: AccountConfig, claude: ClaudeQuotaService = ClaudeQuotaService()) async -> AccountState {
        if config.provider == .claude { return await claude.state(for: config) }
        return await CodexQuotaService().state(for: config)
    }
}
