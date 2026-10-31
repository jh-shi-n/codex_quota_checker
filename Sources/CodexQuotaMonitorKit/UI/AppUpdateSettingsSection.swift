// 목적: 설치 버전·최신 릴리스 확인과 사용자 선택에 따른 업데이트 설치
// 이용처: 앱 설정의 업데이트 영역
// 사용방법: 앱이 소유한 AppUpdateStore 전달
import SwiftUI

/// 자동 설치 없이 사용자가 선택한 새 버전만 다운로드·설치
public struct AppUpdateSettingsSection: View {
    @ObservedObject private var store: AppUpdateStore

    /// 설정 창 재진입에도 공유되는 업데이트 상태 연결
    public init(store: AppUpdateStore) { self.store = store }

    public var body: some View {
        Section("앱 업데이트") {
            LabeledContent("현재 버전", value: store.currentVersion)
            if let latest = store.latest {
                LabeledContent("최신 릴리스", value: latest.version)
            }
            HStack {
                Text(store.isInstalling ? "다운로드·검증 후 앱을 재실행합니다." : statusText)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if store.isChecking || store.isInstalling { ProgressView().controlSize(.small) }
                Button("업데이트 확인") { store.check() }
                    .disabled(store.isChecking || store.isInstalling)
            }
            if store.updateAvailable, let latest = store.latest {
                HStack {
                    Button("업데이트 설치 후 재실행") { store.install() }
                        .disabled(store.isChecking || store.isInstalling || latest.asset == nil)
                    Link("릴리스 내용 보기", destination: latest.pageURL)
                }
                if latest.asset == nil {
                    Text("이 Mac에 맞는 배포 파일은 릴리스 페이지에서 확인해 주세요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = store.installationError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            Text("업데이트 설치 버튼을 눌러야 설치합니다. 앱 실행 시 하루 한 번 새 버전을 확인합니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 공유 업데이트 상태를 설정 화면용 완결 문장으로 표시
    private var statusText: String {
        if store.isChecking { return "새 버전을 확인하고 있습니다." }
        if store.checkFailed { return AppErrorCode.updateCheck.message("업데이트를 확인하지 못했습니다. 다시 시도해 주세요.") }
        guard store.latest != nil else { return "아직 새 버전을 확인하지 않았습니다." }
        return store.updateAvailable ? "새 버전을 사용할 수 있습니다." : "사용 가능한 새 버전이 없습니다."
    }

}
