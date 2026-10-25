// 목적: 계정 표시 설정과 한도·토큰 집계·활동 서비스의 앱 통합
// 이용처: macOS 메뉴 막대 및 노치 모니터
// 사용방법: 앱 실행 후 설정에서 표시 계정과 순서 선택
// 실행 예시: swift run CodexQuotaMonitor
@preconcurrency import AppKit
import Combine
import Darwin
import SwiftUI

import CodexQuotaMonitorKit

@main
enum CodexQuotaMonitorEntryPoint {
    /// macOS 14의 Settings Scene 생성 충돌을 기존 AppKit 수명주기로 우회
    @MainActor
    static func main() {
        if #available(macOS 15.0, *) {
            CodexQuotaMonitorApp.main()
        } else {
            let application = NSApplication.shared
            let delegate = CodexQuotaMonitorAppDelegate()
            application.delegate = delegate
            withExtendedLifetime(delegate) {
                application.run()
            }
        }
    }
}

/// macOS 15 이상에서 앱 메뉴의 설정 Scene 제공
struct CodexQuotaMonitorApp: App {
    @NSApplicationDelegateAdaptor(CodexQuotaMonitorAppDelegate.self)
    private var appDelegate: CodexQuotaMonitorAppDelegate

    var body: some Scene {
        // 앱 메뉴와 노치 설정 동작에서 공통 설정 콘텐츠 사용
        Settings {
            appDelegate.makeSettingsView()
        }
        .defaultSize(SettingsView.defaultWindowSize)
    }
}

@MainActor
final class CodexQuotaMonitorAppDelegate: NSObject, NSApplicationDelegate {
    private let instanceLock: AppInstanceLock
    let preferences: PreferencesStore
    let accountStore: AccountStore
    /// 할당량 조회에 동반하여 갱신하는 네 계정 공용 서비스 상태
    let serviceStatus: OpenAIServiceStatusStore
    let quotaResetNotifications: QuotaResetNotificationService
    /// 안정 관측된 한도의 시각 도달 조회와 사전·도달 시스템 알림 연결
    lazy var quotaResetScheduler = QuotaResetScheduler(
        refresh: { [weak self] id in
            guard let self else { return nil }
            await self.accountStore.refresh(accountID: id, forceFresh: true)
            return self.accountStore.state(for: id)
        },
        notify: { [weak self] alert in
            guard let self else { return }
            await self.quotaResetNotifications.delivery.notifyScheduled(
                alert, displayName: self.preferences.displayName(for: alert.accountID)
            )
        }
    )
    /// 초기화 확인 이후 선택적 Ping과 재시도·실패 알림 연결
    lazy var automaticResetPing = AutomaticResetPingCoordinator(
        refresh: { [weak self] id in
            guard let self else { return nil }
            await self.accountStore.refresh(accountID: id, forceFresh: true)
            return self.accountStore.state(for: id)
        },
        probe: { [weak self] account in
            guard let self else { return AccountDashboardDefaults.unavailableProbe(accountID: account.id, category: .notConfigured) }
            return await self.runUsageWindowProbe(account)
        },
        notify: { [weak self] alert in
            guard let self else { return }
            await self.quotaResetNotifications.delivery.notifyAutomaticPingFailure(
                alert, displayName: self.preferences.displayName(for: alert.accountID)
            )
        }
    )
    let refreshService: RefreshService
    /// 전송과 후속 관측을 합친 계정별 중복 실행 차단
    var runningProbeAccountIDs: Set<String> = []
    /// 수동·자동 Ping이 공통으로 사용하는 시각 고정 확인
    lazy var resetTimeConfirmation = ResetTimeConfirmationService(
        refresh: { [weak self] id in
            guard let self else { return nil }
            await self.accountStore.refresh(accountID: id, forceFresh: true)
            return self.accountStore.state(for: id)
        },
        current: { [weak self] id in self?.accountStore.state(for: id) }
    )
    let launchAtLoginService: LaunchAtLoginService
    let sessionActivityProvider: SQLiteSessionActivityProvider
    /// The probe service owns process lifetime and the per-account running gate.
    let usageWindowProbeService: UsageWindowProbeService
    let sessionActivityToastQueue: SessionActivityToastQueue
    let sessionActivityMonitor: SessionActivityMonitor
    let notchLayoutManager: NotchLayoutManager
    let lifecycleCoordinator: AppLifecycleCoordinator

