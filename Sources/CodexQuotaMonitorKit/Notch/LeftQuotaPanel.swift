// 목적: 설정 순서의 앞 두 계정 표시 및 호스팅 뷰 유지
// 이용처: 노치 왼쪽 패널
// 사용방법: update로 상태 변경, 명시한 경우에만 도넛 크기 변경
import AppKit
import SwiftUI

public struct NotchPanelAppearance: Equatable, Sendable {
    /// Hex token for the NSPanel container. The panel is transparent; the
    /// black wing is drawn by `NotchClusterBackgroundShape` in SwiftUI.
    public let backgroundHex: String
    public let contentBackgroundHex: String
    public let isOpaque: Bool
    public let hasShadow: Bool
    public let borderWidth: CGFloat

    public init(
        backgroundHex: String,
        contentBackgroundHex: String = "#000000",
        isOpaque: Bool,
        hasShadow: Bool,
        borderWidth: CGFloat
    ) {
        self.backgroundHex = backgroundHex
        self.contentBackgroundHex = contentBackgroundHex
        self.isOpaque = isOpaque
        self.hasShadow = hasShadow
        self.borderWidth = borderWidth
    }

    public static let black = NotchPanelAppearance(
        backgroundHex: "#00000000",
        contentBackgroundHex: "#000000",
        isOpaque: false,
        hasShadow: false,
        borderWidth: 0
    )
}

/// Pure policy seam for the AppKit frame-constraining hook.
public enum NotchPanelFramePolicy {
    public static func frameAfterConstraint(
        requestedFrame: CGRect,
        constrainedFrame: CGRect
    ) -> CGRect {
        // Auxiliary top-area panels intentionally live outside visibleFrame.
        // AppKit documents that subclasses may override this hook to prevent
        // its default visible-frame adjustment.
        _ = constrainedFrame
        return requestedFrame
    }
}

/// Common transparent, non-activating panel behavior for notch clusters. The
/// SwiftUI content supplies the solid black wing and side-specific corners.
@MainActor
open class NotchQuotaPanel: NSPanel {
    public override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        configurePanel()
    }

    open override var canBecomeKey: Bool { false }
    open override var canBecomeMain: Bool { false }

    open override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // The frame is derived from NSScreen auxiliaryTop*Area in global
        // coordinates. This specialized panel must not be moved below the
        // menu bar by NSWindow's visibleFrame constraint pass.
        _ = screen
        return frameRect
    }

    /// Semantic wrapper for the manager's explicitly calculated auxiliary
    /// frame. Constraint handling is unconditional in the override above.
    public func setAuxiliaryFrame(_ frame: NSRect, display: Bool) {
        setFrame(frame, display: display)
    }

    public func install<Content: View>(_ view: Content) {
        let hostingView = NSHostingView(rootView: view)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        contentView = hostingView
    }

    private func configurePanel() {
        isOpaque = NotchPanelAppearance.black.isOpaque
        backgroundColor = .clear
        hasShadow = NotchPanelAppearance.black.hasShadow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        isFloatingPanel = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // Keep the final level assignment after all panel flags. A floating
        // panel level would sit behind the menu-bar window and lose mouse
        // hit-testing even when the panel is ordered front regardless.
        level = .statusBar
    }
}

/// 설정 순서의 앞 두 계정을 표시하는 왼쪽 노치 패널
@MainActor
public final class LeftQuotaPanel: NotchQuotaPanel {
    public private(set) var accounts: [AccountState]
    public private(set) var accountDisplayNames: [String: String] = [:]
    public let serviceStatus: OpenAIServiceStatusStore?
    public let tokenUsagePreferences: PreferencesStore?
    public private(set) var menuBarHeight: CGFloat
    public private(set) var diameterOverride: CGFloat?
    public private(set) var displayStyle: NotchDisplayStyle
    public private(set) var showAccountLabels: Bool
    /// Stable model observed by the single hosting root for this panel.
    public let activityPresentation: NotchActivityPresentationModel
    public var activityToast: SessionActivityToast? {
        activityPresentation.displayedToast
    }
    public var activityToastWidth: CGFloat? {
        activityPresentation.displayedWidth
    }
    public var onRefresh: (AccountState) -> Void
    public var onSettings: () -> Void
    public var loadSessionActivity: SessionActivityLoader
    public var loadCachedTokenUsage: TokenUsageSnapshotLookup
    public var refreshTokenUsage: TokenUsageSnapshotRefresh
    public var consumeResetCredit: ResetCreditRunner
    public var runUsageWindowProbe: UsageWindowProbeRunner
    public var onClose: () -> Void

