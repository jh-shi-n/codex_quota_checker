// 목적: 표시 계정 수에 맞춘 노치 패널 배치와 안정적 갱신
// 이용처: 메뉴 막대 좌우 계정 패널
// 사용방법: update 이후 show 호출, 화면 변경 시 relayout 호출
import AppKit
import Foundation

/// Pure per-side visibility policy shared by relayout/show control flow.
public enum NotchPanelVisibility {
    public static func isDisplayable(accountCount: Int, resolvedDiameter: CGFloat) -> Bool {
        accountCount > 0 && resolvedDiameter.isFinite && resolvedDiameter > 0
    }

    public static func isCenterBridgeDisplayable(
        leftAccountCount: Int,
        rightAccountCount: Int,
        frame: CGRect
    ) -> Bool {
        leftAccountCount > 0 && rightAccountCount > 0 &&
            frame.origin.x.isFinite && frame.origin.y.isFinite &&
            frame.width.isFinite && frame.width > 0 &&
            frame.height.isFinite && frame.height > 0
    }
}

/// Owns one NotificationCenter token and removes it exactly once when the
/// owner is released. This class is intentionally not actor-isolated so the
/// manager's automatic destruction does not cross main-actor isolation.
private final class ScreenObserverTokenOwner: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(token: NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}

/// Owns the two notch-adjacent panels and recomputes their frames when the
/// screen configuration changes. All UI/window work is main-actor isolated.
@MainActor
public final class NotchLayoutManager: NSObject {
    public let leftPanel: LeftQuotaPanel
    public let centerPanel: CenterBridgePanel
    public let rightPanel: RightQuotaPanel
    public var screenProvider: @MainActor () -> NSScreen?
    public private(set) var currentLayout: NotchLayout?
    public private(set) var displayStyle: NotchDisplayStyle
    public private(set) var showAccountLabels: Bool
    public private(set) var leftActivityToast: SessionActivityToast?
    public private(set) var rightActivityToast: SessionActivityToast?

    private var observerOwner: ScreenObserverTokenOwner?
    private var isRelayoutInProgress = false
    private var suppressPresentationRelayout = false
    private var isShown = false

    public init(
        screenProvider: @escaping @MainActor () -> NSScreen? = {
            NotchGeometry.primaryScreen(from: NSScreen.screens)
        },
        displayStyle: NotchDisplayStyle = .ring,
        showAccountLabels: Bool = false,
        onRefresh: @escaping (AccountState) -> Void = { _ in },
        onSettings: @escaping () -> Void = {},
        loadCachedTokenUsage: @escaping TokenUsageSnapshotLookup = AccountDashboardDefaults.emptyTokenUsageLookup,
        refreshTokenUsage: @escaping TokenUsageSnapshotRefresh = AccountDashboardDefaults.unavailableTokenUsageRefresh,
        consumeResetCredit: @escaping ResetCreditRunner = ResetCreditDefaults.unavailable,
        runUsageWindowProbe: @escaping UsageWindowProbeRunner = { account in
            AccountDashboardDefaults.unavailableProbe(accountID: account.id)
        },
        onClose: @escaping () -> Void = {},
        serviceStatus: OpenAIServiceStatusStore? = nil,
        tokenUsagePreferences: PreferencesStore? = nil
    ) {
        self.screenProvider = screenProvider
        self.displayStyle = displayStyle
        self.showAccountLabels = showAccountLabels
        self.leftPanel = LeftQuotaPanel(
            displayStyle: displayStyle,
            showAccountLabels: showAccountLabels,
            onRefresh: onRefresh,
            onSettings: onSettings,
            loadCachedTokenUsage: loadCachedTokenUsage,
            refreshTokenUsage: refreshTokenUsage,
            consumeResetCredit: consumeResetCredit,
            runUsageWindowProbe: runUsageWindowProbe,
            onClose: onClose,
            serviceStatus: serviceStatus, tokenUsagePreferences: tokenUsagePreferences
        )
        self.centerPanel = CenterBridgePanel()
        self.rightPanel = RightQuotaPanel(
            displayStyle: displayStyle,
            showAccountLabels: showAccountLabels,
            onRefresh: onRefresh,
            onSettings: onSettings,
            loadCachedTokenUsage: loadCachedTokenUsage,
            refreshTokenUsage: refreshTokenUsage,
            consumeResetCredit: consumeResetCredit,
            runUsageWindowProbe: runUsageWindowProbe,
            onClose: onClose,
            serviceStatus: serviceStatus, tokenUsagePreferences: tokenUsagePreferences
        )
        super.init()
        self.leftPanel.activityPresentation.onPresentationChange = { [weak self] in
            self?.presentationDidChange()
        }
        self.rightPanel.activityPresentation.onPresentationChange = { [weak self] in
            self?.presentationDidChange()
        }
    }

