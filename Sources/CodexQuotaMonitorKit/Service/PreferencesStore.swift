// 목적: 네 계정 모니터의 사용자 설정 로드·정규화·영속화
import Combine
import Foundation

/// 목적: 네 계정 모니터의 사용자 설정 정규화·저장·제공
/// 제한: 인증 파일 읽기 제외
@MainActor
public final class PreferencesStore: ObservableObject {
    /// 기존 설정 이관·호환 로드 및 조회 캐시 저장용 키
    public enum Keys {
        public static let tokenUsageOptions = "CodexQuotaMonitor.tokenUsageOptions"
        public static let settingsBundle = "CodexQuotaMonitor.settings.v1"
        public static let refreshIntervalMinutes = "CodexQuotaMonitor.refreshIntervalMinutes"
        public static let resetReminderMinutes = "CodexQuotaMonitor.resetReminderMinutes"
        public static let automaticResetPingEnabled = "CodexQuotaMonitor.automaticResetPingEnabled"
        public static let accountPaths = "CodexQuotaMonitor.accountPaths"
        public static let enabledAccountIDs = "CodexQuotaMonitor.enabledAccountIDs"
        public static let accountDisplayOrder = "CodexQuotaMonitor.accountDisplayOrder"
        public static let accountDisplayNames = "CodexQuotaMonitor.accountDisplayNames"
        public static let launchAtLogin = "CodexQuotaMonitor.launchAtLogin"
        public static let showAccountLabels = "CodexQuotaMonitor.showAccountLabels"
        public static let activityNotificationDurationSeconds = "CodexQuotaMonitor.activityNotificationDurationSeconds"
        public static let lastSuccessfulQuotaSnapshots = "CodexQuotaMonitor.lastSuccessfulQuotaSnapshots"
    }

    /// 인증정보·원본 응답을 제외한 최근 정상 할당량의 SQLite 저장 자료형
    public struct QuotaSnapshot: Codable, Equatable, Sendable {
        public let usedPercent: Double?
        public let remainingPercent: Double?
        public let resetAt: Date?
        public let secondaryUsedPercent: Double?
        public let secondaryRemainingPercent: Double?
        public let secondaryResetAt: Date?
        public let resetCredits: RateLimitResetCredits?
        public let lastUpdated: Date?

        public var primaryUsedPercent: Double? { usedPercent }
        public var primaryRemainingPercent: Double? { remainingPercent }
        public var primaryResetAt: Date? { resetAt }

        public init(
            usedPercent: Double? = nil,
            remainingPercent: Double? = nil,
            resetAt: Date? = nil,
            secondaryUsedPercent: Double? = nil,
            secondaryRemainingPercent: Double? = nil,
            secondaryResetAt: Date? = nil,
            resetCredits: RateLimitResetCredits? = nil,
            lastUpdated: Date? = nil
        ) {
            self.usedPercent = usedPercent.map(AccountState.clampPercent)
            self.remainingPercent = remainingPercent.map(AccountState.clampPercent)
            self.resetAt = resetAt
            self.secondaryUsedPercent = secondaryUsedPercent.map(AccountState.clampPercent)
            self.secondaryRemainingPercent = secondaryRemainingPercent.map(AccountState.clampPercent)
            self.secondaryResetAt = secondaryResetAt
            self.resetCredits = resetCredits
            self.lastUpdated = lastUpdated
        }
    }

    public static let accountPathCount = 4
    /// 기본 표시 계정 ID: C1–C4
    nonisolated public static let stableAccountIDs = ["C1", "C2", "C3", "C4"]
    /// 초기 활성 계정 ID: 전체 계정
    nonisolated public static let defaultEnabledAccountIDs = stableAccountIDs
    /// 초기 계정 표시 순서: C1부터 C4까지
    nonisolated public static let defaultAccountDisplayOrder = stableAccountIDs
    nonisolated public static let defaultActivityNotificationDurationSeconds = 3
    nonisolated public static let minimumActivityNotificationDurationSeconds = 1
    nonisolated public static let maximumActivityNotificationDurationSeconds = 10