    var effectiveLaunchAtLoginStatus: LaunchAtLoginStatus
    let sessionActivityDelivery: SessionActivityToastDeliveryGate
    var fallbackSettingsWindow: NSWindow?
    var accountSetupWindow: NSWindow?
    var accountSetupModel: AccountSetupModel?
    var statesCancellable: AnyCancellable?
    var activityToastCancellable: AnyCancellable?
    var wakeObserver: NSObjectProtocol?
    var hiddenAccountsStatusItem: NSStatusItem?
    var emptyAccountsPopover: NSPopover?
    var quotaSnapshotCleanupTask: Task<Void, Never>?

    /// 설정과 계정 서비스 초기화 및 표시·갱신 콜백 연결
    override init() {
        self.instanceLock = Self.acquireInstanceLock()
        let preferences = PreferencesStore(configurationFile: AppConfigurationFile(fileURL: AppConfigurationFile.defaultFileURL))
        let serviceStatus = OpenAIServiceStatusStore()
        let accountStore = AccountStore(
            configs: AccountConfig.accounts(for: preferences.accountPaths),
            preferencesStore: preferences
        )
        let refreshService = RefreshService(
            intervalMinutes: preferences.refreshIntervalMinutes,
            refresh: { [weak accountStore] in
                await accountStore?.refreshAll()
            }
        )
        let launchAtLoginService = LaunchAtLoginService()
        let sessionActivityProvider = SQLiteSessionActivityProvider()
        let usageWindowProbeService = UsageWindowProbeService()
        let sessionActivityToastQueue = SessionActivityToastQueue(
            durationSeconds: preferences.activityNotificationDurationSeconds
        )
        let sessionActivityDelivery = SessionActivityToastDeliveryGate(
            queue: sessionActivityToastQueue
        )
        let quotaResetNotifications = QuotaResetNotificationService { fallback in
            let visible = preferences.visibleAccounts(accountStore.states)
            guard let index = visible.firstIndex(where: { $0.id == fallback.accountID }) else { return }
            let windows = fallback.windowTitles.joined(separator: " · ")
            sessionActivityDelivery.deliver(SessionActivityTransition(
                accountID: fallback.accountID,
                side: index < 2 ? .left : .right,
                sessionID: fallback.id,
                agentLabel: "할당량 리셋 알림",
                taskName: fallback.isFailure ? windows : "\(windows) 조기 초기화",
                status: fallback.isFailure ? .error : .completed
            ))
        }
        let sessionActivityMonitor = SessionActivityMonitor(
            accounts: accountStore.configs,
            provider: sessionActivityProvider,
            onTransition: { transition in
                guard let index = preferences.accountDisplayOrder
                    .filter({ preferences.enabledAccountIDs.contains($0) })
                    .firstIndex(of: transition.accountID)
                else { return }
                sessionActivityDelivery.deliver(SessionActivityTransition(
                    accountID: transition.accountID,
                    side: index < 2 ? .left : .right,
                    sessionID: transition.sessionID,
                    agentLabel: transition.agentLabel,
                    taskName: transition.taskName,
                    status: transition.status,
                    sessionTitle: transition.sessionTitle,
                    turnID: transition.turnID
                ))
            }
        )
        let notchLayoutManager = NotchLayoutManager(serviceStatus: serviceStatus, tokenUsagePreferences: preferences)

        self.preferences = preferences
        self.accountStore = accountStore
        self.serviceStatus = serviceStatus
        self.quotaResetNotifications = quotaResetNotifications
        self.refreshService = refreshService
        self.launchAtLoginService = launchAtLoginService
        self.sessionActivityProvider = sessionActivityProvider
        self.usageWindowProbeService = usageWindowProbeService
        self.sessionActivityToastQueue = sessionActivityToastQueue
        self.sessionActivityMonitor = sessionActivityMonitor
        self.notchLayoutManager = notchLayoutManager
        self.sessionActivityDelivery = sessionActivityDelivery
        self.effectiveLaunchAtLoginStatus = launchAtLoginService.status

        self.lifecycleCoordinator = AppLifecycleCoordinator(
            actions: AppLifecycleActions(
                activateAccessory: {
                    NSApp.setActivationPolicy(.accessory)
                },
                renderLoading: {
                    let visible = preferences.visibleAccounts(accountStore.states)
                    notchLayoutManager.update(
                        leftAccounts: QuotaClusterView.splitVisibleAccounts(visible, side: .left),
                        rightAccounts: QuotaClusterView.splitVisibleAccounts(visible, side: .right),
                        showAccountLabels: preferences.showAccountLabels
                    )
                },
                startObservers: {
                    notchLayoutManager.startObservingScreenChanges()
                },
                showPanels: {
                    notchLayoutManager.show()
                },
                startRefresh: {
                    refreshService.start()
                },
                stopRefresh: {
                    refreshService.stop()
                },
                hidePanels: {
                    notchLayoutManager.hide()
                },
                stopObservers: {
                    notchLayoutManager.stopObservingScreenChanges()
                },
                relayout: {
                    _ = notchLayoutManager.screenDidChange()
                },
                refreshNow: {
                    await refreshService.refreshNow()
                },
                restartRefresh: { minutes in
                    refreshService.restart(intervalMinutes: minutes)
                },
                reconfigurePaths: { paths in
                    let generation = sessionActivityDelivery.pause()
                    // 경로가 달라진 슬롯만 동기 무효화하여 다른 계정의 기록 보존
                    let previousHomes = Self.configuredHomes(for: accountStore.configs)
                    let nextHomes = Self.configuredHomes(for: AccountConfig.accounts(for: paths))
                    for accountID in Set(previousHomes.keys).union(nextHomes.keys) {
                        if previousHomes[accountID] != nextHomes[accountID] {
                            AccountTokenUsageStore.shared.invalidate(accountID: accountID)
                        }
                    }
                    accountStore.reconfigure(pathStrings: paths)
                    Task { @MainActor in
                        await sessionActivityMonitor.reconfigure(
                            accounts: accountStore.configs
                        )
                        sessionActivityDelivery.resume(generation: generation)
                    }
                },
                readLaunchAtLoginStatus: {
                    launchAtLoginService.status
                }
            )
        )
        super.init()

        preferences.onAutomaticResetPingChanged = { [weak self] enabled in
            guard let self else { return }
            self.automaticResetPing.reconcile(states: self.accountStore.states, enabled: enabled)
            if enabled, self.quotaResetNotifications.delivery.status.authorization == .notRequested {
                self.quotaResetNotifications.retryAuthorization()
            }
        }

        accountStore.onQuotaRefreshStarted = { [weak serviceStatus] in
            serviceStatus?.refresh()
        }

        accountStore.onEarlyQuotaReset = { [weak self] reset in
            guard let self else { return }
            guard let permitted = reset.suppressingUnavailablePrimary(
                weeklyRemaining: self.accountStore.state(for: reset.accountID)?.secondaryRemainingPercent
            ) else { return }
            self.quotaResetNotifications.notify(permitted,
                displayName: self.preferences.displayName(for: reset.accountID))
        }

        activityToastCancellable = sessionActivityToastQueue.$currentLeft
            .combineLatest(sessionActivityToastQueue.$currentRight)
            .sink { [weak self] left, right in
                self?.notchLayoutManager.updateActivityToasts(left: left, right: right)
            }

        AccountTokenUsageStore.shared.loader = { [weak self] account in
            guard let self,
                  let config = self.accountStore.configs.first(where: { $0.id == account.id }),
                  self.accountStore.state(for: account.id)?.configurationGeneration == account.configurationGeneration
            else { return .failure(.notConfigured) }
            let result = await CodexQuotaService().fetchTokenUsage(for: config)
            guard self.accountStore.configs.first(where: { $0.id == account.id }) == config,
                  self.accountStore.state(for: account.id)?.configurationGeneration == account.configurationGeneration,
                  self.accountStore.state(for: account.id)?.email == account.email else { return .failure(.cancelled) }
            if case let .success(snapshot) = result, let email = account.email, snapshot.accountEmail != email {
                return .failure(.protocolError("Account identity changed"))
            }
            return result
        }

        let loadSessionActivity: SessionActivityLoader = { [weak self] account in
            guard let self else {
                return .unavailable(accountID: account.id)
            }
            return await self.loadSessionActivity(account)
        }
        notchLayoutManager.leftPanel.setSessionActivityLoader(loadSessionActivity)
        notchLayoutManager.rightPanel.setSessionActivityLoader(loadSessionActivity)

        let runUsageWindowProbe: UsageWindowProbeRunner = { [weak self] account in
            guard let self else {
                return AccountDashboardDefaults.unavailableProbe(
                    accountID: account.id,
                    category: .processFailure
                )
            }
            return await self.runUsageWindowProbe(account)
        }
        notchLayoutManager.setDashboardCallbacks(
            loadCachedTokenUsage: AccountDashboardDefaults.emptyTokenUsageLookup,
            refreshTokenUsage: AccountDashboardDefaults.unavailableTokenUsageRefresh,
            consumeResetCredit: { [weak self] account, creditID, attempt in
                guard let self else { return .failure(.cancelled) }
                return await self.consumeResetCredit(account, creditID: creditID, attempt: attempt)
            },
            runUsageWindowProbe: runUsageWindowProbe
        )

        notchLayoutManager.leftPanel.onRefresh = { [weak self] account in
            self?.refreshAccount(account.id)
        }
        notchLayoutManager.rightPanel.onRefresh = { [weak self] account in
            self?.refreshAccount(account.id)
        }
        notchLayoutManager.leftPanel.onSettings = { [weak self] in
            self?.openSettings()
        }
        notchLayoutManager.rightPanel.onSettings = { [weak self] in
            self?.openSettings()
        }

        statesCancellable = accountStore.$states.sink { [weak self] states in
            if let self {
                AccountTokenUsageStore.shared.restore(
                    accounts: states,
                    homes: Self.configuredHomes(for: self.accountStore.configs)
                )
            }
            self?.quotaResetScheduler.reconcile(
                states: states, reminderMinutes: preferences.resetReminderMinutes
            )
            self?.automaticResetPing.reconcile(states: states, enabled: preferences.automaticResetPingEnabled)
            self?.render(states: states)
        }
    }

