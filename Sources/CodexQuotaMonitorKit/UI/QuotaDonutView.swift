// 목적: 한도 도넛 표시 및 조회 중 마지막 한도 유지
// 이용처: 메뉴 막대와 계정 상세 화면
// 사용방법: AccountState 전달, 최초 조회에만 로딩 애니메이션 표시
import Foundation
import SwiftUI

/// The visual state used by a quota donut. Account-specific error text remains
/// in `AccountState` and is shown by the detail view.
public enum QuotaDonutState: Equatable, Sendable {
    case value(Double)
    case fiveHourOnly(Double)
    case timedOut(Double)
    case transientError(Double)
    case notConfigured
    case loading
    case loginRequired
    case error

    public init(account: AccountState) {
        switch account.status {
        case .notConfigured:
            self = .notConfigured
        case .loading:
            if let remaining = account.overallRemainingPercent {
                self = .value(QuotaColors.clampedPercent(remaining))
            } else if let remaining = account.fiveHourRemainingPercent {
                self = .fiveHourOnly(QuotaColors.clampedPercent(remaining))
            } else {
                self = account.isWaitingForRefresh ? .notConfigured : .loading
            }
        case .loginRequired:
            self = .loginRequired
        case .normal:
            if let remainingPercent = account.overallRemainingPercent {
                self = .value(QuotaColors.clampedPercent(remainingPercent))
            } else if let fiveHour = account.fiveHourRemainingPercent {
                self = .fiveHourOnly(QuotaColors.clampedPercent(fiveHour))
            } else {
                self = .error
            }
        case .timeout:
            if let remainingPercent = account.overallRemainingPercent {
                self = .timedOut(QuotaColors.clampedPercent(remainingPercent))
            } else if account.fiveHourRemainingPercent != nil {
                self = .timedOut(0)
            } else {
                self = .error
            }
        case .codexNotFound:
            self = .error
        case .error:
            if let remainingPercent = account.overallRemainingPercent {
                self = .transientError(QuotaColors.clampedPercent(remainingPercent))
            } else if account.fiveHourRemainingPercent != nil {
                self = .transientError(0)
            } else {
                self = .error
            }
        }
    }

    public var centerSymbol: String? {
        switch self {
        case .value, .fiveHourOnly, .timedOut, .transientError, .notConfigured, .loading:
            return nil
        case .loginRequired:
            return "!"
        case .error:
            return "×"
        }
    }

    public var percent: Double? {
        switch self {
        case let .value(value), let .timedOut(value), let .transientError(value):
            return QuotaColors.clampedPercent(value)
        case .fiveHourOnly, .notConfigured, .loading, .loginRequired, .error:
            return nil
        }
    }

    public var ringColor: QuotaRGB? {
        switch self {
        case let .value(value):
            return QuotaColors.color(for: value)
        case .fiveHourOnly:
            return nil
        case .timedOut, .transientError, .error:
            return QuotaColors.critical
        case .notConfigured, .loading, .loginRequired:
            return nil
        }
    }