    @Published public private(set) var tokenUsageOptions: TokenUsageOptions
    @Published public private(set) var tokenHistoryError: String?
    @Published public private(set) var refreshIntervalMinutes: Int
    /// 초기화 사전 알림 시점; 0은 사전 알림만 해제
    @Published public private(set) var resetReminderMinutes: Int
    /// 초기화 감지 이후 최소 Ping 자동 전송 여부; 기본 미사용
    @Published public private(set) var automaticResetPingEnabled: Bool
    @Published public private(set) var accountPaths: [String]
    /// 활성 표시 계정 ID, 빈 배열 허용
    @Published public private(set) var enabledAccountIDs: [String]
    /// C1–C4 전체 계정의 표시 순서
    @Published public private(set) var accountDisplayOrder: [String]
    /// C1–C4 슬롯에만 연결한 사용자 표시 이름
    @Published public private(set) var accountDisplayNames: [String: String]
    @Published public private(set) var launchAtLogin: Bool
    @Published public private(set) var showAccountLabels: Bool
    @Published public private(set) var activityNotificationDurationSeconds: Int
    @Published public private(set) var persistenceError: String?
    /// 자동 전송 선택의 저장 성공 이후에만 예약·권한 동작 연결
    public var onAutomaticResetPingChanged: (@MainActor (Bool) -> Void)?

    private let userDefaults: UserDefaults
    private let configurationFile: AppConfigurationFile?
    private let defaultPaths: [String]
    private let homeDirectory: URL
    private let fileSystem: AccountPathFileSystem
    public private(set) var hasRegisteredAccount = false
    public private(set) var firstAccountRegisteredAt: Date?
    /// 시작 시 config.json 부재와 기존 등록 이력 부재를 함께 확인한 최초 실행
    public private(set) var isFirstLaunch = false
    /// 앱 시작 시 기록한 파일 존재 여부; 시작 중 생성 이후에도 동일 값 유지
    public private(set) var configurationFileWasPresentAtLaunch = false
    private var committedBundle: SettingsBundle?
    private var settingsLoadFailed = false

    /// 경로·표시·등록 이력의 단일 인코딩 경계
    private struct SettingsBundle: Codable, Equatable {
        var schemaVersion = 1
        var settings: AppPreferencesPayload
        var hasRegisteredAccount: Bool
        var firstAccountRegisteredAt: Date?
    }

    @Published public private(set) var cacheError: String?
    private var cacheMigrationError: String?
    private let quotaStore: SQLiteQuotaSnapshotStore?
    private var quotaSnapshotsStorage: [String: QuotaSnapshot]