    /// 설정·타이머 생성 전 중복 진입 차단 및 기존 앱 활성화
    private static func acquireInstanceLock() -> AppInstanceLock {
        let lock = AppInstanceLock(fileURL: AppConfigurationFile.defaultFileURL
            .deletingLastPathComponent().appendingPathComponent("instance.lock"))
        do {
            if try lock.acquire() { return lock }
            let identifier = Bundle.main.bundleIdentifier ?? "com.example.codexquotamonitor"
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) {
                running.activate(options: [])
            }
            exit(EXIT_SUCCESS)
        } catch {
            let message = "앱 실행 잠금을 확보하지 못했습니다: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }

    /// 설정 순서의 표시 계정 배치 및 전체 숨김 시 설정 진입점 유지
    func render(states: [AccountState]) {
        let visible = preferences.visibleAccounts(states)
        sessionActivityToastQueue.configureDisplayedAccounts(visible.map(\.id))
        updateHiddenAccountsSettingsAccess(isHidden: visible.isEmpty)
        notchLayoutManager.update(
            leftAccounts: QuotaClusterView.splitVisibleAccounts(visible, side: .left),
            rightAccounts: QuotaClusterView.splitVisibleAccounts(visible, side: .right),
            showAccountLabels: preferences.showAccountLabels,
            accountDisplayNames: preferences.accountDisplayNames,
            onRefresh: { [weak self] account in
                self?.refreshAccount(account.id)
            },
            onSettings: { [weak self] in
                self?.openSettings()
            }
        )
    }

    /// 공용 새로고침에서 할당량 조회 후 최신 계정 식별자로 토큰 사용량 갱신
    private func refreshAccount(_ id: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.accountStore.refresh(accountID: id)
            guard let account = self.accountStore.state(for: id) else { return }
            await AccountTokenUsageStore.shared.refresh(for: account, force: true)?.value
        }
    }

