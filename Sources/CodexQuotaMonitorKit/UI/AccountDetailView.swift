import SwiftUI

/// 할당량 상세와 서버 계정 토큰 사용량 표시
public struct AccountDetailView: View {
    public static let minimumWidth: CGFloat = TransientPopoverSizingPolicy.contentWidth
    public static let minimumHeight: CGFloat = TransientPopoverSizingPolicy.contentHeight
    public static let popoverContentSize = TransientPopoverSizingPolicy.preferredContentSize

    public let account: AccountState
    public let onRefresh: () -> Void
    public let onSettings: () -> Void
    public let loadSessionActivity: SessionActivityLoader
    public let loadCachedTokenUsage: TokenUsageSnapshotLookup
    public let refreshTokenUsage: TokenUsageSnapshotRefresh
    public let consumeResetCredit: ResetCreditRunner
    public let runUsageWindowProbe: UsageWindowProbeRunner
    public let onClose: () -> Void
    public let serviceStatus: OpenAIServiceStatusStore?
    public let tokenUsagePreferences: PreferencesStore?

    @Environment(\.accountDisplayNames) private var accountDisplayNames
    @ObservedObject private var probeStore = UsageWindowProbeStore.shared
    @ObservedObject private var accountTokenUsageStore = AccountTokenUsageStore.shared
    @ObservedObject private var manualRequestGate = ManualRequestGate.shared

    public init(
        account: AccountState,
        onRefresh: @escaping () -> Void = {},
        onSettings: @escaping () -> Void = {},
        loadSessionActivity: @escaping SessionActivityLoader = { account in
            .unavailable(accountID: account.id)
        },
        loadCachedTokenUsage: @escaping TokenUsageSnapshotLookup = AccountDashboardDefaults.emptyTokenUsageLookup,
        refreshTokenUsage: @escaping TokenUsageSnapshotRefresh = AccountDashboardDefaults.unavailableTokenUsageRefresh,
        consumeResetCredit: @escaping ResetCreditRunner = ResetCreditDefaults.unavailable,
        runUsageWindowProbe: @escaping UsageWindowProbeRunner = AccountDetailView.defaultProbeRunner,
        onClose: @escaping () -> Void = {},
        serviceStatus: OpenAIServiceStatusStore? = nil,
        tokenUsagePreferences: PreferencesStore? = nil
    ) {
        self.account = account
        self.onRefresh = onRefresh
        self.onSettings = onSettings
        self.loadSessionActivity = loadSessionActivity
        self.loadCachedTokenUsage = loadCachedTokenUsage
        self.refreshTokenUsage = refreshTokenUsage
        self.consumeResetCredit = consumeResetCredit
        self.runUsageWindowProbe = runUsageWindowProbe
        self.onClose = onClose
        self.serviceStatus = serviceStatus
        self.tokenUsagePreferences = tokenUsagePreferences
    }

    public var tokenUsageCacheLookup: TokenUsageSnapshotLookup { loadCachedTokenUsage }
    public var tokenUsageUpdate: TokenUsageSnapshotRefresh { refreshTokenUsage }
    public var probeRunner: UsageWindowProbeRunner { runUsageWindowProbe }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                header

                AccountQuotaSection(account: displayedAccount)

                if account.provider == .codex {
                    if let tokenUsagePreferences {
                        AccountTokenUsagePreferencesView(account: account, preferences: tokenUsagePreferences)
                    } else {
                        AccountTokenUsageView(account: account, store: .shared)
                    }
                }
                accountActivity

                if account.provider == .codex { usageWindowProbeSection }