    /// 계정 상태 반영 및 표시 수·크기 변경 시에만 패널 재배치
    public func update(
        leftAccounts: [AccountState],
        rightAccounts: [AccountState],
        menuBarHeight: CGFloat? = nil,
        displayStyle: NotchDisplayStyle? = nil,
        showAccountLabels: Bool? = nil,
        accountDisplayNames: [String: String]? = nil,
        onRefresh: ((AccountState) -> Void)? = nil,
        onSettings: (() -> Void)? = nil
    ) {
        let needsRelayout = currentLayout == nil
            || leftAccounts.count != leftPanel.accounts.count
            || rightAccounts.count != rightPanel.accounts.count
            || menuBarHeight != nil
            || (displayStyle != nil && displayStyle != self.displayStyle)
        if let displayStyle { self.displayStyle = displayStyle }
        if let showAccountLabels {
            self.showAccountLabels = showAccountLabels
        }
        leftPanel.update(
            accounts: leftAccounts,
            menuBarHeight: menuBarHeight,
            displayStyle: self.displayStyle,
            showAccountLabels: self.showAccountLabels,
            accountDisplayNames: accountDisplayNames,
            onRefresh: onRefresh,
            onSettings: onSettings
        )
        rightPanel.update(
            accounts: rightAccounts,
            menuBarHeight: menuBarHeight,
            displayStyle: self.displayStyle,
            showAccountLabels: self.showAccountLabels,
            accountDisplayNames: accountDisplayNames,
            onRefresh: onRefresh,
            onSettings: onSettings
        )
        if needsRelayout || accountDisplayNames != nil { relayout() }
    }

    /// Updates the queue-owned current value for each independent lane. The
    /// queue/AppDelegate remain responsible for choosing and clearing values;
    /// this seam only installs the host-provided presentation state and
    /// recomputes the affected outward panel widths.
    public func updateActivityToasts(
        left: SessionActivityToast?,
        right: SessionActivityToast?
    ) {
        leftActivityToast = left
        rightActivityToast = right
        suppressPresentationRelayout = true
        leftPanel.setActivityToast(left)
        rightPanel.setActivityToast(right)
        suppressPresentationRelayout = false
        _ = relayout()
    }

    /// Installs dashboard data/action contracts on both side panels. Keeping
    /// this as a host setter prevents a quota render from replacing the
    /// closures when the SwiftUI root is rebuilt.
    public func setDashboardCallbacks(
        loadCachedTokenUsage: @escaping TokenUsageSnapshotLookup,
        refreshTokenUsage: @escaping TokenUsageSnapshotRefresh,
        consumeResetCredit: @escaping ResetCreditRunner = ResetCreditDefaults.unavailable,
        runUsageWindowProbe: @escaping UsageWindowProbeRunner,
        onClose: @escaping () -> Void = {}
    ) {
        leftPanel.setDashboardCallbacks(
            loadCachedTokenUsage: loadCachedTokenUsage,
            refreshTokenUsage: refreshTokenUsage,
            consumeResetCredit: consumeResetCredit,
            runUsageWindowProbe: runUsageWindowProbe,
            onClose: onClose
        )
        rightPanel.setDashboardCallbacks(
            loadCachedTokenUsage: loadCachedTokenUsage,
            refreshTokenUsage: refreshTokenUsage,
            consumeResetCredit: consumeResetCredit,
            runUsageWindowProbe: runUsageWindowProbe,
            onClose: onClose
        )
    }

