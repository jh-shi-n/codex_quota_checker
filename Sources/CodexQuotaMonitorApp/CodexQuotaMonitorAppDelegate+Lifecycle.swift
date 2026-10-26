// 목적: 앱 시작·종료·절전 복귀 및 할당량 스냅샷 만료 정리
// 이용처: 앱 위임자의 macOS 수명주기 콜백
// 사용방법: NSApplicationDelegate 이벤트를 통한 자동 호출
@preconcurrency import AppKit
import CodexQuotaMonitorKit

extension CodexQuotaMonitorAppDelegate {
    /// 앱 시작과 서비스 연결 및 진단·캐시 정리 시작
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        DiagnosticLogContext.record(.appStarted, fields: [
            .version: .identifier(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"),
            .build: .identifier(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"),
        ])
        appUpdates.check(force: false)
        DiagnosticLogContext.recordCLIVersion()
        installWakeObserver()
        quotaResetNotifications.start()
        lifecycleCoordinator.launch()
        if preferences.persistenceError != nil { openSettings() }
        else { openAccountSetupIfNeeded() }
        Task { await sessionActivityMonitor.start() }
        quotaSnapshotCleanupTask = Task { [preferences] in
            while !Task.isCancelled {
                preferences.cleanupQuotaSnapshots()
                do { try await Task.sleep(for: .seconds(60)) }
                catch { return }
            }
        }
        synchronizeLaunchAtLoginStatus()
        quotaResetNotifications.refreshAuthorization()
    }

    /// 시스템 설정에서 앱으로 복귀할 때 자동실행 승인 상태 재확인
    func applicationDidBecomeActive(_ notification: Notification) {
        _ = notification
        synchronizeLaunchAtLoginStatus()
    }

    /// 종료 응답을 지연해 비동기 조회 취소와 native 자식 정리에 최대 2초 제공
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quotaMonitoring.stop()
        UsageWindowProbeStore.shared.cancelAll()
        AccountTokenUsageStore.shared.invalidateAll()
        Task {
            await accountStore.shutdown(timeout: 2)
            await ProcessGroupTermination.shutdown()
            await sessionActivityMonitor.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 진행 서비스 종료와 마지막 진단 이벤트의 최대 1초 디스크 기록 대기
    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        DiagnosticLogContext.record(.appTerminating)
        sessionActivityDelivery.stop()
        quotaResetScheduler.stop()
        automaticResetPing.stop()
        UsageWindowProbeStore.shared.cancelAll()
        AccountTokenUsageStore.shared.invalidateAll()
        serviceStatus.cancel()
        appUpdates.cancel()
        emptyAccountsPopover?.performClose(nil)
        emptyAccountsPopover = nil
        quotaSnapshotCleanupTask?.cancel()
        quotaSnapshotCleanupTask = nil
        if let hiddenAccountsStatusItem {
            NSStatusBar.system.removeStatusItem(hiddenAccountsStatusItem)
            self.hiddenAccountsStatusItem = nil
        }
        activityToastCancellable?.cancel()
        activityToastCancellable = nil
        Task { await sessionActivityMonitor.stop() }
        lifecycleCoordinator.terminate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        statesCancellable?.cancel()
        statesCancellable = nil
        fallbackSettingsWindow?.close()
        fallbackSettingsWindow = nil
        accountSetupModel?.cancelCheck()
        accountSetupWindow?.close()
        DiagnosticLogger.shared.flush(timeout: 1)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        _ = sender
        return false
    }

    private func installWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                DiagnosticLogContext.record(.appWoke)
                DiagnosticLogger.shared.maintain()
                self?.preferences.cleanupQuotaSnapshots()
                await self?.lifecycleCoordinator.wake()
                if self?.preferences.automaticRefreshEnabled == true && self?.quotaMonitoring.isStarting == false {
                    await self?.quotaResetScheduler.tick()
                }
            }
        }
    }
}
