// 목적: 등록 경로가 없는 사용자의 초기 연결 창과 저장 동작 연결
@preconcurrency import AppKit
import SwiftUI
import CodexQuotaMonitorKit

extension CodexQuotaMonitorAppDelegate: NSWindowDelegate {
    /// 최초 미등록 또는 설정 불일치 상태의 자동 연결 가이드 표시
    func openAccountSetupIfNeeded() {
        guard preferences.requiresAccountSetup else { return }
        openAccountSetup()
    }

    /// 최초 연결·전체 삭제 후 재연결·추가 계정에서 공용 가이드 표시
    func openAccountSetup() {
        if let accountSetupWindow {
            accountSetupWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = AccountSetupModel(isRecovery: preferences.needsAccountRecovery)
        let window = AccountSetupWindow.make(
            model: model,
            onComplete: { [weak self] path in self?.registerConnectedAccount(path: path) },
            onLater: { [weak self] in self?.accountSetupWindow?.close() }
        )
        window.delegate = self
        accountSetupModel = model
        accountSetupWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 확인된 한 계정 경로 저장과 해당 슬롯 표시 활성화
    private func registerConnectedAccount(path: String) {
        guard preferences.registerAccount(path: path) != nil else {
            accountSetupModel?.reportRegistrationFailure(preferences.persistenceError ?? "설정을 반영하지 못했습니다. 다시 시도해 주세요.")
            return
        }
        applySavedAccountPaths()
    }

    /// 가이드 닫기 시 진행 중 조회와 미저장 초안 폐기
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === accountSetupWindow else { return }
        accountSetupModel?.cancelCheck()
        accountSetupModel = nil
        accountSetupWindow = nil
    }
}