    /// 목적: 설정값 로드, 기본값 병합, 비정규 저장값 정리
    public init(
        userDefaults: UserDefaults = .standard,
        defaultPaths: [String]? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileSystem: AccountPathFileSystem = .live,
        configurationFile: AppConfigurationFile? = nil,
        quotaDatabaseURL: URL? = nil
    ) {
        self.userDefaults = userDefaults
        self.configurationFile = configurationFile
        self.configurationFileWasPresentAtLaunch = configurationFile?.exists ?? true
        self.quotaStore = (quotaDatabaseURL ?? (userDefaults === UserDefaults.standard ? TokenUsageSnapshotCache.defaultDatabaseURL : nil))
            .map { SQLiteQuotaSnapshotStore(databaseURL: $0) }
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.fileSystem = fileSystem
        let requestedDefaults = defaultPaths ?? Array(repeating: "", count: Self.accountPathCount)
        self.defaultPaths = Self.normalizedDefaultPaths(requestedDefaults, homeDirectory: self.homeDirectory)

        var savedSettings: AppPreferencesPayload?
        var bundle: SettingsBundle?
        var loadError: String?
        do {
            if let raw = userDefaults.object(forKey: Keys.settingsBundle) {
                guard let data = raw as? Data else { throw CocoaError(.coderReadCorrupt) }
                let loaded = try JSONDecoder().decode(SettingsBundle.self, from: data)
                guard loaded.schemaVersion == 1, loaded.settings.accountPaths.count == Self.accountPathCount,
                      loaded.hasRegisteredAccount || loaded.firstAccountRegisteredAt == nil,
                      loaded.hasRegisteredAccount || !loaded.settings.accountPaths.contains(where: { !$0.isEmpty }),
                      loaded.firstAccountRegisteredAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true
                else { throw CocoaError(.coderReadCorrupt) }
                bundle = loaded
                savedSettings = loaded.settings
            } else if let document = try configurationFile?.read() {
                savedSettings = document.settings
                self.hasRegisteredAccount = document.installation?.hasRegisteredAccount ?? false
                self.firstAccountRegisteredAt = document.installation?.firstAccountRegisteredAt
                guard self.hasRegisteredAccount || self.firstAccountRegisteredAt == nil else {
                    throw CocoaError(.coderReadCorrupt)
                }
            }
        } catch { loadError = "설정을 읽지 못했습니다. 원본을 보존했습니다: \(error.localizedDescription)" }
        self.settingsLoadFailed = loadError != nil
        self.persistenceError = loadError
        self.committedBundle = bundle
        if let bundle {
            for key in [Keys.accountPaths, Keys.enabledAccountIDs, Keys.accountDisplayOrder, Keys.accountDisplayNames,
                        Keys.refreshIntervalMinutes, Keys.resetReminderMinutes, Keys.automaticResetPingEnabled, Keys.launchAtLogin,
                        Keys.showAccountLabels, Keys.activityNotificationDurationSeconds] {
                userDefaults.removeObject(forKey: key)
            }
            self.hasRegisteredAccount = bundle.hasRegisteredAccount
            self.firstAccountRegisteredAt = bundle.firstAccountRegisteredAt
            // 파일 선행 저장 직후 중단된 경우에도 완료 이력의 false 회귀 방지
            if let history = try? configurationFile?.read()?.installation,
               history.hasRegisteredAccount {
                self.hasRegisteredAccount = true
                if self.firstAccountRegisteredAt == nil {
                    self.firstAccountRegisteredAt = history.firstAccountRegisteredAt
                }
            }
        }
        if let savedSettings, savedSettings.accountPaths.count != Self.accountPathCount {
            loadError = "계정 경로 설정이 손상되었습니다. 원본을 보존했습니다."
            settingsLoadFailed = true
            persistenceError = loadError
        }
        let values = savedSettings?.preferenceValues
        let readSetting: (String) -> Any? = { key in
            if loadError != nil { return nil }
            if let values { return values[key] }
            return userDefaults.object(forKey: key)
        }

        self.tokenUsageOptions = readSetting(Keys.tokenUsageOptions) as? TokenUsageOptions ?? TokenUsageOptions()

        let rawInterval = readSetting(Keys.refreshIntervalMinutes)
        let persistedInterval = rawInterval as? Int
        let normalizedInterval = RefreshService.normalizedIntervalMinutes(persistedInterval ?? 5)
        self.refreshIntervalMinutes = normalizedInterval
        self.resetReminderMinutes = Self.normalizedResetReminderMinutes(
            readSetting(Keys.resetReminderMinutes) as? Int ?? 5
        )
        self.automaticResetPingEnabled = readSetting(Keys.automaticResetPingEnabled) as? Bool ?? false

        let rawPaths = readSetting(Keys.accountPaths)
        let persistedPaths = rawPaths as? [String]
        let normalizedPathResult = Self.normalizedPathResult(
            persistedPaths,
            defaults: self.defaultPaths,
            homeDirectory: self.homeDirectory
        )
        self.accountPaths = normalizedPathResult.values
        if bundle == nil && loadError == nil && normalizedPathResult.values.contains(where: { !$0.isEmpty }) {
            self.hasRegisteredAccount = true
        }

        let rawEnabledAccountIDs = readSetting(Keys.enabledAccountIDs)
        let persistedEnabledAccountIDs = rawEnabledAccountIDs as? [String]
        self.enabledAccountIDs = Self.normalizedAccountIDs(persistedEnabledAccountIDs)
        let rawAccountDisplayOrder = readSetting(Keys.accountDisplayOrder)
        let persistedAccountDisplayOrder = rawAccountDisplayOrder as? [String]
        self.accountDisplayOrder = Self.normalizedAccountDisplayOrder(persistedAccountDisplayOrder)
        self.accountDisplayNames = Self.normalizedAccountDisplayNames(
            readSetting(Keys.accountDisplayNames) as? [String: String] ?? [:]
        )

        let rawLaunchAtLogin = readSetting(Keys.launchAtLogin)
        self.launchAtLogin = rawLaunchAtLogin as? Bool ?? false
        let rawShowAccountLabels = readSetting(Keys.showAccountLabels)
        let persistedShowAccountLabels = rawShowAccountLabels as? Bool
        self.showAccountLabels = persistedShowAccountLabels ?? false
        let rawActivityDuration = readSetting(Keys.activityNotificationDurationSeconds)
        let persistedActivityDuration = rawActivityDuration as? Int
        self.activityNotificationDurationSeconds = Self.normalizedActivityNotificationDurationSeconds(
            persistedActivityDuration ?? Self.defaultActivityNotificationDurationSeconds
        )
        let rawQuotaSnapshots = userDefaults.data(forKey: Keys.lastSuccessfulQuotaSnapshots)
        self.quotaSnapshotsStorage = Self.decodedQuotaSnapshots(rawQuotaSnapshots, homeDirectory: self.homeDirectory)
        if let quotaStore, !settingsLoadFailed {
            do {
                if let rawQuotaSnapshots {
                    let decoded = try JSONDecoder().decode([String: QuotaSnapshot].self, from: rawQuotaSnapshots)
                    let canonical = Dictionary(decoded.map { (Self.normalizedAccountPath($0.key, homeDirectory: self.homeDirectory), $0.value) }, uniquingKeysWith: { _, last in last })
                    let existing = try quotaStore.load()
                    let missing = canonical.filter { existing[$0.key] == nil && !$0.key.isEmpty }
                    try quotaStore.save(missing)
                    let restored = try quotaStore.load()
                    guard missing.allSatisfy({ restored[$0.key] == $0.value || ($0.value.lastUpdated ?? Date()).addingTimeInterval(SQLiteQuotaSnapshotStore.lifetime) <= Date() }) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    if bundle != nil { userDefaults.removeObject(forKey: Keys.lastSuccessfulQuotaSnapshots) }
                }
                self.quotaSnapshotsStorage = try quotaStore.load()
            } catch {
                self.cacheMigrationError = "할당량 캐시를 복원하지 못했습니다: \(error.localizedDescription)"
                self.cacheError = self.cacheMigrationError
            }
        }

        isFirstLaunch = !configurationFileWasPresentAtLaunch && !hasRegisteredAccount && !hasRegisteredAccounts
        // 설정 인코딩 후 등록 이력 파일을 먼저 반영하고 UserDefaults 갱신
        if loadError == nil { persist() }
    }

