// 목적: 경로가 없는 사용자의 최초 계정 연결 안내
// 이용처: 최초 계정 등록 완료 전의 연결 창
// 사용방법: 비영속 연결 모델과 등록·나중에 동작 전달
import SwiftUI

/// 폴더 선택과 실제 연결 확인 후 한 계정부터 등록하는 초기 가이드
public struct AccountSetupView: View {
    public static let windowSize = CGSize(width: 600, height: 640)
    @ObservedObject private var model: AccountSetupModel
    private let onComplete: (String) -> Void
    private let onLater: () -> Void

    /// 저장·창 닫기 책임을 앱 호스트에 위임하는 가이드 초기화
    public init(model: AccountSetupModel, onComplete: @escaping (String) -> Void, onLater: @escaping () -> Void) {
        self.model = model
        self.onComplete = onComplete
        self.onLater = onLater
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.isRecovery ? "계정 연결 복구" : "계정 연결 시작하기")
                .font(.title2.weight(.semibold))
            Text(model.isRecovery
                 ? "등록 완료 이력은 있지만 연결된 계정 경로가 없습니다. 사용할 계정을 확인해 다시 연결해 주세요."
                 : "기본 계정을 자동으로 확인합니다. 연결할 계정을 확인한 뒤 등록해 주세요.")
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Codex 로그인 준비")
                            .font(.headline)
                        Text("Codex CLI에서 사용하려는 계정에 먼저 로그인해 주세요.")
                            .font(.callout)
                        Link("설치·로그인 안내", destination: URL(string: "https://developers.openai.com/codex/cli")!)
                            .font(.caption)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("2. 연결할 계정 확인")
                            .font(.headline)
                        if let discoveryMessage = model.discoveryMessage {
                            Text(discoveryMessage)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            TextField("Codex 계정 폴더 경로", text: $model.path)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("account-setup-path")
                                .onSubmit { checkConnection() }
                                .disabled(model.isRegistering)
                            Button("폴더 선택") {
                                if let selected = AccountFolderPicker.choose(currentPath: model.path) { model.path = selected }
                            }
                            .disabled(model.isRegistering)
                        }
                        Text("숨김 폴더도 선택할 수 있습니다. 경로를 직접 입력해도 됩니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        AccountPathHelpView()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("3. 연결 확인 후 등록")
                            .font(.headline)
                        Group {
                            if let error = model.registrationError {
                                Text(error).foregroundStyle(.red).textSelection(.enabled)
                            } else if model.phase == .checking {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("계정의 할당량을 확인하는 중입니다…")
                                }
                            } else if let message = model.message {
                                Text(message)
                                    .foregroundStyle(model.phase == .connected ? Color.green : .red)
                                    .textSelection(.enabled)
                            } else {
                                Text("연결 확인을 누르면 선택한 계정의 로그인 상태와 할당량을 확인합니다.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("추가 계정은 설정에서 등록할 수 있습니다. 나중에 연결하려면 상단바 아이콘을 눌러 이 안내를 다시 여세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("나중에", action: onLater)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isRegistering)
                Spacer()
                Button("연결 확인", action: checkConnection)
                    .disabled(!model.canCheck)
                Button(model.isRegistering ? "연결 적용 중…" : "이 계정 연결") {
                    if let path = model.beginRegistration() { onComplete(path) }
                }
                .buttonStyle(.appPrimary)
                .disabled(!model.canFinish)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(
            minWidth: Self.windowSize.width, maxWidth: .infinity,
            minHeight: Self.windowSize.height, maxHeight: .infinity,
            alignment: .topLeading
        )
        .preferredColorScheme(.dark)
        .buttonStyle(.appAction)
        .task { await model.discoverDefaultAccount() }
    }

    /// 입력 가능 상태에서만 비동기 연결 확인 시작
    private func checkConnection() {
        guard model.canCheck else { return }
        Task { await model.checkConnection() }
    }
}
