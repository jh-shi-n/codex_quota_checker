// 목적: 설정 순서와 표시 계정 수에 따른 도넛 클러스터 구성
// 이용처: 좌우 노치 패널
// 사용방법: 표시 순서 배열 전달 및 splitVisibleAccounts로 좌우 분할
import Foundation
import SwiftUI

/// Pure content footprint used by both the SwiftUI cluster and notch panels.
public enum QuotaClusterMetrics {
    public static let containmentMargin: CGFloat = 0.25
    /// Black-only extension toward the physical camera/notch gap.
    public static let notchBridgeWidth: CGFloat = 8

    /// 모든 디자인에 동일한 링 한 칸과 계정 간격 적용
    public static func footprint(
        itemCount: Int,
        style: NotchDisplayStyle = .ring,
        diameter: CGFloat,
        spacing: CGFloat = QuotaDonutMetrics.accountSpacing
    ) -> CGSize {
        guard itemCount > 0 else { return .zero }
        let safeDiameter = diameter.isFinite ? max(0, diameter) : 0
        let safeSpacing = spacing.isFinite ? max(0, spacing) : 0
        return CGSize(
            width: safeDiameter * CGFloat(itemCount) + safeSpacing * CGFloat(max(0, itemCount - 1)),
            height: safeDiameter
        )
    }

    /// Extra content inset required for the rounded 3.5pt stroke and 1.07x
    /// hover scale to remain inside the black content bounds.
    public static func visualInset(
        forDiameter diameter: CGFloat,
        hoverScale: CGFloat = QuotaDonutMetrics.hoverScale,
        style: NotchDisplayStyle = .ring
    ) -> CGFloat {
        let safeDiameter = diameter.isFinite ? max(0, diameter) : 0
        let safeScale = hoverScale.isFinite ? max(1, hoverScale) : 1
        return max(
            0,
            (safeDiameter * (safeScale - 1)
                + QuotaDonutMetrics.ringWidth * safeScale) / 2
        )
    }

    public static func visualFootprint(
        itemCount: Int,
        style: NotchDisplayStyle = .ring,
        diameter: CGFloat,
        spacing: CGFloat = QuotaDonutMetrics.accountSpacing,
        hoverScale: CGFloat = QuotaDonutMetrics.hoverScale
    ) -> CGSize {
        let content = footprint(itemCount: itemCount, style: style, diameter: diameter, spacing: spacing)
        guard itemCount > 0 else { return .zero }
        let inset = visualInset(forDiameter: diameter, hoverScale: hoverScale, style: style)
        let safeMargin = containmentMargin
        return CGSize(
            width: content.width + (inset + safeMargin) * 2,
            height: content.height + (inset + safeMargin) * 2
        )
    }
}

public struct NotchClusterCornerRadii: Equatable, Sendable {
    public let topLeading: CGFloat
    public let bottomLeading: CGFloat
    public let bottomTrailing: CGFloat
    public let topTrailing: CGFloat

    public init(
        topLeading: CGFloat,
        bottomLeading: CGFloat,
        bottomTrailing: CGFloat,
        topTrailing: CGFloat
    ) {
        self.topLeading = topLeading
        self.bottomLeading = bottomLeading
        self.bottomTrailing = bottomTrailing
        self.topTrailing = topTrailing
    }

    public static func forSide(_ side: NotchSide, radius: CGFloat = 7) -> NotchClusterCornerRadii {
        let safeRadius = radius.isFinite ? max(0, radius) : 0
        switch side {
        case .left:
            return NotchClusterCornerRadii(
                topLeading: 0,
                bottomLeading: safeRadius,
                bottomTrailing: 0,
                topTrailing: 0
            )
        case .right:
            return NotchClusterCornerRadii(
                topLeading: 0,
                bottomLeading: 0,
                bottomTrailing: safeRadius,
                topTrailing: 0
            )
        }
    }
}

struct NotchClusterBackgroundShape: Shape {
    let cornerRadii: NotchClusterCornerRadii

    init(side: NotchSide, radius: CGFloat = 7) {
        self.cornerRadii = .forSide(side, radius: radius)
    }