    private func loadSessionActivity(_ account: AccountState) async -> SessionActivitySnapshot {
        guard let home = accountStore.configs.first(where: { $0.id == account.id })?.configuredHome else {
            return .unavailable(accountID: account.id)
        }
        return await sessionActivityProvider.snapshot(accountID: account.id, home: home)
    }

    /// 확인한 계정 설정으로 리셋권 사용 후 서버 한도·잔여 개수 재조회
    private func consumeResetCredit(
        _ account: AccountState, creditID: String, attempt: String
    ) async -> Result<ResetCreditOutcome, CodexQuotaServiceError> {
        guard let config = accountStore.configs.first(where: { $0.id == account.id }),
              config.isConfigured,
              accountStore.state(for: account.id)?.configurationGeneration == account.configurationGeneration
        else { return .failure(.notConfigured) }
        let result = await CodexQuotaService().consumeResetCredit(
            for: config, creditID: creditID, idempotencyKey: attempt
        )
        if accountStore.configs.first(where: { $0.id == account.id }) == config,
           accountStore.state(for: account.id)?.configurationGeneration == account.configurationGeneration {
            _ = await accountStore.refreshOutcome(accountID: account.id, forceFresh: true)
        }
        return result
    }

    /// 선택 계정의 Ping 실행 후 새 한도 조회 및 Reset 변화 반환
    private func runUsageWindowProbe(
        _ account: AccountState
    ) async -> UsageWindowProbePresentationResult {
        guard runningProbeAccountIDs.insert(account.id).inserted else {
            return AccountDashboardDefaults.unavailableProbe(accountID: account.id, category: .alreadyRunning)
        }
        defer { runningProbeAccountIDs.remove(account.id) }
        guard let config = accountStore.configs.first(where: { $0.id == account.id }),
              config.isConfigured,
              accountStore.state(for: account.id)?.configurationGeneration == account.configurationGeneration
        else {
            return AccountDashboardDefaults.unavailableProbe(
                accountID: account.id,
                category: .notConfigured
            )
        }

        // Ping 이전 조회 재사용을 막고 완료 이후 한도 조회 보장
        let generation = account.configurationGeneration
        let before = accountStore.state(for: account.id) ?? account
        let result = await usageWindowProbeService.probe(config)
        let isCurrent = generation == accountStore.state(for: account.id)?.configurationGeneration
            && accountStore.configs.first(where: { $0.id == account.id }) == config
        guard result.isSuccess,
              isCurrent
        else {
            if !isCurrent {
                DiagnosticLogContext.record(.probeResultDiscarded, accountID: account.id,
                                            fields: [.reason: .identifier("configuration_changed")])
            }
            return UsageWindowProbePresentationResult(
                result: result,
                primaryResetBefore: before.primaryResetAt,
                secondaryResetBefore: before.secondaryResetAt,
                quotaRefreshSucceeded: result.isSuccess ? false : nil,
                isCurrentAccount: isCurrent
            )
        }
        UsageWindowProbeStore.shared.markConfirming(for: account)
        let confirmation = await resetTimeConfirmation.confirm(before)
        let didRefresh = confirmation.lastRefreshSucceeded
        let isStillCurrent = generation == accountStore.state(for: account.id)?.configurationGeneration
            && accountStore.configs.first(where: { $0.id == account.id }) == config
        let after = isStillCurrent ? confirmation.account : nil
        return UsageWindowProbePresentationResult(
            result: result,
            primaryResetBefore: before.primaryResetAt,
            primaryResetAfter: after?.primaryResetAt,
            secondaryResetBefore: before.secondaryResetAt,
            secondaryResetAfter: after?.secondaryResetAt,
            quotaRefreshSucceeded: didRefresh && isStillCurrent,
            refreshedAccount: after,
            isCurrentAccount: isStillCurrent && confirmation.isCurrentAccount,
            resetConfirmation: confirmation
        )
    }