    /// 계정 표시 활성화 여부와 독립적인 등록 경로 존재 여부
    public var hasRegisteredAccounts: Bool { accountPaths.contains { !$0.isEmpty } }

    /// 첫 실행 또는 등록 미완료 상태의 연결 가이드 분기; 기존 등록 이력 우선
    public var requiresAccountSetup: Bool {
        guard !hasRegisteredAccount, !hasRegisteredAccounts else { return false }
        if isFirstLaunch { return true }
        // 파일은 존재하지만 등록을 마치지 않은 다음 실행의 가이드 유지
        return configurationFileWasPresentAtLaunch || configurationFile == nil
    }

    /// Compatibility alias for settings views that use the shorter name.
    public var intervalMinutes: Int { refreshIntervalMinutes }

    /// Compatibility alias for hosts that refer to persisted homes as paths.
    public var paths: [String] { accountPaths }

    /// 슬롯 ID 대신 정규화 경로로 구분한 정상 할당량의 메모리 사본
    public var lastSuccessfulQuotaSnapshots: [String: QuotaSnapshot] {
        quotaSnapshotsStorage
    }

    public func quotaSnapshot(for accountPath: String) -> QuotaSnapshot? {
        let normalizedPath = normalizedAccountPath(accountPath)
        guard !normalizedPath.isEmpty else { return nil }
        cleanupQuotaSnapshots()
        return quotaSnapshotsStorage[normalizedPath]
    }

    public func quotaSnapshot(for accountPath: URL) -> QuotaSnapshot? {
        quotaSnapshot(for: accountPath.path)
    }

