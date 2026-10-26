// 목적: 앱 시작·업데이트 실패의 오류코드 대화상자 표시
// 이용처: 사용자 작업 실패 또는 다음 실행에서 확인한 설치 결과
// 사용방법: 메인 실행 흐름에서 present 호출
import AppKit

/// 알림 권한과 무관한 사용자 확인 대화상자
@MainActor
public enum AppErrorPresenter {
    /// 작업 실패 제목과 민감정보 없는 오류코드 안내 표시
    public static func present(title: String, message: String, failure: AppOperationFailure? = nil) {
        let application = NSApplication.shared
        if !application.isRunning {
            application.setActivationPolicy(.accessory)
            application.finishLaunching()
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "확인")
        let copy = ErrorInfoCopyAction(message: message, failure: failure)
        let button = NSButton(title: "오류 정보 복사", target: copy, action: #selector(ErrorInfoCopyAction.copyInfo(_:)))
        button.bezelStyle = .rounded
        button.sizeToFit()
        alert.accessoryView = button
        application.activate(ignoringOtherApps: true)
        withExtendedLifetime(copy) { _ = alert.runModal() }
    }
}

/// 대화상자를 닫지 않고 비동기로 관련 오류 정보를 복사하는 동작
@MainActor
private final class ErrorInfoCopyAction: NSObject {
    private let message: String
    private let failure: AppOperationFailure?

    /// 표시 문구와 원문이 없는 오류 문맥 보관
    init(message: String, failure: AppOperationFailure?) {
        self.message = message
        self.failure = failure
    }

    /// 명시적 버튼 요청 시 진단 요약을 만들고 클립보드에 반영
    @objc func copyInfo(_ sender: NSButton) {
        sender.isEnabled = false
        sender.title = "복사 중…"
        Task.detached(priority: .userInitiated) { [message, failure] in
            let report = await AppErrorReport.make(message: message, failure: failure)
            RunLoop.main.perform(inModes: [.common, .modalPanel, .default]) {
                MainActor.assumeIsolated {
                    NSPasteboard.general.clearContents()
                    let copied = NSPasteboard.general.setString(report, forType: .string)
                    sender.title = copied ? "복사됨" : "복사 실패 · 다시 시도"
                    sender.isEnabled = true
                }
            }
        }
    }
}
