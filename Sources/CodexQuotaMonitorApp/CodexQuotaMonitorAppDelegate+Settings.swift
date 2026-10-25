// 목적: 설정 화면 바인딩과 앱 위임자 설정 변경 처리
@preconcurrency import AppKit
import SwiftUI

import CodexQuotaMonitorKit

extension CodexQuotaMonitorAppDelegate {
    func openSettings() {
        effectiveLaunchAtLoginStatus = lifecycleCoordinator.readLaunchAtLoginStatus()
        // Accessory apps can report `showSettingsWindow:` as handled without
        // actually presenting SwiftUI's Settings scene. Ring clicks therefore
        // use the concrete AppKit host directly and reuse it on later clicks.
        if fallbackSettingsWindow == nil {
            createFallbackSettingsWindow()
        } else {
            fallbackSettingsWindow?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 한글 제목과 공통 콘텐츠 크기의 설정 창 생성
    private func createFallbackSettingsWindow() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsView.defaultWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Quota Checker 설정"
        window.isReleasedWhenClosed = false
        window.contentMinSize = SettingsView.minimumWindowSize
        window.contentViewController = NSHostingController(rootView: makeSettingsView())
        window.center()
        fallbackSettingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// 목적: 설정 화면과 앱 위임자 저장·렌더 콜백 연결
    func makeSettingsView() -> some View {
        SettingsView(
            refreshIntervalMinutes: Binding(
                get: { [weak self] in self?.preferences.refreshIntervalMinutes ?? 5 },
                set: { [weak self] value in self?.applyRefreshInterval(value) }
            ),
            accountPaths: Binding(
                get: { [weak self] in self?.preferences.accountPaths ?? [] },
                set: { [weak self] values in self?.applyAccountPaths(values) }
            ),
            launchAtLogin: Binding(
                get: { [weak self] in self?.effectiveLaunchAtLoginStatus == .enabled },
                set: { [weak self] enabled in self?.applyLaunchAtLogin(enabled) }
            ),
            showAccountLabels: Binding(
                get: { [weak self] in self?.preferences.showAccountLabels ?? false },
                set: { [weak self] enabled in self?.applyShowAccountLabels(enabled) }
            ),
            activityNotificationDurationSeconds: Binding(
                get: { [weak self] in
                    self?.preferences.activityNotificationDurationSeconds
                        ?? PreferencesStore.defaultActivityNotificationDurationSeconds
                },
                set: { [weak self] seconds in
                    self?.applyActivityNotificationDuration(seconds)
                }
            ),
            enabledAccountIDs: Binding(
                get: { [weak self] in
                    self?.preferences.enabledAccountIDs ?? PreferencesStore.defaultEnabledAccountIDs
                },
                set: { [weak self] ids in self?.applyEnabledAccountIDs(ids) }
            ),
            accountDisplayOrder: Binding(
                get: { [weak self] in
                    self?.preferences.accountDisplayOrder ?? PreferencesStore.defaultAccountDisplayOrder
                },
                set: { [weak self] ids in self?.applyAccountDisplayOrder(ids) }
            ),
            accountDisplayNames: Binding(
                get: { [weak self] in self?.preferences.accountDisplayNames ?? [:] },
                set: { [weak self] names in
                    guard let self else { return }
                    self.preferences.updateAccountDisplayNames(names)
                    self.render(states: self.accountStore.states)
                }
            ),
            resetReminderMinutes: Binding(
                get: { [weak self] in self?.preferences.resetReminderMinutes ?? 5 },
                set: { [weak self] minutes in
                    guard let self else { return }
                    self.preferences.updateResetReminder(minutes: minutes)
                    self.quotaResetScheduler.reconcile(
                        states: self.accountStore.states, reminderMinutes: self.preferences.resetReminderMinutes
                    )
                    if minutes > 0 && self.quotaResetNotifications.delivery.status.authorization == .notRequested {
                        self.quotaResetNotifications.retryAuthorization()
                    }
                }
            ),
            notificationDelivery: quotaResetNotifications.delivery,
            onRetryNotificationAuthorization: { [weak self] in
                self?.quotaResetNotifications.retryAuthorization()
            },
            onSendNotificationTest: { [weak self] in
                self?.quotaResetNotifications.sendTestNotification()
            },
            onOpenNotificationSettings: { [weak self] in
                self?.openNotificationSettings()
            },
            tokenUsageOptions: Binding(
                get: { [weak self] in self?.preferences.tokenUsageOptions ?? TokenUsageOptions() },
                set: { [weak self] in self?.applyTokenUsageOptions($0) }
            )
        )
        .safeAreaInset(edge: .top) { StorageStatusView(preferences: preferences) }
    }

    /// 사용자 동작 시 macOS 알림 시스템 설정 열기
    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func applyRefreshInterval(_ minutes: Int) {
        let preferences = self.preferences
        lifecycleCoordinator.applyRefreshInterval(minutes: minutes) { value in
            preferences.updateRefreshInterval(minutes: value)
            return preferences.refreshIntervalMinutes
        }
    }

    func applyAccountPaths(_ paths: [String]) {
        let accepted = paths.contains(where: { !$0.isEmpty })
            ? preferences.registerAccountPaths(paths) : preferences.updateAccountPaths(paths)
        guard accepted else {
            let alert = NSAlert()
            alert.messageText = "설정을 반영하지 못했습니다"
            alert.informativeText = preferences.persistenceError ?? "계정 경로를 확인한 뒤 다시 시도해 주세요."
            alert.runModal()
            return
        }
        if preferences.hasRegisteredAccounts {
            accountSetupWindow?.close()
        } else if !preferences.hasRegisteredAccount {
            openAccountSetupIfNeeded()
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.lifecycleCoordinator.reconfigure(paths: self.preferences.accountPaths)
        }
    }

    /// 계정 토큰 그래프의 형태·표시 범위 저장
    private func applyTokenUsageOptions(_ options: TokenUsageOptions) {
        preferences.updateTokenUsageOptions(options)
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        switch launchAtLoginService.setEnabled(enabled) {
        case let .success(status):
            effectiveLaunchAtLoginStatus = status
            let effective = enabled ? status == .enabled : status == .disabled
            if effective {
                preferences.updateLaunchAtLogin(enabled)
            } else {
                presentLaunchAtLoginStatus(status, requestedEnabled: enabled)
            }
        case let .failure(error):
            effectiveLaunchAtLoginStatus = launchAtLoginService.status
            presentLaunchAtLoginFailureMessage(error.localizedDescription)
        }
    }

    private func applyShowAccountLabels(_ enabled: Bool) {
        preferences.updateShowAccountLabels(enabled)
        render(states: accountStore.states)
    }

    /// 목적: 활성 계정 설정 저장 후 현재 상태 재렌더
    private func applyEnabledAccountIDs(_ ids: [String]) {
        preferences.updateEnabledAccountIDs(ids)
        render(states: accountStore.states)
    }

    /// 목적: 계정 표시 순서 저장 후 현재 상태 재렌더
    private func applyAccountDisplayOrder(_ ids: [String]) {
        preferences.updateAccountDisplayOrder(ids)
        render(states: accountStore.states)
    }

    private func applyActivityNotificationDuration(_ seconds: Int) {
        preferences.updateActivityNotificationDuration(seconds: seconds)
        sessionActivityToastQueue.updateDuration(
            seconds: preferences.activityNotificationDurationSeconds
        )
    }

    private func presentLaunchAtLoginStatus(_ status: LaunchAtLoginStatus, requestedEnabled: Bool) {
        let message: String
        switch status {
        case .requiresApproval:
            presentLaunchAtLoginApproval()
            return
        case .notFound:
            message = "macOS에서 설치된 앱을 찾을 수 없습니다."
        case .disabled:
            message = requestedEnabled
                ? "로그인 시 자동 실행이 활성화되지 않았습니다."
                : "로그인 시 자동 실행이 꺼져 있습니다."
        case .enabled:
            message = "로그인 시 자동 실행이 켜져 있습니다."
        }
        presentLaunchAtLoginFailureMessage(message)
    }

    private func presentLaunchAtLoginApproval() {
        let alert = NSAlert()
        alert.messageText = "로그인 시 자동 실행 승인"
        alert.informativeText = "앱이 등록되었습니다. 시스템 설정 > 로그인 항목에서 승인해 주세요."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "로그인 항목 열기")
        alert.addButton(withTitle: "취소")

        if let settingsWindow = settingsHostWindow {
            alert.beginSheetModal(for: settingsWindow) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.launchAtLoginService.openSystemSettingsLoginItems()
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            launchAtLoginService.openSystemSettingsLoginItems()
        }
    }

    private func presentLaunchAtLoginFailureMessage(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "로그인 시 자동 실행을 변경하지 못했습니다"
        alert.informativeText = message
        alert.alertStyle = .warning
        if let settingsWindow = settingsHostWindow {
            alert.beginSheetModal(for: settingsWindow)
        } else {
            alert.runModal()
        }
    }

    private var settingsHostWindow: NSWindow? {
        if let fallbackSettingsWindow, fallbackSettingsWindow.isVisible {
            return fallbackSettingsWindow
        }
        if let keyWindow = NSApp.keyWindow, keyWindow.isVisible {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow, mainWindow.isVisible {
            return mainWindow
        }
        return nil
    }
}

/// 설정과 캐시 오류를 구분하고 복구 원본 위치를 안내하는 설정 화면 영역
private struct StorageStatusView: View {
    @ObservedObject var preferences: PreferencesStore

    var body: some View {
        if preferences.persistenceError != nil || preferences.cacheError != nil || preferences.tokenHistoryError != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let error = preferences.persistenceError {
                    Text(error).foregroundStyle(.red)
                    Text("원본 설정을 보존했습니다. 손상된 설정을 복구한 뒤 앱을 다시 실행해 주세요.")
                }
                if let error = preferences.cacheError {
                    Text(error).foregroundStyle(.orange)
                    Button("캐시 정리 재시도") { preferences.cleanupQuotaSnapshots() }
                        .buttonStyle(.appAction)
                }
                if let error = preferences.tokenHistoryError {
                    Text(error).foregroundStyle(.orange)
                }
                Button("설정 저장 위치 열기") {
                    NSWorkspace.shared.open(AppConfigurationFile.defaultFileURL.deletingLastPathComponent())
                }
                .buttonStyle(.appAction)
            }
            .font(.caption)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