    /// 서버 캐시 무효화를 위한 슬롯별 계정 경로 구성
    private static func configuredHomes(for configs: [AccountConfig]) -> [String: URL] {
        Dictionary(uniqueKeysWithValues: configs.compactMap { config in
            config.configuredHome.map { (config.id, $0) }
        })
    }

    /// 표시 계정이 없을 때 메뉴 막대의 앱 안내 아이콘 제공
    private func updateHiddenAccountsSettingsAccess(isHidden: Bool) {
        guard isHidden else {
            emptyAccountsPopover?.performClose(nil)
            emptyAccountsPopover = nil
            if let hiddenAccountsStatusItem {
                NSStatusBar.system.removeStatusItem(hiddenAccountsStatusItem)
                self.hiddenAccountsStatusItem = nil
            }
            return
        }
        if hiddenAccountsStatusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = AppBranding.menuBarIcon()
            item.button?.target = self
            item.button?.action = #selector(openEmptyAccountsInfo)
            item.button?.toolTip = "Codex Quota Checker"
            hiddenAccountsStatusItem = item
        }
        if let controller = emptyAccountsPopover?.contentViewController as? NSHostingController<EmptyAccountsView> {
            controller.rootView = makeEmptyAccountsView()
        }
    }

    /// 초기 등록 전 연결 가이드 또는 등록 완료 후 계정 상태 안내 표시
    @objc private func openEmptyAccountsInfo() {
        if preferences.requiresAccountSetup {
            openAccountSetupIfNeeded()
            return
        }
        guard let button = hiddenAccountsStatusItem?.button else { return }
        if emptyAccountsPopover?.isShown == true {
            emptyAccountsPopover?.performClose(nil)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: makeEmptyAccountsView())
        popover.contentSize = EmptyAccountsView.contentSize
        emptyAccountsPopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// 등록 상태별 설명과 설정 버튼의 공통 구성
    private func makeEmptyAccountsView() -> EmptyAccountsView {
        EmptyAccountsView(hasRegisteredAccounts: preferences.hasRegisteredAccounts) { [weak self] in
            self?.emptyAccountsPopover?.performClose(nil)
            self?.openSettings()
        }
    }
}
