// 목적: 최초 연결 화면의 실제 AppKit 호스트 구성과 크기 보장
// 이용처: 앱 시작 연결 창 및 창 레이아웃 통합 검증
// 사용방법: make 호출 후 앱 호스트에서 delegate·표시 수명 관리
import AppKit
import SwiftUI

/// 앱과 테스트가 공유하는 계정 연결 창 생성 경계
@MainActor
public enum AccountSetupWindow {
    /// 화면 연결 이후 콘텐츠 크기와 최소 크기를 적용한 연결 창 반환
    public static func make(
        model: AccountSetupModel,
        onComplete: @escaping (String) -> Void,
        onLater: @escaping () -> Void
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: AccountSetupView.windowSize),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "LLM Quota Checker 시작하기"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: AccountSetupView(
            model: model, onComplete: onComplete, onLater: onLater
        ))
        window.contentMinSize = AccountSetupView.windowSize
        window.setContentSize(AccountSetupView.windowSize)
        return window
    }
}