                if let errorMessage = account.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(
            minWidth: 0,
            idealWidth: Self.popoverContentSize.width,
            maxWidth: .infinity,
            minHeight: 0,
            idealHeight: Self.popoverContentSize.height,
            maxHeight: .infinity
        )
        .background(Color(red: 0.075, green: 0.085, blue: 0.10))
        .preferredColorScheme(.dark)

    }

    /// 공통 자동 전송 설정을 관찰하는 상세 화면의 시간 설정 영역 구성
    @ViewBuilder
    private var usageWindowProbeSection: some View {
        let section = UsageWindowProbeSection(
            account: displayedAccount, probe: currentProbePresentation,
            isRunning: isProbeRunning, runningStartedAt: probeStore.startedAt(for: account),
            lastExecutionAt: probeStore.lastStartedAt(for: account),
            isConfigured: displayedAccount.status != .notConfigured, onRun: runProbe,
            isConfirming: probeStore.isConfirming(for: account)
        )
        if let tokenUsagePreferences {
            UsageWindowProbePreferencesView(preferences: tokenUsagePreferences, section: section)
        } else {
            section
        }
    }

    /// 서비스별 고정 색상의 독립 배지 표시
    private var serviceBadge: some View {
        Text(account.provider.displayName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(account.provider == .claude ? Color.orange : Color.white))
            .fixedSize()
            .accessibilityLabel("사용 중인 서비스: \(account.provider.displayName)")
    }

    /// 계정 정보와 버튼에 인접한 조회 시각·상태의 2행 표시
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(AccountDisplayName.resolved(accountDisplayNames[account.id], slotID: account.id))
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(AccountDisplayName.resolved(accountDisplayNames[account.id], slotID: account.id))
                    serviceBadge
                    Text(AccountDashboardFormatting.subscriptionBadgeText(account.planType))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(SubscriptionBadgeStyle.accentColor(for: account.planType))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(SubscriptionBadgeStyle.backgroundColor(for: account.planType)))
                        .overlay {
                            Capsule().strokeBorder(
                                SubscriptionBadgeStyle.accentColor(for: account.planType).opacity(0.45),
                                lineWidth: 1
                            )
                        }
                    if account.provider == .codex, let serviceStatus {
                        OpenAIServiceStatusBadge(store: serviceStatus)
                    }
                    Button(action: onSettings) {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.appIcon)
                    .foregroundStyle(.secondary)
                    .help("설정 열기")
                    .accessibilityLabel("설정 열기")
                }
                HStack(spacing: 7) {
                    Text(account.email ?? "—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if account.provider == .codex {
                        ResetCreditsBadge(account: displayedAccount, consume: consumeResetCredit).fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .center, spacing: 4) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("마지막 조회 \(AccountDashboardFormatting.dateText(displayedAccount.lastUpdated, dateStyle: .none, timeStyle: .medium))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(manualRequestGate.message(for: account) ?? Self.statusText(for: account))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(manualRequestGate.message(for: account) == nil ? statusColor : .orange)
                    }
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityElement(children: .combine)

                Button(action: onRefresh) {
                    if account.isRefreshing || accountTokenUsageStore.isLoading(for: account) {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("새로고침", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.appAction)
                .disabled(account.status == .notConfigured || account.isRefreshing || account.isResetVerificationPending || accountTokenUsageStore.isLoading(for: account))
                .keyboardShortcut("r", modifiers: [.command])
                .help(account.provider == .claude ? "Claude CLI에서 마지막으로 수신한 사용량 다시 읽기" : "이 계정의 할당량과 토큰 사용량 새로고침")
                .accessibilityLabel("계정 새로고침")
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.appIcon)
            .help("닫기")
            .accessibilityLabel("계정 상세 닫기")
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var accountActivity: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("활성 세션")
                    .font(.headline.weight(.semibold))
            }

            Text(account.provider == .claude
                 ? "선택한 Claude 폴더의 실행 중 CLI 세션을 표시합니다. 대화 내용은 읽지 않습니다."
                 : "해당 계정의 최근 15분 CLI 활동을 표시합니다. Codex Desktop 앱 활동은 표시되지 않을 수 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if account.status == .notConfigured {
                Text("계정의 CLI 폴더를 등록하면 활성 세션을 확인할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                CLIActivitySection(
                    account: account,
                    loadSessionActivity: loadSessionActivity
                )
            }
        }
    }

    private var statusColor: Color {
        switch account.status {
        case .notConfigured:
            return .secondary
        case .normal:
            return QuotaColors.swiftUIColor(
                for: account.overallRemainingPercent ?? account.fiveHourRemainingPercent ?? 0
            )
        case .loading:
            return account.isWaitingForRefresh ? .secondary : .accentColor
        case .loginRequired, .codexNotFound, .timeout, .error:
            return QuotaColors.critical.swiftUIColor
        }
    }

    /// 현재 계정에 속한 Ping 결과만 노출
    private var currentProbePresentation: UsageWindowProbePresentationResult? {
        guard account.status != .notConfigured,
              let probePresentation = probeStore.presentation(for: account),
              probePresentation.isCurrentAccount,
              probePresentation.result.accountID == account.id
        else { return nil }
        return probePresentation
    }

    /// 현재 계정과 Ping 갱신 스냅샷 중 더 최신 한도 우선 표시
    private var displayedAccount: AccountState {
        AccountDashboardPresentation.accountForDisplay(
            current: account,
            probe: currentProbePresentation
        )
    }

    /// 계정별 공용 저장소의 실행 상태 조회
    private var isProbeRunning: Bool { probeStore.isRunning(for: account) }

    /// 화면 수명과 독립적으로 선택 계정의 초기화 갱신 시작
    private func runProbe() {
        guard manualRequestGate.allow(account) else { return }
        probeStore.start(for: account, runner: runUsageWindowProbe)
    }

    /// 계정 조회 상태의 상세 화면 표시명 변환
    public static func statusText(for account: AccountState) -> String {
        if account.provider == .claude {
            if account.status == .codexNotFound { return "Claude not found" }
            if account.status == .normal && account.lastUpdated == nil { return "사용량 대기" }
            if account.status == .normal, let updated = account.lastUpdated, Date().timeIntervalSince(updated) > 900 { return "마지막 수신값" }
        }
        return account.status == .loading && account.isWaitingForRefresh ? "조회 대기" : statusText(for: account.status)
    }

    /// 실제 요청·정상·실패 상태의 표시명 변환
    public static func statusText(for status: AccountStatus) -> String {
        switch status {
        case .notConfigured:
            return "Not configured"
        case .normal:
            return "Normal"
        case .loading:
            return "Loading"
        case .loginRequired:
            return "Login required"
        case .codexNotFound:
            return "Codex not found"
        case .timeout:
            return "Timed out"
        case .error:
            return "Error"
        }
    }

    public static let defaultProbeRunner: UsageWindowProbeRunner = { account in
        AccountDashboardDefaults.unavailableProbe(accountID: account.id)
    }
}
