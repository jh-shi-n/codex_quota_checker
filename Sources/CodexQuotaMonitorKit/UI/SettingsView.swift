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
    public static let refreshSectionTitle = "새로고침"
    public static let activitySectionTitle = "활동 알림"
    public static let quotaResetNotificationSectionTitle = "할당량 초기화 알림"
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
        private let originalPaths: [String]
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
    @Binding public var resetReminderMinutes: Int
    @Binding public var accountPaths: [String]
    @Binding public var accountDisplayNames: [String: String]
    @Binding public var launchAtLogin: Bool
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

    /// 목적: 배열형 경로와 설정 바인딩을 사용하는 화면 초기화
    /// 호환성: 새 계정 표시 바인딩은 기본값 제공
    @MainActor
    public init(
        refreshIntervalMinutes: Binding<Int>,
        accountPaths: Binding<[String]>,
        launchAtLogin: Binding<Bool>,
        showAccountLabels: Binding<Bool> = .constant(false),
        activityNotificationDurationSeconds: Binding<Int> = .constant(
            PreferencesStore.defaultActivityNotificationDurationSeconds
        ),
        accountPathValidator: AccountPathValidator = .live,
        enabledAccountIDs: Binding<[String]> = .constant(PreferencesStore.defaultEnabledAccountIDs),
        accountDisplayOrder: Binding<[String]> = .constant(PreferencesStore.defaultAccountDisplayOrder),
        accountDisplayNames: Binding<[String: String]> = .constant([:]),
        resetReminderMinutes: Binding<Int> = .constant(5),
        notificationDelivery: QuotaResetNotificationDelivery = .unavailable,
        onRetryNotificationAuthorization: @escaping () -> Void = {},
        onSendNotificationTest: @escaping () -> Void = {},
        onOpenNotificationSettings: @escaping () -> Void = {},
        tokenUsageOptions: Binding<TokenUsageOptions> = .constant(TokenUsageOptions())
    ) {
        self._tokenUsageOptions = tokenUsageOptions
        self._refreshIntervalMinutes = refreshIntervalMinutes
        self._resetReminderMinutes = resetReminderMinutes
        self._accountPaths = accountPaths
        self._launchAtLogin = launchAtLogin
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
        showAccountLabels: Binding<Bool> = .constant(false),
        activityNotificationDurationSeconds: Binding<Int> = .constant(
            PreferencesStore.defaultActivityNotificationDurationSeconds
        ),
        accountPathValidator: AccountPathValidator = .live,
        enabledAccountIDs: Binding<[String]> = .constant(PreferencesStore.defaultEnabledAccountIDs),
        accountDisplayOrder: Binding<[String]> = .constant(PreferencesStore.defaultAccountDisplayOrder),
        accountDisplayNames: Binding<[String: String]> = .constant([:]),
        resetReminderMinutes: Binding<Int> = .constant(5),
        notificationDelivery: QuotaResetNotificationDelivery = .unavailable,
        onRetryNotificationAuthorization: @escaping () -> Void = {},
        onSendNotificationTest: @escaping () -> Void = {},
        onOpenNotificationSettings: @escaping () -> Void = {},
        tokenUsageOptions: Binding<TokenUsageOptions> = .constant(TokenUsageOptions())
    ) {
        self._tokenUsageOptions = tokenUsageOptions
        self._refreshIntervalMinutes = refreshIntervalMinutes
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
        ScrollView {
            Form {
                Section(Self.refreshSectionTitle) {
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
                    Text("모든 계정에 적용됩니다. 1~60분을 입력한 뒤 Enter를 누르면 적용됩니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(Self.accountPathSectionTitle) {
                    ForEach(0..<Self.accountPathCount, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("C\(index + 1)")
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 28, alignment: .leading)
                                TextField("계정 이름 (최대 14자)", text: nameBinding(for: "C\(index + 1)"))
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("C\(index + 1) 사용자 이름")
                                    .onSubmit(commitAccountNames)
                            }
                            HStack {
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
                        Button("이름 적용", action: commitAccountNames)
                            .disabled(accountNamesDraft == accountDisplayNames)
                        Button("경로 적용", action: commitAccountPathsDraft)
                            .disabled(accountPathsDraft.paths == Self.paddedAccountPaths(accountPaths))
                        Button("편집 취소", action: cancelAccountEdits)
                            .disabled(accountPathsDraft.paths == Self.paddedAccountPaths(accountPaths) && accountNamesDraft == accountDisplayNames)
                    }
                    Text("이름은 문자·숫자·공백으로 최대 14자까지 입력할 수 있습니다. 이름 적용 또는 Enter로 저장합니다. 비워두면 슬롯명을 사용합니다. 경로는 적용 또는 Enter로 저장합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(Self.accountVisibilitySectionTitle) {
                    ForEach(PreferencesStore.stableAccountIDs, id: \.self) { accountID in
                        Toggle(isOn: enabledAccountBinding(for: accountID)) {
                            HStack(spacing: 8) {
                                Text(accountID)
                                if let name = accountDisplayNames[accountID], !name.isEmpty {
                                    Text(name).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Text("선택한 계정은 왼쪽부터 최대 두 개씩 채워집니다. 모두 숨기거나 등록된 계정이 없으면 메뉴 막대 아이콘의 안내에서 설정을 열 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(Self.accountDisplayOrderSectionTitle) {
                    AccountOrderEditor(
                        order: Binding(get: { normalizedAccountDisplayOrder }, set: { ids in updateAccountDisplayOrder(ids) }),
                        names: accountDisplayNames
                    )
                    Text("오른쪽 손잡이나 행을 드래그해 원하는 위치에 놓으세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TokenUsageSettingsSection(options: $tokenUsageOptions)

                Section(Self.activitySectionTitle) {
                    Picker(Self.activityNotificationDurationLabel, selection: activityNotificationDurationBinding) {
                        ForEach(Self.minimumActivityNotificationDurationSeconds...Self.maximumActivityNotificationDurationSeconds, id: \.self) { seconds in
                            Text("\(seconds)초").tag(seconds)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("1~10초 중 선택할 수 있습니다. 기본값은 3초이며 다음 활동 알림부터 적용됩니다.")
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
                    Text("안정 관측된 초기화 시각에 다시 조회하고 도달 알림을 보냅니다. 사전 알림을 꺼도 도달 알림은 유지됩니다.")
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
                    Text("권한 요청은 버튼을 눌렀을 때만 진행됩니다. 권한을 거부한 경우 시스템 설정에서 변경할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle(Self.launchAtLoginLabel, isOn: $launchAtLogin)
                    Toggle("계정 이름 표시", isOn: $showAccountLabels)
                    Text("로그인 시 앱을 자동으로 실행합니다. macOS 시스템 설정 > 로그인 항목에서 승인이 필요할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("앱 실행")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("OpenAI와 무관한 비공식 독립 프로젝트입니다.")
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
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
            .padding()
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
        .onChange(of: accountDisplayNames) { _, names in accountNamesDraft = names }
        .onChange(of: accountPaths) { _, _ in synchronizeAccountPathDrafts() }
        .onChange(of: enabledAccountIDs) { _, _ in synchronizeAccountDisplayDrafts() }
        .onChange(of: accountDisplayOrder) { _, _ in synchronizeAccountDisplayDrafts() }
    }

    /// 설치 앱의 번들 버전 표시 및 소스 미리보기의 현재 릴리스 기본값
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.7"
    }

    private var refreshIntervalBinding: Binding<Int> {
        Binding(
            get: { refreshIntervalMinutes },
            set: { value in
                let normalized = RefreshService.normalizedIntervalMinutes(value)
                refreshIntervalMinutes = normalized
                refreshIntervalDraft = RefreshIntervalDraft(value: normalized)
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
        case .checking: "상태 확인 중"
        case .notRequested: "아직 권한을 요청하지 않음"
        case .denied: "꺼짐 · 시스템 설정에서 허용 필요"
        case .authorized: "허용됨"
        case .provisional: "임시 허용"
        case .ephemeral: "임시 허용"
        case .unavailable: "앱 번들에서 실행되지 않아 사용할 수 없음"
        case .unknown: "알 수 없는 상태"
        case .error: "상태 확인 실패"
        }
    }

    /// 목적: 마지막 시스템 알림 전달 결과의 사용자 표시 문구 제공
    private var notificationOutcomeText: String {
        switch notificationDelivery.status.outcome {
        case .idle: "전달 기록 없음"
        case .delivered: "시스템 알림 전달 완료"
        case .fallback: "노치 활동 토스트에 대체 표시"
        case .testDelivered: "테스트 알림 전달 완료"
        case .testFailed: "테스트 알림 전달 실패"
        case .failed: "시스템 알림 전달 불가"
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

    /// 한글 조합과 공백 입력을 보존하는 계정 이름 편집 초안
    private func nameBinding(for accountID: String) -> Binding<String> {
        Binding(
            get: { accountNamesDraft[accountID] ?? "" },
            set: { accountNamesDraft[accountID] = $0 }
        )
    }

    /// 입력 완료 시 이름 제한 적용 및 내부 슬롯과 분리한 일괄 저장
    private func commitAccountNames() {
        accountDisplayNames = accountNamesDraft.reduce(into: [:]) { names, entry in
            let name = AccountDisplayName.normalized(entry.value)
            if !name.isEmpty { names[entry.key] = name }
        }
        accountNamesDraft = accountDisplayNames
    }

    /// 목적: 표시 계정 ID별 활성 상태 바인딩 제공
    private func enabledAccountBinding(for accountID: String) -> Binding<Bool> {
        Binding(
            get: { enabledAccountDraft.contains(accountID) },
            set: { isEnabled in
                var ids = Self.normalizedEnabledAccountIDs(enabledAccountDraft)
                if isEnabled {
                    if !ids.contains(accountID) { ids.append(accountID) }
                } else {
                    ids.removeAll { $0 == accountID }
                }
                let normalized = Self.normalizedEnabledAccountIDs(ids)
                enabledAccountDraft = Self.applyDisplayChange(normalized, binding: $enabledAccountIDs)
            }
        )
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

    /// 저장 전 이름·경로 편집 내용을 함께 취소
    private func cancelAccountEdits() {
        synchronizeAccountPathDrafts()
        accountNamesDraft = accountDisplayNames
    }

    /// 외부 경로 변경 또는 편집 취소 시 저장된 경로로 초안 복원
    private func synchronizeAccountPathDrafts() {
        accountPathsDraft = AccountPathsDraft(paths: accountPaths)
    }

    /// 목적: 네 경로 편집을 위한 입력 배열 길이 보정
    private static func paddedAccountPaths(_ paths: [String]) -> [String] {
        let prefix = Array(paths.prefix(accountPathCount))
        return prefix + Array(repeating: "", count: max(0, accountPathCount - prefix.count))
    }
}