    /// Recomputes frames from the current screen's auxiliary top areas.
    @discardableResult
    public func relayout() -> Bool {
        guard let screen = screenProvider() else {
            hidePanelsAndClearLayout()
            return false
        }
        return relayout(for: screen)
    }

    /// Injectable variant used by callers that already know the target screen.
    @discardableResult
    public func relayout(for screen: NSScreen) -> Bool {
        guard !isRelayoutInProgress else { return currentLayout != nil }
        isRelayoutInProgress = true
        defer { isRelayoutInProgress = false }

        let layout = NotchGeometry.layout(for: screen)
        currentLayout = layout

        let effectiveMenuBarHeight = max(layout.leftArea.height, layout.rightArea.height)
        let requestedDiameter = QuotaDonutMetrics.diameter(forMenuBarHeight: effectiveMenuBarHeight)
        let leftDiameter = layout.resolvedDiameter(
            side: .left,
            itemCount: leftPanel.accounts.count,
            style: displayStyle,
            diameter: requestedDiameter,
            spacing: QuotaDonutMetrics.accountSpacing
        )
        let rightDiameter = layout.resolvedDiameter(
            side: .right,
            itemCount: rightPanel.accounts.count,
            style: displayStyle,
            diameter: requestedDiameter,
            spacing: QuotaDonutMetrics.accountSpacing
        )

        if leftPanel.menuBarHeight != effectiveMenuBarHeight || leftPanel.diameterOverride != leftDiameter {
            leftPanel.update(
                accounts: leftPanel.accounts,
                menuBarHeight: effectiveMenuBarHeight,
                diameterOverride: leftDiameter,
                displayStyle: self.displayStyle,
                showAccountLabels: self.showAccountLabels
            )
        }
        if rightPanel.menuBarHeight != effectiveMenuBarHeight || rightPanel.diameterOverride != rightDiameter {
            rightPanel.update(
                accounts: rightPanel.accounts,
                menuBarHeight: effectiveMenuBarHeight,
                diameterOverride: rightDiameter,
                displayStyle: self.displayStyle,
                showAccountLabels: self.showAccountLabels
            )
        }

        let leftDisplayedToast = leftPanel.activityToast
        let rightDisplayedToast = rightPanel.activityToast
        let leftToastWidth = layout.resolvedToastWidth(
            side: .left,
            itemCount: leftPanel.accounts.count,
            style: displayStyle,
            diameter: leftDiameter,
            spacing: QuotaDonutMetrics.accountSpacing,
            requestedWidth: NotchActivityToastMetrics.requiredWidth(for: leftDisplayedToast, names: leftPanel.accountDisplayNames)
        )
        let rightToastWidth = layout.resolvedToastWidth(
            side: .right,
            itemCount: rightPanel.accounts.count,
            style: displayStyle,
            diameter: rightDiameter,
            spacing: QuotaDonutMetrics.accountSpacing,
            requestedWidth: NotchActivityToastMetrics.requiredWidth(for: rightDisplayedToast, names: rightPanel.accountDisplayNames)
        )

        let leftFrame = layout.panelFrame(
            side: .left,
            itemCount: leftPanel.accounts.count,
            style: displayStyle,
            diameter: leftDiameter,
            spacing: QuotaDonutMetrics.accountSpacing,
            toastWidth: leftToastWidth
        )
        let rightFrame = layout.panelFrame(
            side: .right,
            itemCount: rightPanel.accounts.count,
            style: displayStyle,
            diameter: rightDiameter,
            spacing: QuotaDonutMetrics.accountSpacing,
            toastWidth: rightToastWidth
        )
        let centerFrame = layout.centerBridgeFrame

        if leftDisplayedToast != nil && leftPanel.activityToastWidth != leftToastWidth {
            leftPanel.setActivityToastWidth(leftToastWidth)
        }
        if rightDisplayedToast != nil && rightPanel.activityToastWidth != rightToastWidth {
            rightPanel.setActivityToastWidth(rightToastWidth)
        }

        if !NotchPanelVisibility.isDisplayable(
            accountCount: leftPanel.accounts.count,
            resolvedDiameter: leftDiameter
        ) {
            leftPanel.orderOut(nil)
        } else {
            if leftPanel.frame != leftFrame {
                leftPanel.setAuxiliaryFrame(leftFrame, display: true)
            }
            if isShown && !leftPanel.isVisible { leftPanel.orderFrontRegardless() }
        }
        if !NotchPanelVisibility.isDisplayable(
            accountCount: rightPanel.accounts.count,
            resolvedDiameter: rightDiameter
        ) {
            rightPanel.orderOut(nil)
        } else {
            if rightPanel.frame != rightFrame {
                rightPanel.setAuxiliaryFrame(rightFrame, display: true)
            }
            if isShown && !rightPanel.isVisible { rightPanel.orderFrontRegardless() }
        }
        if NotchPanelVisibility.isCenterBridgeDisplayable(
            leftAccountCount: leftPanel.accounts.count,
            rightAccountCount: rightPanel.accounts.count,
            frame: centerFrame
        ) {
            if centerPanel.frame != centerFrame {
                centerPanel.setAuxiliaryFrame(centerFrame, display: true)
            }
            if isShown && !centerPanel.isVisible { centerPanel.orderFrontRegardless() }
        } else {
            centerPanel.orderOut(nil)
        }
        return true
    }