    func path(in rect: CGRect) -> Path {
        let safeRect = rect.standardized
        let maximumRadius = min(safeRect.width, safeRect.height) / 2
        let topLeading = min(cornerRadii.topLeading, maximumRadius)
        let bottomLeading = min(cornerRadii.bottomLeading, maximumRadius)
        let bottomTrailing = min(cornerRadii.bottomTrailing, maximumRadius)
        let topTrailing = min(cornerRadii.topTrailing, maximumRadius)

        var path = Path()
        path.move(to: CGPoint(x: safeRect.minX + topLeading, y: safeRect.minY))
        path.addLine(to: CGPoint(x: safeRect.maxX - topTrailing, y: safeRect.minY))
        if topTrailing > 0 {
            path.addQuadCurve(
                to: CGPoint(x: safeRect.maxX, y: safeRect.minY + topTrailing),
                control: CGPoint(x: safeRect.maxX, y: safeRect.minY)
            )
        }
        path.addLine(to: CGPoint(x: safeRect.maxX, y: safeRect.maxY - bottomTrailing))
        if bottomTrailing > 0 {
            path.addQuadCurve(
                to: CGPoint(x: safeRect.maxX - bottomTrailing, y: safeRect.maxY),
                control: CGPoint(x: safeRect.maxX, y: safeRect.maxY)
            )
        }
        path.addLine(to: CGPoint(x: safeRect.minX + bottomLeading, y: safeRect.maxY))
        if bottomLeading > 0 {
            path.addQuadCurve(
                to: CGPoint(x: safeRect.minX, y: safeRect.maxY - bottomLeading),
                control: CGPoint(x: safeRect.minX, y: safeRect.maxY)
            )
        }
        path.addLine(to: CGPoint(x: safeRect.minX, y: safeRect.minY + topLeading))
        if topLeading > 0 {
            path.addQuadCurve(
                to: CGPoint(x: safeRect.minX + topLeading, y: safeRect.minY),
                control: CGPoint(x: safeRect.minX, y: safeRect.minY)
            )
        }
        path.closeSubpath()
        return path
    }
}

/// 설정 순서의 계정 도넛을 왼쪽부터 배치하는 노치 클러스터
public struct QuotaClusterView: View {
    public let accounts: [AccountState]
    public let accountDisplayNames: [String: String]
    public let serviceStatus: OpenAIServiceStatusStore?
    public let tokenUsagePreferences: PreferencesStore?
    public let side: NotchSide
    public let menuBarHeight: CGFloat
    public let diameterOverride: CGFloat?
    public let displayStyle: NotchDisplayStyle
    public let showAccountLabels: Bool
    public let onRefresh: (AccountState) -> Void
    public let onSettings: () -> Void
    public let loadSessionActivity: SessionActivityLoader
    public let loadCachedTokenUsage: TokenUsageSnapshotLookup
    public let refreshTokenUsage: TokenUsageSnapshotRefresh
    public let consumeResetCredit: ResetCreditRunner
    public let runUsageWindowProbe: UsageWindowProbeRunner
    public let onClose: () -> Void
    /// Stable main-actor state object supplied by the panel host. Queue
    /// lifetime and target selection remain outside this view.
    @ObservedObject public var activityPresentation: NotchActivityPresentationModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealedToastID: String?

    public var activityToast: SessionActivityToast? {
        activityPresentation.displayedToast
    }

    public var activityToastWidth: CGFloat? {
        activityPresentation.displayedWidth
    }

    public init(
        accounts: [AccountState],
        side: NotchSide,
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
        accountDisplayNames: [String: String] = [:],
        tokenUsagePreferences: PreferencesStore? = nil
    ) {
        self.tokenUsagePreferences = tokenUsagePreferences
        self.accounts = accounts
        self.accountDisplayNames = accountDisplayNames
        self.serviceStatus = serviceStatus
        self.side = side
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
        let presentation = activityPresentation ?? NotchActivityPresentationModel(
            toast: activityToast,
            width: activityToastWidth
        )
        self._activityPresentation = ObservedObject(wrappedValue: presentation)
    }

