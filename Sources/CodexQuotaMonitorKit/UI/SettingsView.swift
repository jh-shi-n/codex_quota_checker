// 목적: 설정 창 라우팅과 계정 표시·앱 설정 편집 UI 제공
import SwiftUI

public enum SettingsWindowPresentationRoute: Equatable, Sendable {
    case focusSettingsScene
    case createFallback
    case focusExistingFallback
}

/// Pure routing policy used by the app delegate. A handled Settings action
/// keeps the SwiftUI scene as the host; an unhandled action gets one reusable
/// fallback host, which always wins once it exists.
public enum SettingsWindowPresentationPolicy {
    public static func route(
        actionHandled: Bool,
        hasFallbackWindow: Bool
    ) -> SettingsWindowPresentationRoute {
        if hasFallbackWindow {
            return .focusExistingFallback
        }
        return actionHandled ? .focusSettingsScene : .createFallback
    }
}

/// 목적: 호출자 바인딩을 통해 계정 표시와 앱 설정을 편집하는 화면
public struct SettingsView: View {
    public static let footerText = "OpenAI 및 Anthropic과 제휴 관계가 없는 비공식 독립 프로젝트입니다."
    public static let refreshSectionTitle = "새로고침"
    public static let activitySectionTitle = "활동 알림"
    public static let quotaResetNotificationSectionTitle = "할당량 초기화 알림"
    public static let notificationPermissionHelp = "사전 알림을 켜거나 권한 요청을 누르면 권한을 요청합니다. 거부한 권한은 시스템 설정에서 변경하세요."
    public static let accountVisibilitySectionTitle = "표시할 계정"
    public static let accountDisplayOrderSectionTitle = "계정 표시 순서"
    public static let activityNotificationDurationLabel = "활동 알림 표시 시간"
    public static let launchAtLoginLabel = "로그인 시 자동 실행"
    /// 설정 창의 기본 콘텐츠 크기와 최소 콘텐츠 크기
    public static let defaultWindowSize = CGSize(width: 560, height: 720)
    public static let minimumWindowSize = CGSize(width: 480, height: 520)
    public static let refreshIntervalOptions: [Int] = [1, 5, 10, 30]
    public static let minimumRefreshIntervalMinutes = RefreshService.minimumIntervalMinutes
    public static let maximumRefreshIntervalMinutes = RefreshService.maximumIntervalMinutes
    nonisolated public static let accountPathCount = 4
    public static let accountPathSectionTitle = "계정 경로"
    public static let minimumActivityNotificationDurationSeconds = PreferencesStore.minimumActivityNotificationDurationSeconds
    public static let maximumActivityNotificationDurationSeconds = PreferencesStore.maximumActivityNotificationDurationSeconds

    /// Draft text used by the direct minute editor. Empty/non-numeric text is
    /// not committed, while numeric values use the shared service policy.
    public struct RefreshIntervalDraft: Equatable, Sendable {
        public private(set) var text: String

        public init(value: Int) {
            self.text = String(RefreshService.normalizedIntervalMinutes(value))
        }

        public mutating func replace(text: String) {
            self.text = text
        }

