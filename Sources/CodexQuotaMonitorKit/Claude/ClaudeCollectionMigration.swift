// 목적: 직접 조회 전환 후 이전 앱 수집 설정의 자동 복원
// 이용처: Claude 사용량 조회·계정 확인·스냅샷 저장 성공 이후
// 사용방법: restoreLegacySettings(home:) 호출
// 실행 예시: ClaudeCollectionMigration.restoreLegacySettings(home: folder)
import Foundation

/// 앱이 설치한 값과 일치하는 수집 설정만 복원하는 전환 처리
internal enum ClaudeCollectionMigration {
    /// 사용자 변경 보존 및 복원 실패와 정상 사용량 조회의 분리
    static func restoreLegacySettings(home: URL) {
        if ClaudeStatusLineConnection.isInstalled(home: home) {
            do { try ClaudeStatusLineConnection.remove(home: home) }
            catch { AppOperationFailure(.unexpected, "이전 Claude 상태 표시줄 수집 설정을 복원하지 못했습니다.", underlying: error).record() }
        }
        if ClaudeTelemetryConnection.isInstalled(home: home) {
            do { try ClaudeTelemetryConnection.remove(home: home) }
            catch { AppOperationFailure(.unexpected, "이전 Claude 토큰 수집 설정을 복원하지 못했습니다.", underlying: error).record() }
        }
    }
}