    public var showsErrorRing: Bool {
        switch self {
        case .timedOut, .transientError, .error:
            return true
        case .value, .fiveHourOnly, .notConfigured, .loading, .loginRequired:
            return false
        }
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// Pure display mapping: the center and ring intentionally consume different
/// quota windows so tests can guard against accidentally swapping them.
public struct QuotaDonutPresentation: Equatable, Sendable {
    public let centerPercent: Double?
    public let ringPercent: Double?
    public let ringColor: QuotaRGB?

    public init(account: AccountState) {
        switch account.status {
        case .normal, .loading, .timeout, .error:
            centerPercent = Self.centerPercent(
                fiveHour: account.fiveHourRemainingPercent,
                overall: account.overallRemainingPercent
            )
            ringPercent = account.overallRemainingPercent.map(QuotaColors.clampedPercent)
        case .notConfigured, .loginRequired, .codexNotFound:
            centerPercent = nil
            ringPercent = nil
        }

        if account.status == .timeout || account.status == .error {
            ringColor = QuotaColors.critical
        } else {
            ringColor = ringPercent.map { QuotaColors.color(for: $0) }
        }
    }

    public func trackColor(for appearance: QuotaAppearance) -> QuotaRGB {
        ringPercent == 0
            ? QuotaColors.white
            : QuotaColors.trackColor(for: appearance)
    }

    private static func centerPercent(fiveHour: Double?, overall: Double?) -> Double? {
        let normalizedOverall = overall.map(QuotaColors.clampedPercent)
        if normalizedOverall == 0 {
            return 0
        }
        if let fiveHour {
            return QuotaColors.clampedPercent(fiveHour)
        }
        return normalizedOverall
    }
}

/// The minimal loading-animation seam shared by the renderer and pure tests.
public enum QuotaLoadingAnimationPhase: Equatable, Sendable {
    case idle
    case animating

    public init(isLoading: Bool) {
        self = isLoading ? .animating : .idle
    }
}

public enum QuotaLoadingAnimationAction: Equatable, Sendable {
    case none
    case start
    case stop
}

/// Tiny transition state machine for loading animation lifecycle. Repeated
/// loading snapshots do not restart the animation; leaving loading resets it.
public struct QuotaLoadingAnimationState: Equatable, Sendable {
    public private(set) var phase: QuotaLoadingAnimationPhase = .idle
    public private(set) var startCount = 0

    public init() {}

    @discardableResult
    public mutating func transition(isLoading: Bool) -> QuotaLoadingAnimationAction {
        switch (phase, isLoading) {
        case (.idle, true):
            phase = .animating
            startCount += 1
            return .start
        case (.animating, true):
            return .none
        case (.animating, false):
            phase = .idle
            return .stop
        case (.idle, false):
            return .none
        }
    }

    public mutating func reset() {
        phase = .idle
    }
}

public enum QuotaDonutMetrics {
    public static let ringWidth: CGFloat = 3.5
    public static let hoverScale: CGFloat = 1.07
    public static let minimumDiameter: CGFloat = 20
    public static let maximumDiameter: CGFloat = 22
    public static let accountSpacing: CGFloat = 8

    /// Keeps a menu-bar donut between the design's 20–22 pt bounds.
    public static func diameter(forMenuBarHeight menuBarHeight: CGFloat) -> CGFloat {
        guard menuBarHeight.isFinite else { return minimumDiameter }
        return min(maximumDiameter, max(minimumDiameter, menuBarHeight - 2))
    }

    /// Compact menu-bar content uses digits only so 100 remains legible inside
    /// a 20–22pt ring. Tooltip/detail presentation keeps the percent sign.
    public static func compactValueText(_ value: Double) -> String {
        String(format: "%.0f", QuotaColors.clampedPercent(value))
    }

    /// Explicit text colors for surfaces whose background is fixed outside
    /// the window's color-scheme environment, such as the black notch.
    public static func centerTextColor(for appearance: QuotaAppearance) -> QuotaRGB {
        appearance == .dark
            ? QuotaRGB(red: 0xFF, green: 0xFF, blue: 0xFF)
            : QuotaRGB(red: 0x00, green: 0x00, blue: 0x00)
    }
}

/// A compact, clickable quota donut intended for menu-bar/notch-adjacent use.
public struct QuotaDonutView: View {
    public let account: AccountState
    public let menuBarHeight: CGFloat
    public let diameterOverride: CGFloat?
    public let displayStyle: NotchDisplayStyle
    public let showAccountLabels: Bool
    public let onRefresh: () -> Void
    public let onSettings: () -> Void
    public let loadSessionActivity: SessionActivityLoader
    public let loadCachedTokenUsage: TokenUsageSnapshotLookup
    public let refreshTokenUsage: TokenUsageSnapshotRefresh
    public let consumeResetCredit: ResetCreditRunner
    public let runUsageWindowProbe: UsageWindowProbeRunner
    public let onClose: () -> Void

    public let tokenUsagePreferences: PreferencesStore?

    @State private var isHovered = false
    @State private var isDetailPresented = false
    @Environment(\.accountDisplayNames) private var accountDisplayNames
    @Environment(\.openAIServiceStatus) private var serviceStatus

    public init(
        account: AccountState,
        menuBarHeight: CGFloat = 24,
        diameterOverride: CGFloat? = nil,
        displayStyle: NotchDisplayStyle = .ring,
        showAccountLabels: Bool = false,
        onRefresh: @escaping () -> Void = {},
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
        tokenUsagePreferences: PreferencesStore? = nil
    ) {
        self.account = account
        self.menuBarHeight = menuBarHeight
        self.diameterOverride = diameterOverride
        self.displayStyle = displayStyle
        self.showAccountLabels = showAccountLabels
        self.onRefresh = onRefresh
        self.onSettings = onSettings
        self.loadSessionActivity = loadSessionActivity
        self.loadCachedTokenUsage = loadCachedTokenUsage
        self.refreshTokenUsage = refreshTokenUsage
        self.consumeResetCredit = consumeResetCredit
        self.runUsageWindowProbe = runUsageWindowProbe
        self.onClose = onClose
        self.tokenUsagePreferences = tokenUsagePreferences
    }

    public var body: some View {
        Button {
            isDetailPresented = true
        } label: {
            NotchQuotaGraphic(
                account: account,
                style: displayStyle,
                diameter: diameterOverride ?? QuotaDonutMetrics.diameter(forMenuBarHeight: menuBarHeight),
                showAccountLabel: showAccountLabels
            )
            .contentShape(RoundedRectangle(cornerRadius: displayStyle == .ring ? 100 : 0))
        }
        .buttonStyle(.appGraphic)
        .scaleEffect(isHovered ? QuotaDonutMetrics.hoverScale : 1)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
        .help(tooltip)
        .accessibilityLabel(tooltip)
        .overlay {
            TransientPopoverPresenter(isPresented: $isDetailPresented) {
                AccountDetailView(
                    account: account,
                    onRefresh: onRefresh,
                    onSettings: onSettings,
                    loadSessionActivity: loadSessionActivity,
                    loadCachedTokenUsage: loadCachedTokenUsage,
                    refreshTokenUsage: refreshTokenUsage,
                    consumeResetCredit: consumeResetCredit,
                    runUsageWindowProbe: runUsageWindowProbe,
                    onClose: {
                        isDetailPresented = false
                        onClose()
                    },
                    serviceStatus: serviceStatus, tokenUsagePreferences: tokenUsagePreferences
                )
                .environment(\.accountDisplayNames, accountDisplayNames)
                .id(account.configurationGeneration)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
    }

    private var tooltip: String {
        let state = QuotaDonutState(account: account)
        let presentation = QuotaDonutPresentation(account: account)
        let fiveHour = account.fiveHourRemainingPercent.map(Self.percentText) ?? "—"
        let overall = presentation.ringPercent.map(Self.percentText) ?? "—"
        let name = AccountDisplayName.resolved(accountDisplayNames[account.id], slotID: account.id)
        let quotaText = "5h \(fiveHour) · Overall \(overall)"
        if account.status == .loading && account.isWaitingForRefresh {
            return "\(name) · \(quotaText) · 조회 대기"
        }
        switch state {
        case .value, .fiveHourOnly:
            return "\(name) · \(quotaText)"
        case .timedOut:
            return "\(name) · \(quotaText) · Timed out"
        case .transientError:
            return "\(name) · \(quotaText) · Error"
        case .loading:
            return "\(name) · Loading"
        case .notConfigured:
            return "\(name) · Not configured"
        case .loginRequired:
            return "\(name) · Login required"
        case .error:
            return "\(name) · Error"
        }
    }

    static func percentText(_ value: Double) -> String {
        String(format: "%.0f%%", QuotaColors.clampedPercent(value))
    }
}