    public init(
        accounts: [AccountState] = [],
        menuBarHeight: CGFloat = 24,
        diameterOverride: CGFloat? = nil,
        displayStyle: NotchDisplayStyle = .ring,
        showAccountLabels: Bool = false,
        onRefresh: @escaping (AccountState) -> Void = { _ in },
        onSettings: @escaping () -> Void = {},
        loadSessionActivity: @escaping SessionActivityLoader = { account in
            .unavailable(accountID: account.id)
        },
        loadCachedTokenUsage: @escaping TokenUsageSnapshotLookup = AccountDashboardDefaults.emptyTokenUsageLookup,
        refreshTokenUsage: @escaping TokenUsageSnapshotRefresh = AccountDashboardDefaults.unavailableTokenUsageRefresh,
        consumeResetCredit: @escaping ResetCreditRunner = ResetCreditDefaults.unavailable,
        runUsageWindowProbe: @escaping UsageWindowProbeRunner = { account in
            AccountDashboardDefaults.unavailableProbe(accountID: account.id)
        },
        onClose: @escaping () -> Void = {},
        activityToast: SessionActivityToast? = nil,
        activityToastWidth: CGFloat? = nil,
        activityPresentation: NotchActivityPresentationModel? = nil,
        serviceStatus: OpenAIServiceStatusStore? = nil,
        tokenUsagePreferences: PreferencesStore? = nil
    ) {
        self.accounts = accounts
        self.serviceStatus = serviceStatus
        self.tokenUsagePreferences = tokenUsagePreferences
        self.menuBarHeight = menuBarHeight
        self.diameterOverride = diameterOverride
        self.displayStyle = displayStyle
        self.showAccountLabels = showAccountLabels
        self.activityPresentation = activityPresentation ?? NotchActivityPresentationModel(
            toast: activityToast,
            width: activityToastWidth
        )
        self.onRefresh = onRefresh
        self.onSettings = onSettings
        self.loadSessionActivity = loadSessionActivity
        self.loadCachedTokenUsage = loadCachedTokenUsage
        self.refreshTokenUsage = refreshTokenUsage
        self.consumeResetCredit = consumeResetCredit
        self.runUsageWindowProbe = runUsageWindowProbe
        self.onClose = onClose
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        update(
            accounts: accounts,
            menuBarHeight: menuBarHeight,
            diameterOverride: diameterOverride,
            displayStyle: displayStyle,
            showAccountLabels: showAccountLabels,
            onRefresh: onRefresh,
            onSettings: onSettings,
            loadSessionActivity: loadSessionActivity,
            loadCachedTokenUsage: loadCachedTokenUsage,
            refreshTokenUsage: refreshTokenUsage,
            consumeResetCredit: consumeResetCredit,
            runUsageWindowProbe: runUsageWindowProbe,
            onClose: onClose
        )
    }

