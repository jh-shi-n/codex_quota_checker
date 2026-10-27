// 목적: config.json의 최초 실행 표식·등록 이력 저장과 이전 설정 이관
// 이용처: 앱 시작과 최초 계정 등록·기존 설정 이관
// 사용방법: PreferencesStore에 이관 원본 경로 전달
import Foundation

/// 인증 정보 없이 저장 가능한 앱 설정의 명시적 허용 목록
public struct AppPreferencesPayload: Codable, Equatable, Sendable {
    public var accountPaths: [String]
    public var enabledAccountIDs: [String]
    public var accountDisplayOrder: [String]
    public var refreshIntervalMinutes: Int
    public var resetReminderMinutes: Int
    public var activityNotificationDurationSeconds: Int
    public var showAccountLabels: Bool
    public var launchAtLogin: Bool
    /// 이전 JSON의 필드 누락과 기존 멤버별 초기화 호출 호환
    public var accountDisplayNames: [String: String]? = nil
    /// 이전 설정의 필드 누락을 허용하는 토큰 차트·보관 정책
    public var tokenUsageOptions: TokenUsageOptions? = nil
    /// 이전 설정의 필드 누락은 자동 Ping 미사용으로 처리
    public var automaticResetPingEnabled: Bool? = nil
    public var automaticRefreshEnabled: Bool? = nil
    /// 누락·알 수 없는 스타일의 링 기본값 호환을 위한 원시 문자열
    public var notchDisplayStyle: String? = nil

    /// 기존 정규화 경로와 동일한 키를 사용하는 설정 로드 어댑터
    @MainActor var preferenceValues: [String: Any] {
        [
            PreferencesStore.Keys.accountPaths: accountPaths,
            PreferencesStore.Keys.enabledAccountIDs: enabledAccountIDs,
            PreferencesStore.Keys.accountDisplayOrder: accountDisplayOrder,
            PreferencesStore.Keys.accountDisplayNames: accountDisplayNames ?? [:],
            PreferencesStore.Keys.tokenUsageOptions: tokenUsageOptions ?? TokenUsageOptions(),
            PreferencesStore.Keys.refreshIntervalMinutes: refreshIntervalMinutes,
            PreferencesStore.Keys.resetReminderMinutes: resetReminderMinutes,
            PreferencesStore.Keys.automaticResetPingEnabled: automaticResetPingEnabled ?? false,
            PreferencesStore.Keys.automaticRefreshEnabled: automaticRefreshEnabled ?? true,
            PreferencesStore.Keys.activityNotificationDurationSeconds: activityNotificationDurationSeconds,
            PreferencesStore.Keys.showAccountLabels: showAccountLabels,
            PreferencesStore.Keys.notchDisplayStyle: notchDisplayStyle ?? "ring",
            PreferencesStore.Keys.launchAtLogin: launchAtLogin,
        ]
    }
}

/// 과거 실행 이력과 앱 설정을 읽기 위한 버전 2 호환 자료형
public struct AppConfigurationDocument: Codable, Equatable, Sendable {
    public var schemaVersion = 2
    public var installation: InstallationHistory?
    public var settings: AppPreferencesPayload?
}

/// 최초 실행 표식·등록 이력과 이전 설정 이관의 파일 경계
@MainActor
public final class AppConfigurationFile {
    public let fileURL: URL