    /// Records only the quota fields needed for a loading/error placeholder.
    /// Invalid or empty paths are ignored rather than creating an unscoped
    /// snapshot entry.
    public func updateQuotaSnapshot(for accountPath: String, snapshot: QuotaSnapshot) {
        let normalizedPath = normalizedAccountPath(accountPath)
        guard !normalizedPath.isEmpty else { return }
        quotaSnapshotsStorage[normalizedPath] = snapshot
        do {
            try quotaStore?.save([normalizedPath: snapshot])
            cleanupQuotaSnapshots()
        } catch { cacheError = "할당량 캐시를 저장하지 못했습니다: \(error.localizedDescription)" }
    }

    public func updateQuotaSnapshot(for accountPath: URL, snapshot: QuotaSnapshot) {
        updateQuotaSnapshot(for: accountPath.path, snapshot: snapshot)
    }

    public func removeQuotaSnapshot(for accountPath: String) {
        let normalizedPath = normalizedAccountPath(accountPath)
        guard !normalizedPath.isEmpty else { return }
        quotaSnapshotsStorage.removeValue(forKey: normalizedPath)
        do {
            try quotaStore?.remove(path: normalizedPath)
            cacheError = cacheMigrationError
        } catch { cacheError = "할당량 캐시를 삭제하지 못했습니다: \(error.localizedDescription)" }
    }

    public func removeQuotaSnapshot(for accountPath: URL) {
        removeQuotaSnapshot(for: accountPath.path)
    }

    /// 설정과 독립적인 할당량 정리 오류 기록 및 재시도
    public func cleanupQuotaSnapshots(now: Date = Date()) {
        guard !settingsLoadFailed, let quotaStore else { return }
        let paths = Set(accountPaths.filter { !$0.isEmpty })
        do {
            try quotaStore.cleanup(registeredPaths: paths, now: now)
            quotaSnapshotsStorage = try quotaStore.load(now: now)
            quotaSnapshotsStorage = quotaSnapshotsStorage.filter {
                paths.contains($0.key) && ($0.value.lastUpdated ?? now).addingTimeInterval(SQLiteQuotaSnapshotStore.lifetime) > now
            }
            cacheError = cacheMigrationError
        } catch { cacheError = "할당량 캐시 정리에 실패했습니다. 다음 주기에 재시도합니다: \(error.localizedDescription)" }
    }

    /// Returns the normalized representation used as a snapshot key.
    public func normalizedAccountPath(_ path: String) -> String {
        Self.normalizedAccountPath(path, homeDirectory: homeDirectory)
    }

    public func normalizedAccountPath(_ path: URL) -> String {
        normalizedAccountPath(path.path)
    }

    /// Validates one account path using the same injected filesystem policy as
    /// persistence. Empty paths are accepted as unconfigured.
    public func validateAccountPath(_ path: String) -> AccountPathValidation {
        AccountConfig.validatePath(
            path,
            homeDirectory: homeDirectory,
            fileSystem: fileSystem
        )
    }

    public func validateAccountPath(_ path: URL) -> AccountPathValidation {
        validateAccountPath(path.path)
    }

    public static func validateAccountPath(
        _ path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileSystem: AccountPathFileSystem = .live
    ) -> AccountPathValidation {
        AccountConfig.validatePath(
            path,
            homeDirectory: homeDirectory,
            fileSystem: fileSystem
        )
    }

    public static func normalizedAccountPath(
        _ path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        canonicalPath(path, homeDirectory: homeDirectory.standardizedFileURL)
    }

    /// Stores the shared bounded interval; non-positive values become the
    /// five-minute default and values above the maximum clamp before being
    /// published and persisted.
    public func updateRefreshInterval(minutes: Int) {
        guard !settingsLoadFailed else { return }
        refreshIntervalMinutes = RefreshService.normalizedIntervalMinutes(minutes)
        persist()
    }

    /// 사전 알림 시점 저장; 도달 시각 재조회와 알림은 별도 유지
    public func updateResetReminder(minutes: Int) {
        guard !settingsLoadFailed else { return }
        resetReminderMinutes = Self.normalizedResetReminderMinutes(minutes)
        persist()
    }

