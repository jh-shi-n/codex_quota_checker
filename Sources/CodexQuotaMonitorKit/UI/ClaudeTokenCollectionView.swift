// 목적: 공식 Claude 토큰 수집의 활성화·해제와 수집 범위 안내
// 이용처: Claude 계정 토큰 사용량 영역
// 사용방법: 현재 계정과 공용 로컬 수집기 연결
// 실행 예시: ClaudeTokenCollectionView(account: account)
import SwiftUI

/// CLI 설정 변경을 명시적 버튼으로 제한하는 공식 수집 안내
struct ClaudeTokenCollectionView: View {
    let account: AccountState
    @ObservedObject private var server = ClaudeTelemetryServer.shared
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("공식 토큰 수집을 켠 뒤 이 기기에서 받은 값입니다. 웹·다른 기기·수집 이전 사용량은 포함하지 않으며 날짜는 수신일의 UTC 기준입니다.")
                .font(.caption).foregroundStyle(.secondary)
            if let home = server.home(accountID: account.id) {
                Button(ClaudeTelemetryConnection.isInstalled(home: home) ? "공식 토큰 수집 해제" : "공식 토큰 수집 연결") {
                    Task {
                    do {
                        let enabled = !ClaudeTelemetryConnection.isInstalled(home: home)
                        try await server.setEnabled(enabled, home: home)
                        message = enabled ? "수집 연결을 설치했습니다. Claude CLI를 다시 시작하면 공식 토큰 카운터가 자동 수신됩니다." : "이전 토큰 수집 설정을 복원했습니다. Claude CLI를 다시 시작해 주세요."
                    } catch {
                        message = (error as? ClaudeQuotaError)?.errorDescription ?? "공식 토큰 수집 설정을 변경하지 못했습니다."
                    }
                    }
                }
                .buttonStyle(.appAction)
            }
            if let message = server.failureMessage ?? message {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .onChange(of: server.revision) { _, _ in
            Task { await AccountTokenUsageStore.shared.refresh(for: account, force: true)?.value }
        }
    }
}