        @discardableResult
        public mutating func commit() -> Int? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let value = Int(trimmed) else { return nil }
            let normalized = RefreshService.normalizedIntervalMinutes(value)
            text = String(normalized)
            return normalized
        }
    }

    /// 적용 전까지 계정 설정과 캐시를 변경하지 않는 경로 초안
    public struct AccountPathsDraft {
        public private(set) var paths: [String]
        private var originalPaths: [String]
        public private(set) var validationErrors: [Int: AccountPathValidation] = [:]

        /// 현재 설정의 네 계정 경로 복사
        public init(paths: [String]) {
            let prefix = Array(paths.prefix(SettingsView.accountPathCount))
            self.paths = prefix + Array(repeating: "", count: max(0, SettingsView.accountPathCount - prefix.count))
            self.originalPaths = self.paths
        }

        /// 저장된 설정에 영향을 주지 않는 입력 교체
        public mutating func replace(at index: Int, text: String) {
            guard paths.indices.contains(index) else { return }
            paths[index] = text
            validationErrors[index] = nil
        }

        /// 외부 경로 변경 시 미편집 슬롯만 갱신하고 현재 저장 기준 갱신
        public mutating func synchronize(paths savedPaths: [String]) {
            let current = SettingsView.paddedAccountPaths(savedPaths)
            for index in paths.indices where paths[index] == originalPaths[index] {
                paths[index] = current[index]
                validationErrors[index] = nil
            }
            originalPaths = current
        }

        /// 모든 경로의 검증 성공 시에만 정규화한 일괄 적용값 반환
        public mutating func commit(validator: AccountPathValidator) -> [String]? {
            validationErrors = [:]
            let normalized = paths.map(validator.normalizedPath)
            for (index, path) in normalized.enumerated() {
                guard path != validator.normalizedPath(originalPaths[index]) else { continue }
                let validation = validator.validate(path)
                if !validation.isAcceptable { validationErrors[index] = validation }
            }
            guard validationErrors.isEmpty else { return nil }
            paths = normalized
            return normalized
        }
    }

    @Binding public var tokenUsageOptions: TokenUsageOptions
    @Binding public var refreshIntervalMinutes: Int
    @Binding public var automaticRefreshEnabled: Bool
    @Binding public var resetReminderMinutes: Int
    @Binding public var accountPaths: [String]
    @Binding public var accountDisplayNames: [String: String]
    @Binding public var launchAtLogin: Bool
    private let launchAtLoginService: LaunchAtLoginService?
    @Binding public var notchDisplayStyle: NotchDisplayStyle
    @Binding public var showAccountLabels: Bool
    @Binding public var activityNotificationDurationSeconds: Int
    /// 화면에 표시할 활성 계정 ID 목록
    @Binding public var enabledAccountIDs: [String]
    /// 모든 계정의 표시 순서 목록
    @Binding public var accountDisplayOrder: [String]
    @ObservedObject public var notificationDelivery: QuotaResetNotificationDelivery
    @State private var accountNamesDraft: [String: String]
    @State private var refreshIntervalDraft: RefreshIntervalDraft
    @State private var accountPathsDraft: AccountPathsDraft
    /// 활성 계정 바인딩의 반응형 화면 초안
    @State private var enabledAccountDraft: [String]
    /// 표시 순서 바인딩의 반응형 화면 초안
    @State private var accountDisplayOrderDraft: [String]
    private let accountPathValidator: AccountPathValidator
    private let onRetryNotificationAuthorization: () -> Void
    private let onSendNotificationTest: () -> Void
    private let onOpenNotificationSettings: () -> Void
    private let onConnectAccount: () -> Void
    private let appUpdateStore: AppUpdateStore?

    /// 목적: 배열형 경로와 설정 바인딩을 사용하는 화면 초기화
    /// 호환성: 새 계정 표시 바인딩은 기본값 제공
    @MainActor
    public init(
        refreshIntervalMinutes: Binding<Int>,
        accountPaths: Binding<[String]>,
        launchAtLogin: Binding<Bool>,
        launchAtLoginService: LaunchAtLoginService? = nil,
        notchDisplayStyle: Binding<NotchDisplayStyle> = .constant(.ring),
        showAccountLabels: Binding<Bool> = .constant(false),
        activityNotificationDurationSeconds: Binding<Int> = .constant(
            PreferencesStore.defaultActivityNotificationDurationSeconds
        ),
        accountPathValidator: AccountPathValidator = .live,
        enabledAccountIDs: Binding<[String]> = .constant(PreferencesStore.defaultEnabledAccountIDs),
        accountDisplayOrder: Binding<[String]> = .constant(PreferencesStore.defaultAccountDisplayOrder),
        accountDisplayNames: Binding<[String: String]> = .constant([:]),
        automaticRefreshEnabled: Binding<Bool> = .constant(true),
        resetReminderMinutes: Binding<Int> = .constant(5),
        notificationDelivery: QuotaResetNotificationDelivery = .unavailable,
        onRetryNotificationAuthorization: @escaping () -> Void = {},
        onSendNotificationTest: @escaping () -> Void = {},
        onOpenNotificationSettings: @escaping () -> Void = {},
        tokenUsageOptions: Binding<TokenUsageOptions> = .constant(TokenUsageOptions()),
        onConnectAccount: @escaping () -> Void = {},
        appUpdateStore: AppUpdateStore? = nil
    ) {
        self.appUpdateStore = appUpdateStore
        self._tokenUsageOptions = tokenUsageOptions
        self._refreshIntervalMinutes = refreshIntervalMinutes
        self._automaticRefreshEnabled = automaticRefreshEnabled
        self._resetReminderMinutes = resetReminderMinutes
        self._accountPaths = accountPaths
        self._launchAtLogin = launchAtLogin
        self.launchAtLoginService = launchAtLoginService
        self._notchDisplayStyle = notchDisplayStyle
        self._showAccountLabels = showAccountLabels
        self._activityNotificationDurationSeconds = activityNotificationDurationSeconds
        self._enabledAccountIDs = enabledAccountIDs
        self._accountDisplayOrder = accountDisplayOrder
        self._accountDisplayNames = accountDisplayNames
        self._accountNamesDraft = State(initialValue: accountDisplayNames.wrappedValue)
        self._notificationDelivery = ObservedObject(wrappedValue: notificationDelivery)
        self.onRetryNotificationAuthorization = onRetryNotificationAuthorization
        self.onSendNotificationTest = onSendNotificationTest
        self.onOpenNotificationSettings = onOpenNotificationSettings
        self.onConnectAccount = onConnectAccount
        self._refreshIntervalDraft = State(initialValue: RefreshIntervalDraft(value: refreshIntervalMinutes.wrappedValue))
        self._accountPathsDraft = State(initialValue: AccountPathsDraft(paths: accountPaths.wrappedValue))
        self._enabledAccountDraft = State(
            initialValue: Self.normalizedEnabledAccountIDs(enabledAccountIDs.wrappedValue)
        )
        self._accountDisplayOrderDraft = State(
            initialValue: Self.normalizedDisplayOrder(accountDisplayOrder.wrappedValue)
        )
        self.accountPathValidator = accountPathValidator
    }

    /// 목적: 개별 경로 바인딩을 유지하는 호스트용 화면 초기화
    /// 호환성: 새 계정 표시 바인딩은 기본값 제공
    @MainActor
    public init(
        refreshIntervalMinutes: Binding<Int>,
        account1Path: Binding<String>,
        account2Path: Binding<String>,
        account3Path: Binding<String>,
        account4Path: Binding<String>,
        launchAtLogin: Binding<Bool>,
        launchAtLoginService: LaunchAtLoginService? = nil,
        notchDisplayStyle: Binding<NotchDisplayStyle> = .constant(.ring),
        showAccountLabels: Binding<Bool> = .constant(false),
        activityNotificationDurationSeconds: Binding<Int> = .constant(
            PreferencesStore.defaultActivityNotificationDurationSeconds
        ),
        accountPathValidator: AccountPathValidator = .live,
        enabledAccountIDs: Binding<[String]> = .constant(PreferencesStore.defaultEnabledAccountIDs),
        accountDisplayOrder: Binding<[String]> = .constant(PreferencesStore.defaultAccountDisplayOrder),
        accountDisplayNames: Binding<[String: String]> = .constant([:]),
        automaticRefreshEnabled: Binding<Bool> = .constant(true),
        resetReminderMinutes: Binding<Int> = .constant(5),
        notificationDelivery: QuotaResetNotificationDelivery = .unavailable,
        onRetryNotificationAuthorization: @escaping () -> Void = {},
        onSendNotificationTest: @escaping () -> Void = {},
        onOpenNotificationSettings: @escaping () -> Void = {},
        tokenUsageOptions: Binding<TokenUsageOptions> = .constant(TokenUsageOptions()),
        onConnectAccount: @escaping () -> Void = {},
        appUpdateStore: AppUpdateStore? = nil
    ) {
        self.appUpdateStore = appUpdateStore
        self._tokenUsageOptions = tokenUsageOptions
        self._refreshIntervalMinutes = refreshIntervalMinutes
        self._automaticRefreshEnabled = automaticRefreshEnabled
        self._resetReminderMinutes = resetReminderMinutes
        self._accountPaths = Binding(
            get: {
                [account1Path.wrappedValue, account2Path.wrappedValue, account3Path.wrappedValue, account4Path.wrappedValue]
            },
            set: { values in
                let normalized = values + Array(repeating: "", count: max(0, Self.accountPathCount - values.count))
                account1Path.wrappedValue = normalized[0]
                account2Path.wrappedValue = normalized[1]
                account3Path.wrappedValue = normalized[2]
                account4Path.wrappedValue = normalized[3]
            }
        )
        self._launchAtLogin = launchAtLogin
        self.launchAtLoginService = launchAtLoginService
        self._notchDisplayStyle = notchDisplayStyle
        self._showAccountLabels = showAccountLabels
        self._activityNotificationDurationSeconds = activityNotificationDurationSeconds
        self._enabledAccountIDs = enabledAccountIDs
        self._accountDisplayOrder = accountDisplayOrder
        self._accountDisplayNames = accountDisplayNames
        self._accountNamesDraft = State(initialValue: accountDisplayNames.wrappedValue)
        self._notificationDelivery = ObservedObject(wrappedValue: notificationDelivery)
        self.onRetryNotificationAuthorization = onRetryNotificationAuthorization
        self.onSendNotificationTest = onSendNotificationTest
        self.onOpenNotificationSettings = onOpenNotificationSettings
        self.onConnectAccount = onConnectAccount
        self._refreshIntervalDraft = State(initialValue: RefreshIntervalDraft(value: refreshIntervalMinutes.wrappedValue))
        self._accountPathsDraft = State(initialValue: AccountPathsDraft(paths: [
            account1Path.wrappedValue,
            account2Path.wrappedValue,
            account3Path.wrappedValue,
            account4Path.wrappedValue,
        ]))
        self._enabledAccountDraft = State(
            initialValue: Self.normalizedEnabledAccountIDs(enabledAccountIDs.wrappedValue)
        )
        self._accountDisplayOrderDraft = State(
            initialValue: Self.normalizedDisplayOrder(accountDisplayOrder.wrappedValue)
        )
        self.accountPathValidator = accountPathValidator
    }

    /// 목적: 계정 표시·경로·갱신·시작 설정 화면 구성
    public var body: some View {
        TabView {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                settingsForm {
                    switch tab {
                    case .general: generalSections
                    case .accounts: accountSections
                    case .display: displaySections
                    case .notifications: notificationSections
                    }
                }
                .tabItem { tab.label }
            }
        }
        .frame(
            minWidth: Self.minimumWindowSize.width,
            idealWidth: Self.defaultWindowSize.width,
            minHeight: Self.minimumWindowSize.height,
            idealHeight: Self.defaultWindowSize.height
        )
        .buttonStyle(.appAction)
        .onAppear {
            synchronizeAccountPathDrafts()
            synchronizeAccountDisplayDrafts()
        }
        .onChange(of: refreshIntervalMinutes) { previous, current in
            if refreshIntervalDraft.text == String(previous) {
                refreshIntervalDraft = RefreshIntervalDraft(value: current)
            }
        }
        .onChange(of: accountDisplayNames) { previous, names in
            accountNamesDraft = Self.mergingNameDrafts(accountNamesDraft, previous: previous, current: names)
        }
        .onChange(of: accountPaths) { _, paths in accountPathsDraft.synchronize(paths: paths) }
        .onChange(of: enabledAccountIDs) { _, _ in synchronizeAccountDisplayDrafts() }
        .onChange(of: accountDisplayOrder) { _, _ in synchronizeAccountDisplayDrafts() }
    }

    /// 긴 탭도 창 크기 안에서 스크롤할 수 있는 공통 폼 구성
    private func settingsForm<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Form(content: content)
            .formStyle(.grouped)
            .padding(8)
    }

    /// 업데이트·로그인 실행·앱 정보 구성
    @ViewBuilder private var generalSections: some View {
        if let appUpdateStore { AppUpdateSettingsSection(store: appUpdateStore) }

        Section {
            if let launchAtLoginService {
                LaunchAtLoginSettingsView(service: launchAtLoginService) { enabled in
                    launchAtLogin = enabled
                }
            } else {
                Toggle(Self.launchAtLoginLabel, isOn: $launchAtLogin)
            }
            Text("로그인 시 앱을 자동으로 실행합니다. macOS 시스템 설정 > 로그인 항목에서 승인이 필요할 수 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("앱 실행")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.footerText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("버전 \(appVersion)")
                    .foregroundStyle(.secondary)
                Link(destination: URL(string: "https://github.com/jh-shi-n/codex_quota_checker")!) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left.slash.chevron.right")
                        Text("GitHub")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .medium))
                    }
                }
                .help("https://github.com/jh-shi-n/codex_quota_checker")
                .accessibilityLabel("GitHub 프로젝트 저장소 열기")
            }
            .font(.caption)
        }
    }

    /// 경로 초안과 계정 표시·이름·순서 구성
    @ViewBuilder private var accountSections: some View {
        Section(Self.accountPathSectionTitle) {
            Button("계정 연결 가이드", action: onConnectAccount)
            ForEach(0..<Self.accountPathCount, id: \.self) { index in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(SettingsAccountLabel.slot("C\(index + 1)"))
                            .font(.caption.weight(.semibold)).frame(width: 36)
                        Text(SettingsAccountLabel.providerBadge(path: Self.paddedAccountPaths(accountPaths)[index]))
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                        TextField("계정 폴더 경로", text: pathBinding(at: index))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(commitAccountPathsDraft)
                        Button("폴더 선택") { chooseAccountDirectory(at: index) }
                    }
                    if let validation = accountPathsDraft.validationErrors[index],
                       let message = validation.userMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("account-path-error-\(index + 1)")
                    }
                }
            }
            HStack {
                Button("경로 적용", action: commitAccountPathsDraft)
                    .disabled(accountPathsDraft.paths == Self.paddedAccountPaths(accountPaths))
                Button("경로 편집 취소", action: synchronizeAccountPathDrafts)
                    .disabled(accountPathsDraft.paths == Self.paddedAccountPaths(accountPaths))
            }
            Text("경로 변경은 경로 적용을 누르거나 Enter를 눌러야 저장됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            AccountPathHelpView(instructions: "CLI에 아래 요청을 붙여 넣으세요. 응답받은 경로를 입력한 뒤 경로 적용을 누르세요.")
        }

        Section("계정 표시·이름·순서") {
            AccountOrderEditor(
                order: Binding(get: { normalizedAccountDisplayOrder }, set: { updateAccountDisplayOrder($0) }),
                names: accountDisplayNames,
                enabledAccountIDs: Binding(get: { enabledAccountDraft }, set: { ids in
                    enabledAccountDraft = Self.applyDisplayChange(ids, binding: $enabledAccountIDs)
                }),
                nameDrafts: $accountNamesDraft,
                onCommitNames: commitAccountNames
            )
            HStack {
                Button("이름 적용", action: commitAccountNames)
                    .accessibilityIdentifier("apply-account-names")
                    .disabled(accountNamesDraft == accountDisplayNames)
                Button("이름 편집 취소") { accountNamesDraft = accountDisplayNames }
                    .disabled(accountNamesDraft == accountDisplayNames)
            }
            Text("체크한 계정은 왼쪽부터 두 개씩 표시됩니다. 손잡이를 드래그하면 순서가 바로 바뀝니다. 모두 숨겨도 메뉴 막대에서 설정을 열 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
            Text("이름 변경은 이름 적용을 누르거나 Enter를 눌러야 저장됩니다. 문자·숫자·공백으로 최대 14자까지 입력하세요. 비우면 기본 계정 이름을 사용합니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 노치·계정 이름·토큰 그래프 표시 구성
    @ViewBuilder private var displaySections: some View {
        NotchDisplayStyleSettingsSection(selection: $notchDisplayStyle)
        Section("계정 이름") {
            Toggle("계정 이름 표시", isOn: $showAccountLabels)
            Text("노치에 계정 이름을 표시합니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
        TokenUsageSettingsSection(options: $tokenUsageOptions)
    }

    /// 조회 주기·활동 알림·할당량 알림 구성
    @ViewBuilder private var notificationSections: some View {
        Section(Self.refreshSectionTitle) {
            Toggle("주기 조회", isOn: $automaticRefreshEnabled)
            Text("주기 조회를 꺼도 앱 시작 시 조회와 수동 새로고침은 실행됩니다.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("새로고침 간격", selection: refreshIntervalBinding) {
                if !Self.refreshIntervalOptions.contains(refreshIntervalMinutes) {
                    Text("직접 입력: \(refreshIntervalMinutes)분").tag(refreshIntervalMinutes)
                }
                ForEach(Self.refreshIntervalOptions, id: \.self) { minutes in
                    Text("\(minutes)분").tag(minutes)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Text("직접 입력")
                Spacer()
                TextField("분", text: refreshIntervalDraftBinding)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitRefreshIntervalDraft)

            }
            Text("1~60분을 입력하고 Enter를 누르면 모든 계정에 적용됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section(Self.activitySectionTitle) {
            Picker(Self.activityNotificationDurationLabel, selection: activityNotificationDurationBinding) {
                ForEach(Self.minimumActivityNotificationDurationSeconds...Self.maximumActivityNotificationDurationSeconds, id: \.self) { seconds in
                    Text("\(seconds)초").tag(seconds)
                }
            }
            .pickerStyle(.menu)
            Text("선택한 시간은 다음 활동 알림부터 적용됩니다. 1~10초를 선택할 수 있으며 기본값은 3초입니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section(Self.quotaResetNotificationSectionTitle) {
            Picker("초기화 사전 알림", selection: $resetReminderMinutes) {
                Text("끔").tag(0)
                Text("10분 전").tag(10)
                Text("5분 전").tag(5)
                Text("3분 전").tag(3)
            }
            Text("초기화 시각이 확정되면 해당 시각에 다시 조회하고 도달 알림을 보냅니다. 사전 알림을 꺼도 도달 알림은 보냅니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text("권한: \(notificationAuthorizationText)")
                Text("전달: \(notificationOutcomeText)")
                    .foregroundStyle(.secondary)
                if let error = notificationDelivery.status.authorizationError {
                    Text("권한 오류: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if let error = notificationDelivery.status.deliveryError {
                    Text("전달 오류: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            HStack {
                Button("권한 요청 / 다시 확인", action: onRetryNotificationAuthorization)
                    .disabled(notificationControlsUnavailable)
                Button("테스트 알림", action: onSendNotificationTest)
                    .disabled(notificationControlsUnavailable)
                Button("알림 설정 열기", action: onOpenNotificationSettings)
                    .disabled(notificationControlsUnavailable)
            }
            Text(Self.notificationPermissionHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 설치 앱의 번들 버전 표시 및 소스 미리보기의 현재 릴리스 기본값
    private var appVersion: String {
        AppVersion.current
    }

    private var refreshIntervalBinding: Binding<Int> {
        Binding(
            get: { refreshIntervalMinutes },
            set: { value in
                let normalized = RefreshService.normalizedIntervalMinutes(value)
                refreshIntervalMinutes = normalized
                refreshIntervalDraft = RefreshIntervalDraft(value: refreshIntervalMinutes)
            }
        )
    }

    private var refreshIntervalDraftBinding: Binding<String> {
        Binding(
            get: { refreshIntervalDraft.text },
            set: { refreshIntervalDraft.replace(text: $0) }
        )
    }

    private var activityNotificationDurationBinding: Binding<Int> {
        Binding(
            get: { activityNotificationDurationSeconds },
            set: {
                activityNotificationDurationSeconds = PreferencesStore
                    .normalizedActivityNotificationDurationSeconds($0)
            }
        )
    }

    /// 목적: 권한 상태의 사용자 표시 문구 제공
    private var notificationAuthorizationText: String {
        switch notificationDelivery.status.authorization {
        case .checking: "상태를 확인하고 있습니다."
        case .notRequested: "아직 권한을 요청하지 않았습니다."
        case .denied: "꺼져 있습니다. 시스템 설정에서 허용하세요."
        case .authorized: "허용되어 있습니다."
        case .provisional: "임시로 허용되어 있습니다."
        case .ephemeral: "임시로 허용되어 있습니다."
        case .unavailable: "앱 번들에서 실행해야 사용할 수 있습니다."
        case .unknown: "상태를 알 수 없습니다."
        case .error: "상태를 확인하지 못했습니다."
        }
    }

    /// 목적: 마지막 시스템 알림 전달 결과의 사용자 표시 문구 제공
    private var notificationOutcomeText: String {
        switch notificationDelivery.status.outcome {
        case .idle: "전달 기록이 없습니다."
        case .delivered: "시스템 알림을 전달했습니다."
        case .fallback: "노치 활동 알림으로 대신 표시했습니다."
        case .testDelivered: "테스트 알림을 전달했습니다."
        case .testFailed: "테스트 알림을 전달하지 못했습니다."
        case .failed: "시스템 알림을 전달할 수 없습니다."
        }
    }

    /// 목적: 앱 번들과 권한 상태에 따른 알림 동작 버튼 활성 여부
    private var notificationControlsUnavailable: Bool {
        switch notificationDelivery.status.authorization {
        case .checking, .unavailable:
            true
        case .notRequested, .denied, .authorized, .provisional, .ephemeral, .unknown, .error:
            false
        }
    }

    /// 입력 완료 시 이름 제한 적용 및 내부 슬롯과 분리한 일괄 저장
    private func commitAccountNames() {
        accountDisplayNames = accountNamesDraft.reduce(into: [:]) { names, entry in
            let name = AccountDisplayName.normalized(entry.value)
            if !name.isEmpty { names[entry.key] = name }
        }
        accountNamesDraft = accountDisplayNames
    }

    /// 외부 이름 변경 시 미편집 슬롯만 동기화하여 입력 중 초안 보존
    static func mergingNameDrafts(_ drafts: [String: String], previous: [String: String], current: [String: String]) -> [String: String] {
        var result = drafts
        for id in PreferencesStore.stableAccountIDs where (drafts[id] ?? "") == (previous[id] ?? "") {
            result[id] = current[id]
        }
        return result
    }

    /// 목적: 표시 순서를 표준 계정 ID의 완전한 순열로 제공
    private var normalizedAccountDisplayOrder: [String] {
        Self.normalizedDisplayOrder(accountDisplayOrderDraft)
    }

    /// 목적: 활성 계정·표시 순서 초안을 외부 바인딩과 동기화
    private func synchronizeAccountDisplayDrafts() {
        let enabledIDs = Self.normalizedEnabledAccountIDs(enabledAccountIDs)
        if enabledAccountDraft != enabledIDs {
            enabledAccountDraft = enabledIDs
        }
        if enabledAccountIDs != enabledIDs {
            enabledAccountIDs = enabledIDs
        }

        let displayOrder = Self.normalizedDisplayOrder(accountDisplayOrder)
        if accountDisplayOrderDraft != displayOrder {
            accountDisplayOrderDraft = displayOrder
        }
        if accountDisplayOrder != displayOrder {
            accountDisplayOrder = displayOrder
        }
    }

    /// 목적: 계정 표시 순서를 정규화해 초안·호출자 바인딩에 반영
    private func updateAccountDisplayOrder(_ ids: [String]) {
        let normalized = Self.normalizedDisplayOrder(ids)
        accountDisplayOrderDraft = Self.applyDisplayChange(normalized, binding: $accountDisplayOrder)
    }

    /// 저장 실패 시 복원된 실제 설정값을 화면 초안에 반환
    @MainActor
    static func applyDisplayChange(_ values: [String], binding: Binding<[String]>) -> [String] {
        binding.wrappedValue = values
        return binding.wrappedValue
    }

    /// 목적: 활성 계정 ID의 대문자 표준화·중복 제거
    private static func normalizedEnabledAccountIDs(_ ids: [String]) -> [String] {
        let stableIDs = PreferencesStore.stableAccountIDs
        var normalized: [String] = []
        for rawID in ids {
            let accountID = rawID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard stableIDs.contains(accountID), !normalized.contains(accountID) else { continue }
            normalized.append(accountID)
        }
        return normalized
    }

    /// 목적: 중복·미지원 ID를 제거하고 누락 계정을 기본 순서로 추가
    private static func normalizedDisplayOrder(_ ids: [String]) -> [String] {
        let stableIDs = PreferencesStore.stableAccountIDs
        var normalized = normalizedEnabledAccountIDs(ids)
        let missingIDs = stableIDs.filter { !normalized.contains($0) }
        normalized.append(contentsOf: missingIDs)
        return normalized
    }

    /// 목적: 직접 입력한 갱신 간격의 유효값 반영
    private func commitRefreshIntervalDraft() {
        guard let value = refreshIntervalDraft.commit() else {
            refreshIntervalDraft = RefreshIntervalDraft(value: refreshIntervalMinutes)
            return
        }
        refreshIntervalMinutes = value
        refreshIntervalDraft = RefreshIntervalDraft(value: refreshIntervalMinutes)
    }

    /// 적용 전까지 초안만 갱신하는 계정 경로 바인딩
    private func pathBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { accountPathsDraft.paths[index] },
            set: { accountPathsDraft.replace(at: index, text: $0) }
        )
    }

    /// 숨김 폴더를 포함한 사용자 선택 경로를 편집 초안에만 반영
    private func chooseAccountDirectory(at index: Int) {
        guard let selected = AccountFolderPicker.choose(currentPath: accountPathsDraft.paths[index]) else { return }
        accountPathsDraft.replace(at: index, text: selected)
    }

    /// 전체 검증 성공 시에만 실제 계정 경로 일괄 저장
    private func commitAccountPathsDraft() {
        guard let paths = accountPathsDraft.commit(validator: accountPathValidator),
              paths != Self.paddedAccountPaths(accountPaths) else { return }
        accountPaths = paths
    }

    /// 외부 경로 변경 또는 편집 취소 시 저장된 경로로 초안 복원
    private func synchronizeAccountPathDrafts() {
        accountPathsDraft = AccountPathsDraft(paths: accountPaths)
    }

    /// 목적: 네 경로 편집을 위한 입력 배열 길이 보정
    nonisolated private static func paddedAccountPaths(_ paths: [String]) -> [String] {
        let prefix = Array(paths.prefix(accountPathCount))
        return prefix + Array(repeating: "", count: max(0, accountPathCount - prefix.count))
    }
}