    public var body: some View {
        let activityToast = activityPresentation.displayedToast
        let isExpanded = activityToast != nil
            && revealedToastID == activityToast?.id
            && activityPresentation.phase != .exiting
        let duration = NotchActivityToastPresentation.animationDuration(isPresented: isExpanded)
        let animation: Animation = reduceMotion
            ? .easeOut(duration: duration)
            : .timingCurve(0.22, 1, 0.36, 1, duration: duration)
        HStack(spacing: 0) {
            if side == .left, let activityToast {
                NotchActivityToastView(
                    toast: activityToast,
                    side: side,
                    width: effectiveActivityToastWidth,
                    isPresented: isExpanded
                )
                .id(activityToast.id)
            }

            if side == .right {
                Color.clear.frame(width: QuotaClusterMetrics.notchBridgeWidth)
            }

            HStack(spacing: QuotaDonutMetrics.accountSpacing) {
                ForEach(Self.orderedAccounts(accounts, for: side)) { account in
                    QuotaDonutView(
                        account: account,
                        menuBarHeight: menuBarHeight,
                        diameterOverride: diameterOverride,
                        displayStyle: displayStyle,
                        showAccountLabels: showAccountLabels,
                        onRefresh: { onRefresh(account) },
                        onSettings: onSettings,
                        loadSessionActivity: loadSessionActivity,
                        loadCachedTokenUsage: loadCachedTokenUsage,
                        refreshTokenUsage: refreshTokenUsage,
                        consumeResetCredit: consumeResetCredit,
                        runUsageWindowProbe: runUsageWindowProbe,
                        onClose: onClose, tokenUsagePreferences: tokenUsagePreferences
                    )
                    .environment(\.openAIServiceStatus, serviceStatus)
                }
            }
            .frame(width: contentWidth)
            .frame(maxHeight: .infinity, alignment: .center)

            if side == .left {
                Color.clear.frame(width: QuotaClusterMetrics.notchBridgeWidth)
            }

            if side == .right, let activityToast {
                NotchActivityToastView(
                    toast: activityToast,
                    side: side,
                    width: effectiveActivityToastWidth,
                    isPresented: isExpanded
                )
                .id(activityToast.id)
            }
        }
        .frame(maxHeight: .infinity)
        .background(NotchClusterBackgroundShape(side: side).fill(Color.black))
        .clipped()
        .animation(animation, value: isExpanded)
        .task(id: activityToast?.id) {
            // 접힌 배경 배치 이후 새 알림을 펼쳐 삽입 시 폭 변화 보존
            revealedToastID = nil
            guard let id = activityToast?.id else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            revealedToastID = id
        }
        // 노치 쪽 끝 고정으로 알림 확장 중 계정 도넛의 위치 유지
        .frame(maxWidth: .infinity, alignment: side == .left ? .trailing : .leading)
        .environment(\.accountDisplayNames, accountDisplayNames)
    }

    private var contentWidth: CGFloat {
        let requestedDiameter = diameterOverride ?? QuotaDonutMetrics.diameter(forMenuBarHeight: menuBarHeight)
        return QuotaClusterMetrics.visualFootprint(
            itemCount: accounts.count,
            style: displayStyle,
            diameter: requestedDiameter,
            spacing: QuotaDonutMetrics.accountSpacing
        ).width
    }

    private var effectiveActivityToastWidth: CGFloat {
        guard let activityToast else { return 0 }
        let requested = NotchActivityToastMetrics.requiredWidth(for: activityToast, names: accountDisplayNames)
        guard let activityToastWidth else { return requested }
        guard activityToastWidth.isFinite else { return 0 }
        return min(requested, max(0, activityToastWidth))
    }

    /// 설정에서 결정한 표시 순서 보존
    public static func orderedAccounts(_ accounts: [AccountState], for side: NotchSide) -> [AccountState] {
        accounts
    }

    /// 표시 계정의 앞 두 항목을 왼쪽에, 나머지 항목을 오른쪽에 배치
    public static func splitVisibleAccounts(_ accounts: [AccountState], side: NotchSide) -> [AccountState] {
        side == .left ? Array(accounts.prefix(2)) : Array(accounts.dropFirst(2).prefix(2))
    }
}