    /// 자동 Ping 선택의 영속 저장 및 저장 실패 시 기존 설정 복원
    public func updateAutomaticResetPing(_ enabled: Bool) {
        guard !settingsLoadFailed else { return }
        let previous = automaticResetPingEnabled
        automaticResetPingEnabled = enabled
        guard persist() else { return }
        if previous != automaticResetPingEnabled {
            onAutomaticResetPingChanged?(automaticResetPingEnabled)
        }
    }

    /// 사전 알림 선택값의 허용 범위 정규화
    nonisolated public static func normalizedResetReminderMinutes(_ minutes: Int) -> Int {
        [0, 3, 5, 10].contains(minutes) ? minutes : 5
    }

    /// 최초 연결 확인 후 경로·표시·등록 이력을 동일 묶음으로 반영
    @discardableResult
    public func registerAccountPaths(_ paths: [String], enabledIDs: [String]? = nil, now: Date = Date()) -> Bool {
        guard !settingsLoadFailed, paths.count == Self.accountPathCount,
              now.timeIntervalSince1970.isFinite else { return false }
        let normalized = paths.map { normalizedAccountPath($0) }
        guard normalized.contains(where: { !$0.isEmpty }) else { return false }
        for (index, path) in normalized.enumerated() where path != accountPaths[index] {
            let validation = validateAccountPath(path)
            guard validation == .valid || validation == .empty else {
                persistenceError = validation.userMessage ?? "계정 경로를 확인해 주세요."
                return false
            }
        }
        let previous = currentPayload
        let previousRegistered = hasRegisteredAccount
        let previousDate = firstAccountRegisteredAt
        accountPaths = normalized
        if let enabledIDs { enabledAccountIDs = Self.normalizedAccountIDs(enabledIDs) }
        if !hasRegisteredAccount {
            hasRegisteredAccount = true
            firstAccountRegisteredAt = now
        }
        guard persist() else {
            restore(previous)
            hasRegisteredAccount = previousRegistered
            firstAccountRegisteredAt = previousDate
            return false
        }
        return true
    }

    /// 변경된 경로만 검증하고 모든 슬롯을 하나의 설정 묶음으로 반영
    @discardableResult
    public func updateAccountPaths(_ paths: [String]) -> Bool {
        guard paths.count == Self.accountPathCount, !settingsLoadFailed else { return false }
        let normalized = paths.map { normalizedAccountPath($0) }
        for (index, path) in normalized.enumerated() where path != accountPaths[index] {
            let validation = validateAccountPath(path)
            guard validation == .empty || validation == .valid else {
                persistenceError = validation.userMessage ?? "계정 경로를 확인해 주세요."
                return false
            }
        }
        if normalized.contains(where: { !$0.isEmpty }) { return registerAccountPaths(normalized) }
        accountPaths = normalized
        return persist()
    }

    /// 목적: 활성 계정 ID를 정규화해 게시·저장
    /// 조건: 빈 배열 허용, 유효한 C1–C4 ID만 유지
    public func updateEnabledAccountIDs(_ ids: [String]) {
        guard !settingsLoadFailed else { return }
        enabledAccountIDs = Self.normalizedAccountIDs(ids)
        persist()
    }

    /// 목적: 계정 표시 순서를 전체 ID 순열로 정규화해 게시·저장
    /// 조건: 누락 ID는 기본 순서대로 뒤에 추가
    public func updateAccountDisplayOrder(_ ids: [String]) {
        guard !settingsLoadFailed else { return }
        accountDisplayOrder = Self.normalizedAccountDisplayOrder(ids)
        persist()
    }

    /// 슬롯별 표시 이름의 정규화·원자적 저장과 실패 시 직전 값 복원
    public func updateAccountDisplayNames(_ names: [String: String]) {
        guard !settingsLoadFailed else { return }
        let previous = accountDisplayNames
        accountDisplayNames = Self.normalizedAccountDisplayNames(names)
        if !persist() { accountDisplayNames = previous }
    }

    /// 사용자 이름 또는 기본 슬롯 ID 반환
    public func displayName(for id: String) -> String {
        AccountDisplayName.resolved(accountDisplayNames[id], slotID: id)
    }