    /// 계정 상태 갱신 및 기존 호스팅 뷰·미지정 도넛 크기 유지
    public func update(
        accounts: [AccountState],
        menuBarHeight: CGFloat? = nil,
        diameterOverride: CGFloat? = nil,
        displayStyle: NotchDisplayStyle? = nil,
        showAccountLabels: Bool? = nil,
        accountDisplayNames: [String: String]? = nil,
        onRefresh: ((AccountState) -> Void)? = nil,
        onSettings: (() -> Void)? = nil,
        loadSessionActivity: SessionActivityLoader? = nil,
        loadCachedTokenUsage: TokenUsageSnapshotLookup? = nil,
        refreshTokenUsage: TokenUsageSnapshotRefresh? = nil,
        consumeResetCredit: ResetCreditRunner? = nil,
        runUsageWindowProbe: UsageWindowProbeRunner? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.accounts = accounts
        if let accountDisplayNames { self.accountDisplayNames = accountDisplayNames }
        if let menuBarHeight { self.menuBarHeight = menuBarHeight }
        if let diameterOverride { self.diameterOverride = diameterOverride }
        if let displayStyle { self.displayStyle = displayStyle }
        if let showAccountLabels { self.showAccountLabels = showAccountLabels }
        if let onRefresh { self.onRefresh = onRefresh }
        if let onSettings { self.onSettings = onSettings }
        if let loadSessionActivity { self.loadSessionActivity = loadSessionActivity }
        if let loadCachedTokenUsage { self.loadCachedTokenUsage = loadCachedTokenUsage }
        if let refreshTokenUsage { self.refreshTokenUsage = refreshTokenUsage }
        if let consumeResetCredit { self.consumeResetCredit = consumeResetCredit }
        if let runUsageWindowProbe { self.runUsageWindowProbe = runUsageWindowProbe }
        if let onClose { self.onClose = onClose }
        installCluster()
    }

    /// Host seam for the queue's current left-lane value. The manager supplies
    /// the clamped width during relayout; callers that do not have geometry
    /// can omit it and use the pure text estimate.
    public func setActivityToast(
        _ toast: SessionActivityToast?,
        width: CGFloat? = nil
    ) {
        activityPresentation.setToast(toast, width: width)
    }

    /// Updates only the current displayed width after pure notch geometry
    /// clamps it to an auxiliary area. This never restarts a toast lifecycle.
    public func setActivityToastWidth(_ width: CGFloat?) {
        activityPresentation.setDisplayedWidth(width)
    }

    /// Rebuilds the SwiftUI root with the host-provided popover activity
    /// loader without changing panel geometry or quota callbacks.
    public func setSessionActivityLoader(_ loader: @escaping SessionActivityLoader) {
        loadSessionActivity = loader
        installCluster()
    }

    /// Installs the account dashboard contracts once. Subsequent quota/state
    /// renders retain these closures because `update` only replaces values
    /// supplied by its optional arguments.
    public func setDashboardCallbacks(
        loadCachedTokenUsage: @escaping TokenUsageSnapshotLookup,
        refreshTokenUsage: @escaping TokenUsageSnapshotRefresh,
        consumeResetCredit: @escaping ResetCreditRunner = ResetCreditDefaults.unavailable,
        runUsageWindowProbe: @escaping UsageWindowProbeRunner,
        onClose: @escaping () -> Void = {}
    ) {
        self.loadCachedTokenUsage = loadCachedTokenUsage
        self.refreshTokenUsage = refreshTokenUsage
        self.consumeResetCredit = consumeResetCredit
        self.runUsageWindowProbe = runUsageWindowProbe
        self.onClose = onClose
        installCluster()
    }

    private func installCluster() {
        let root = QuotaClusterView(
            accounts: accounts,
            side: .left,
            menuBarHeight: menuBarHeight,
            diameterOverride: diameterOverride,
            displayStyle: displayStyle,
            showAccountLabels: showAccountLabels,
            onRefresh: onRefresh,
            onSettings: onSettings,
            loadSessionActivity: loadSessionActivity,
            loadCachedTokenUsage: loadCachedTokenUsage,
            refreshTokenUsage: refreshTokenUsage,
            consumeResetCredit: consumeResetCredit,
            runUsageWindowProbe: runUsageWindowProbe,
            onClose: onClose,
            activityPresentation: activityPresentation,
            serviceStatus: serviceStatus,
            accountDisplayNames: accountDisplayNames, tokenUsagePreferences: tokenUsagePreferences
        )
        if let activityHostingView {
            activityHostingView.rootView = root
            return
        }

        let hostingView = NSHostingView(rootView: root)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        activityHostingView = hostingView
        contentView = hostingView
    }

    private var activityHostingView: NSHostingView<QuotaClusterView>?
}