    public func show() {
        isShown = true
        guard relayout(), currentLayout != nil else { return }
        if NotchPanelVisibility.isDisplayable(
            accountCount: leftPanel.accounts.count,
            resolvedDiameter: leftPanel.diameterOverride ?? 0
        ) {
            leftPanel.orderFrontRegardless()
        }
        if NotchPanelVisibility.isDisplayable(
            accountCount: rightPanel.accounts.count,
            resolvedDiameter: rightPanel.diameterOverride ?? 0
        ) {
            rightPanel.orderFrontRegardless()
        }
        if let layout = currentLayout,
           NotchPanelVisibility.isCenterBridgeDisplayable(
               leftAccountCount: leftPanel.accounts.count,
               rightAccountCount: rightPanel.accounts.count,
               frame: layout.centerBridgeFrame
           ) {
            centerPanel.orderFrontRegardless()
        }
    }

    public func hide() {
        isShown = false
        leftPanel.orderOut(nil)
        centerPanel.orderOut(nil)
        rightPanel.orderOut(nil)
    }

    public func startObservingScreenChanges() {
        guard observerOwner == nil else { return }
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                _ = self?.relayout()
            }
        }
        observerOwner = ScreenObserverTokenOwner(token: token)
    }

    public func stopObservingScreenChanges() {
        observerOwner = nil
    }

    /// Explicit public hook for app lifecycle/sleep-wake handlers.
    @discardableResult
    public func screenDidChange() -> Bool {
        relayout()
    }

    private func hidePanelsAndClearLayout() {
        leftPanel.orderOut(nil)
        centerPanel.orderOut(nil)
        rightPanel.orderOut(nil)
        currentLayout = nil
    }

    private func presentationDidChange() {
        guard !suppressPresentationRelayout, !isRelayoutInProgress else { return }
        _ = relayout()
    }
}
