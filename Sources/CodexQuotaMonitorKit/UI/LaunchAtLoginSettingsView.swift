// 목적: 로그인 자동실행의 실제 상태와 승인 안내 표시
// 이용처: 앱 설정의 자동실행 토글과 명시적 시스템 설정 진입
// 사용방법: 관찰 대상 서비스와 사용자 변경 콜백 전달
// 실행 예시: LaunchAtLoginSettingsView(service: service, onSetEnabled: apply)
import SwiftUI

/// 시스템 상태 변경을 기존 설정 창에 반영하는 자동실행 설정 영역
@MainActor
struct LaunchAtLoginSettingsView: View {
    @ObservedObject var service: LaunchAtLoginService
    let onSetEnabled: @MainActor (Bool) -> Void

    /// 활성 상태 토글과 승인·설치 오류별 안내 구성
    var body: some View {
        Toggle(SettingsView.launchAtLoginLabel, isOn: Binding(
            get: { service.currentStatus == .enabled },
            set: { enabled in onSetEnabled(enabled) }
        ))
        switch service.currentStatus {
        case .requiresApproval:
            Text("자동 실행이 등록되어 있지만 macOS 승인이 필요합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("로그인 항목 열기") { service.openSystemSettingsLoginItems() }
                .buttonStyle(.appAction)
        case .notFound:
            Text("macOS에서 앱을 찾을 수 없습니다. 응용 프로그램 폴더의 앱을 실행한 뒤 자동 실행을 다시 켜 주세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .enabled, .disabled:
            EmptyView()
        }
    }
}