    /// 목적: 활성 계정만 저장된 표시 순서로 반환
    /// 반환: 입력 상태 중 활성화된 C1–C4 계정 상태
    public func visibleAccounts(_ states: [AccountState]) -> [AccountState] {
        accountDisplayOrder.compactMap { id in
            guard enabledAccountIDs.contains(id) else { return nil }
            return states.first { $0.id == id && $0.status != .notConfigured }
        }
    }

    /// 차트 옵션의 정규화·일괄 저장과 실패 시 이전 설정 복원
    public func updateTokenUsageOptions(_ value: TokenUsageOptions) {
        guard !settingsLoadFailed else { return }
        tokenUsageOptions = TokenUsageOptions(weeklyChartEnabled: value.weeklyChartEnabled,
            chartStyle: value.chartStyle, retentionMonths: value.retentionMonths)
        persist()
    }

    /// 비동기 장기 저장소 오류를 설정 화면에 전달
    public func reportTokenHistoryError(_ message: String?) {
        if tokenHistoryError != message { tokenHistoryError = message }
    }

    public func updateLaunchAtLogin(_ enabled: Bool) {
        guard !settingsLoadFailed else { return }
        launchAtLogin = enabled
        persist()
    }

    public func updateShowAccountLabels(_ enabled: Bool) {
        guard !settingsLoadFailed else { return }
        showAccountLabels = enabled
        persist()
    }

    public func updateActivityNotificationDuration(seconds: Int) {
        guard !settingsLoadFailed else { return }
        activityNotificationDurationSeconds = Self.normalizedActivityNotificationDurationSeconds(seconds)
        persist()
    }

    /// 현재 설정의 메모리 반영 완료; 디스크 저장은 UserDefaults의 비동기 처리
    @discardableResult
    public func persist() -> Bool {
        guard !settingsLoadFailed else { return false }
        let candidate = SettingsBundle(settings: currentPayload,
            hasRegisteredAccount: hasRegisteredAccount, firstAccountRegisteredAt: firstAccountRegisteredAt)
        do {
            let data = try JSONEncoder().encode(candidate)
            try configurationFile?.saveInstallation(InstallationHistory(
                hasRegisteredAccount: candidate.hasRegisteredAccount,
                firstAccountRegisteredAt: candidate.firstAccountRegisteredAt
            ))
            if candidate != committedBundle { userDefaults.set(data, forKey: Keys.settingsBundle) }
            committedBundle = candidate
            persistenceError = nil
            cleanupQuotaSnapshots()
            return true
        } catch {
            if let committedBundle {
                restore(committedBundle.settings)
                hasRegisteredAccount = committedBundle.hasRegisteredAccount
                firstAccountRegisteredAt = committedBundle.firstAccountRegisteredAt
            }
            persistenceError = "설정을 반영하지 못했습니다: \(error.localizedDescription)"
            return false
        }
    }

    /// 인증정보를 제외한 운영 설정 묶음 구성
    private var currentPayload: AppPreferencesPayload {
        AppPreferencesPayload(accountPaths: accountPaths, enabledAccountIDs: enabledAccountIDs,
            accountDisplayOrder: accountDisplayOrder, refreshIntervalMinutes: refreshIntervalMinutes,
            resetReminderMinutes: resetReminderMinutes,
            activityNotificationDurationSeconds: activityNotificationDurationSeconds,
            showAccountLabels: showAccountLabels, launchAtLogin: launchAtLogin,
            accountDisplayNames: accountDisplayNames, tokenUsageOptions: tokenUsageOptions,
            automaticResetPingEnabled: automaticResetPingEnabled)
    }

    /// 인코딩 실패 시 직전 정상 설정 복원
    private func restore(_ value: AppPreferencesPayload) {
        tokenUsageOptions = value.tokenUsageOptions ?? TokenUsageOptions()
        accountPaths = value.accountPaths
        enabledAccountIDs = value.enabledAccountIDs
        accountDisplayOrder = value.accountDisplayOrder
        accountDisplayNames = Self.normalizedAccountDisplayNames(value.accountDisplayNames ?? [:])
        refreshIntervalMinutes = value.refreshIntervalMinutes
        resetReminderMinutes = value.resetReminderMinutes
        automaticResetPingEnabled = value.automaticResetPingEnabled ?? false
        activityNotificationDurationSeconds = value.activityNotificationDurationSeconds
        showAccountLabels = value.showAccountLabels
        launchAtLogin = value.launchAtLogin
    }

