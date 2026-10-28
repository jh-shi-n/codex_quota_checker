// 목적: Claude 로컬 집계 범위와 이전 수집 설정의 해제 안내
// 이용처: Claude 계정 토큰 사용량 영역
// 사용방법: 현재 계정과 공용 로컬 수집기 연결
// 실행 예시: ClaudeTokenCollectionView(account: account)
import SwiftUI

/// 로컬 집계에 별도 수집 연결이 필요 없음을 알리는 안내
struct ClaudeTokenCollectionView: View {
    let account: AccountState
    @ObservedObject private var server = ClaudeTelemetryServer.shared
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stats 캐시와 세션 기록을 자동으로 읽습니다. 별도 수집 연결은 필요하지 않으며 연결 폴더의 기록만 포함합니다.")
                .font(.caption).foregroundStyle(.secondary)
            if let home = server.home(accountID: account.id), ClaudeTelemetryConnection.isInstalled(home: home) {
                Button("이전 공식 토큰 수집 해제") {
                    Task {
                        do {
                            try await server.setEnabled(false, home: home)
                            message = "이전 토큰 수집 설정을 복원했습니다. Claude CLI를 다시 시작해 주세요."
                        } catch {
                            message = (error as? ClaudeQuotaError)?.errorDescription ?? "공식 토큰 수집 설정을 변경하지 못했습니다."
                        }
                    }
                }
                .buttonStyle(.appAction)
            }
            if let message = message {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}