    /// 사용자별 앱 지원 폴더의 공용 설정 경로
    public static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("CodexQuotaMonitor/config.json")
    }

    /// 실제 사용자 파일 또는 격리된 테스트 파일 연결
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 신규 실행 판별용 config.json 자체의 존재 여부; 이전 파일과 구분
    public var exists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    /// 이전 파일명·버전 1 이력의 복원 및 알 수 없는 버전의 저장 차단
    public func read() throws -> AppConfigurationDocument? {
        let legacy = fileURL.deletingLastPathComponent().appendingPathComponent("installation.json")
        let source = !FileManager.default.fileExists(atPath: fileURL.path)
            && fileURL.lastPathComponent == "config.json"
            && FileManager.default.fileExists(atPath: legacy.path) ? legacy : fileURL
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let data = try Data(contentsOf: source)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = Self.registrationDate(from: text) else { throw CocoaError(.fileReadCorruptFile) }
            return date
        }
        let header = try decoder.decode(VersionHeader.self, from: data)
        if header.schemaVersion == nil {
            let record = try decoder.decode(RegistrationRecord.self, from: data)
            guard record.hasRegisteredAccount || record.firstAccountRegisteredAt == nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return AppConfigurationDocument(installation: InstallationHistory(
                hasRegisteredAccount: record.hasRegisteredAccount,
                firstAccountRegisteredAt: record.firstAccountRegisteredAt
            ), settings: record.settings)
        }
        if header.schemaVersion == 1 {
            let history = try decoder.decode(InstallationHistory.self, from: data)
            guard history.schemaVersion == 1, history.hasRegisteredAccount || history.firstAccountRegisteredAt == nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return AppConfigurationDocument(installation: history)
        }
        guard header.schemaVersion == 2 else { throw CocoaError(.fileReadCorruptFile) }
        let document = try decoder.decode(AppConfigurationDocument.self, from: data)
        if let history = document.installation, history.schemaVersion != 1 || (!history.hasRegisteredAccount && history.firstAccountRegisteredAt != nil) {
            throw CocoaError(.fileReadCorruptFile)
        }
        return document
    }

    /// 앱 설정 변경 시 실행 이력의 최신 파일 값 보존
    public func saveSettings(_ settings: AppPreferencesPayload) throws {
        var document = try read() ?? AppConfigurationDocument()
        guard document.settings != settings else { return }
        document.settings = settings
        try write(document)
    }

    /// 등록 이력만 동기화하고 동일 값의 반복 기록·이전 설정의 유실 방지
    public func saveInstallation(_ history: InstallationHistory) throws {
        guard history.schemaVersion == 1, history.hasRegisteredAccount || history.firstAccountRegisteredAt == nil,
              history.firstAccountRegisteredAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true else {
            throw CocoaError(.coderInvalidValue)
        }
        var document = try read() ?? AppConfigurationDocument()
        if exists, document.installation == history,
           try JSONDecoder().decode(VersionHeader.self, from: Data(contentsOf: fileURL)).schemaVersion == nil {
            return
        }
        document.installation = history
        try write(document)
    }

    /// 허용된 Codable 필드만 원자적으로 저장하고 사용자 전용 파일 권한 적용
    private func write(_ document: AppConfigurationDocument) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.registrationDateText(date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let record = RegistrationRecord(
            hasRegisteredAccount: document.installation?.hasRegisteredAccount ?? false,
            firstAccountRegisteredAt: document.installation?.firstAccountRegisteredAt,
            settings: document.settings
        )
        try encoder.encode(record).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// UserDefaults의 Date 정밀도를 보존한 ISO 8601 UTC 문자열 구성
    nonisolated private static func registrationDateText(_ date: Date) -> String {
        let reference = date.timeIntervalSinceReferenceDate
        let integral = floor(reference)
        let formatter = ISO8601DateFormatter()
        let base = formatter.string(from: Date(timeIntervalSinceReferenceDate: integral))
        let fraction = String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), reference - integral).dropFirst()
        return String(base.dropLast()) + fraction + "Z"
    }

    /// 기존 초 단위·새 소수 초 UTC 표현의 동일 Date 복원
    nonisolated private static func registrationDate(from text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if text.hasSuffix("Z"), let dot = text.lastIndex(of: ".") {
            let base = String(text[..<dot]) + "Z"
            let digits = text[text.index(after: dot)..<text.index(before: text.endIndex)]
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let fraction = Double("0." + digits),
                  let integral = formatter.date(from: base) else { return nil }
            return Date(timeIntervalSinceReferenceDate: integral.timeIntervalSinceReferenceDate + fraction)
        }
        return formatter.date(from: text)
    }

    /// 등록 여부·등록일자의 새 파일 형식; 과거 설정은 이관 원본으로만 보존
    private struct RegistrationRecord: Codable {
        let hasRegisteredAccount: Bool
        let firstAccountRegisteredAt: Date?
        let settings: AppPreferencesPayload?

        private enum CodingKeys: String, CodingKey {
            case hasRegisteredAccount, firstAccountRegisteredAt, settings
        }

        /// 날짜 미상도 null로 명시하고 형식 버전·실행 횟수 저장 제외
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(hasRegisteredAccount, forKey: .hasRegisteredAccount)
            try values.encode(firstAccountRegisteredAt, forKey: .firstAccountRegisteredAt)
            try values.encodeIfPresent(settings, forKey: .settings)
        }
    }

    /// 임의 필드 저장 없이 파일 형식 버전만 판별하는 읽기 경계
    private struct VersionHeader: Decodable {
        let schemaVersion: Int?
    }
}