    nonisolated public static func normalizedActivityNotificationDurationSeconds(_ seconds: Int) -> Int {
        min(
            max(seconds, minimumActivityNotificationDurationSeconds),
            maximumActivityNotificationDurationSeconds
        )
    }

    public static func normalizedPaths(
        _ paths: [String]?,
        defaults: [String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        normalizedPathResult(paths, defaults: defaults, homeDirectory: homeDirectory).values
    }

    /// 목적: 유효한 계정 ID를 대문자 표준형·중복 없는 배열로 변환
    private static func normalizedAccountIDs(_ ids: [String]?) -> [String] {
        guard let ids else { return defaultEnabledAccountIDs }
        var normalized: [String] = []
        for id in ids {
            let canonical = id.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard stableAccountIDs.contains(canonical), !normalized.contains(canonical) else { continue }
            normalized.append(canonical)
        }
        return normalized
    }

    /// 목적: 활성 계정 ID를 전체 계정의 완전한 표시 순서로 변환
    /// 조건: 중복·알 수 없는 ID 제거 후 누락 ID를 기본 순서로 추가
    private static func normalizedAccountDisplayOrder(_ ids: [String]?) -> [String] {
        guard let ids else { return defaultAccountDisplayOrder }
        var normalized = normalizedAccountIDs(ids)
        let missingIDs = stableAccountIDs.filter { !normalized.contains($0) }
        normalized.append(contentsOf: missingIDs)
        return normalized
    }

    /// 안정된 슬롯 키만 유지하고 빈 표시 이름은 기본값으로 위임
    private static func normalizedAccountDisplayNames(_ names: [String: String]) -> [String: String] {
        stableAccountIDs.reduce(into: [:]) { result, id in
            let value = AccountDisplayName.normalized(names[id] ?? "")
            if !value.isEmpty { result[id] = value }
        }
    }

    private struct PathNormalization: Sendable {
        let values: [String]
        let changed: Bool
    }

    private static func normalizedPathResult(
        _ paths: [String]?,
        defaults: [String],
        homeDirectory: URL
    ) -> PathNormalization {
        let normalizedDefaults = normalizedDefaultPaths(defaults, homeDirectory: homeDirectory)
        guard let paths, paths.count == accountPathCount else {
            return PathNormalization(values: normalizedDefaults, changed: paths != nil)
        }

        let values = paths.enumerated().map { index, value in
            let canonical = canonicalPath(value, homeDirectory: homeDirectory)
            // Empty is a deliberate unconfigured value. Defaults are used
            // only when the entire persisted collection is missing or has an
            // invalid slot count.
            return canonical
        }
        return PathNormalization(values: values, changed: values != paths)
    }

    /// 명시적 기본 경로만 정규화하고 비어 있는 초기 슬롯은 그대로 보존
    private static func normalizedDefaultPaths(_ paths: [String], homeDirectory: URL) -> [String] {
        guard paths.count == accountPathCount else { return Array(repeating: "", count: accountPathCount) }
        return paths.map { canonicalPath($0, homeDirectory: homeDirectory) }
    }

    private static func canonicalPath(_ path: String, homeDirectory: URL) -> String {
        AccountConfig.normalizedPath(path, homeDirectory: homeDirectory)
    }

    private static func decodedQuotaSnapshots(
        _ data: Data?,
        homeDirectory: URL
    ) -> [String: QuotaSnapshot] {
        guard let data,
              let decoded = try? JSONDecoder().decode([String: QuotaSnapshot].self, from: data)
        else {
            return [:]
        }

        return decoded.reduce(into: [:]) { snapshots, entry in
            let normalizedPath = normalizedAccountPath(entry.key, homeDirectory: homeDirectory)
            guard !normalizedPath.isEmpty else { return }
            snapshots[normalizedPath] = entry.value
        }
    }
}
