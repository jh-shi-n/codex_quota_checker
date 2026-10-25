import Foundation

public enum AccountPosition: String, Codable, Equatable, Sendable {
    case left
    case right
}

/// The result of validating a user-supplied account home path.
///
/// Empty is intentionally a successful, unconfigured state. Every other
/// non-valid case is kept distinct so settings can explain what needs to be
/// fixed without exposing any account data.
public enum AccountPathValidation: Equatable, Sendable {
    case empty
    case missing
    case notDirectory
    case unreadable
    case valid

    /// Compatibility spelling for callers that describe the failure as
    /// "nonexistent" rather than "missing".
    public static var nonexistent: Self { .missing }

    /// Compatibility spelling for callers that describe a regular file as a
    /// regular-file failure rather than a non-directory failure.
    public static var regularFile: Self { .notDirectory }

    public var isAcceptable: Bool {
        self == .empty || self == .valid
    }

    public var isConfigured: Bool {
        self == .valid
    }

    /// 설정 화면의 계정 경로 검증 오류 안내 및 정상 경로의 문구 생략
    public var userMessage: String? {
        switch self {
        case .empty, .valid:
            return nil
        case .missing:
            return "계정 경로가 존재하지 않습니다."
        case .notDirectory:
            return "계정 경로는 폴더여야 합니다."
        case .unreadable:
            return "계정 폴더를 읽을 수 없습니다."
        }
    }
}

/// File metadata used by account-path validation. Keeping this as a value
/// type makes filesystem behavior straightforward to inject in tests without
/// touching real account directories.
public struct AccountPathFileMetadata: Equatable, Sendable {
    public let exists: Bool
    public let isDirectory: Bool
    public let isReadable: Bool

    public init(exists: Bool, isDirectory: Bool, isReadable: Bool) {
        self.exists = exists
        self.isDirectory = isDirectory
        self.isReadable = isReadable
    }
}

/// The small filesystem seam needed to distinguish path validation failures.
/// The live implementation uses only metadata queries and never reads an
/// authentication file.
public struct AccountPathFileSystem: Sendable {
    public let metadata: @Sendable (String) -> AccountPathFileMetadata

    public init(metadata: @escaping @Sendable (String) -> AccountPathFileMetadata) {
        self.metadata = metadata
    }

    public static var live: Self {
        Self { path in
            let fileManager = FileManager()
            var directoryFlag = ObjCBool(false)
            let exists = fileManager.fileExists(atPath: path, isDirectory: &directoryFlag)
            return AccountPathFileMetadata(
                exists: exists,
                isDirectory: exists && directoryFlag.boolValue,
                isReadable: exists && fileManager.isReadableFile(atPath: path)
            )
        }
    }
}

/// Normalization and validation policy shared by preferences and settings.
public struct AccountPathValidator: Sendable {
    public let homeDirectory: URL
    public let fileSystem: AccountPathFileSystem

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileSystem: AccountPathFileSystem = .live
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.fileSystem = fileSystem
    }

    public static var live: Self { Self() }

    public func normalizedPath(_ path: String) -> String {
        AccountConfig.normalizedPath(path, homeDirectory: homeDirectory)
    }

    public func validate(_ path: String) -> AccountPathValidation {
        AccountConfig.validatePath(
            path,
            homeDirectory: homeDirectory,
            fileSystem: fileSystem
        )
    }
}

/// Configuration that identifies an isolated CODEX_HOME and its notch side.
public struct AccountConfig: Identifiable, Codable, Equatable, Hashable, Sendable {
    public static let stableAccountIDs = ["C1", "C2", "C3", "C4"]

    public let id: String
    public let home: URL
    public let position: AccountPosition
    public let provider: AccountProvider
    /// Explicitly distinguishes an empty settings slot from a real CODEX_HOME.
    /// `home` remains a URL for source compatibility with existing hosts, but
    /// callers must use `configuredHome` when accessing the filesystem.
    public let isConfigured: Bool

    public init(id: String, home: URL, position: AccountPosition, provider: AccountProvider = .codex) {
        self.id = id
        self.home = home.standardizedFileURL
        self.position = position
        self.provider = provider
        self.isConfigured = true
    }

    private init(id: String, unconfiguredPosition position: AccountPosition) {
        self.id = id
        self.home = Self.unconfiguredHomeURL(for: id)
        self.position = position
        self.provider = .codex
        self.isConfigured = false
    }

    /// Creates a stable account slot with no CODEX_HOME configured.
    public static func unconfigured(id: String, position: AccountPosition) -> Self {
        Self(id: id, unconfiguredPosition: position)
    }

    /// Creates a configuration from the same path strings persisted by
    /// preferences. Empty and whitespace-only values remain unconfigured;
    /// they are never converted through `URL(fileURLWithPath:)`.
    public init(
        id: String,
        path: String,
        position: AccountPosition,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        provider: AccountProvider = .codex
    ) {
        let normalized = Self.normalizedPath(path, homeDirectory: homeDirectory)
        if normalized.isEmpty {
            self.init(id: id, unconfiguredPosition: position)
        } else {
            self.init(id: id, home: URL(fileURLWithPath: normalized), position: position, provider: provider)
        }
    }

    /// The filesystem URL for a configured account, or `nil` for an empty
    /// settings slot. This is the preferred access point for new callers.
    public var configuredHome: URL? {
        isConfigured ? home : nil
    }

    public var authFile: URL {
        home.appendingPathComponent("auth.json", isDirectory: false)
    }

    private static func unconfiguredHomeURL(for id: String) -> URL {
        // A non-file URL is deliberately used as a compatibility value for
        // the historical non-optional `home` property. All I/O paths are
        // guarded by `isConfigured`/`configuredHome`, so it cannot resolve to
        // the app's current working directory.
        URL(string: "codex-unconfigured://\(id)")!
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case home
        case position
        case isConfigured
        case provider
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let position = try container.decode(AccountPosition.self, forKey: .position)
        let provider = try container.decodeIfPresent(AccountProvider.self, forKey: .provider) ?? .codex
        let decodedHome = try container.decodeIfPresent(URL.self, forKey: .home)
        let configuredFlag = try container.decodeIfPresent(Bool.self, forKey: .isConfigured)

        if configuredFlag == false {
            self.init(id: id, unconfiguredPosition: position)
            return
        }

        guard let decodedHome else {
            throw DecodingError.keyNotFound(
                CodingKeys.home,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Configured account is missing home"
                )
            )
        }

        if configuredFlag == true {
            self.init(id: id, home: decodedHome, position: position, provider: provider)
            return
        }

        // Older snapshots did not have `isConfigured`; infer it from the
        // encoded home while preserving their Codable representation.
        let legacyPath = decodedHome.path.trimmingCharacters(in: .whitespacesAndNewlines)
        if legacyPath.isEmpty || decodedHome.scheme == "codex-unconfigured" {
            self.init(id: id, unconfiguredPosition: position)
        } else {
            self.init(id: id, home: decodedHome, position: position, provider: provider)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(position, forKey: .position)
        try container.encode(provider, forKey: .provider)
        try container.encode(isConfigured, forKey: .isConfigured)
        // Keep a home key for old decoders while ensuring an unconfigured
        // value cannot be interpreted as a relative file URL/CWD.
        try container.encode(
            isConfigured ? home : Self.unconfiguredHomeURL(for: id),
            forKey: .home
        )
    }

    /// Returns the canonical path used for preferences and snapshot keys.
    /// Leading `~` forms are resolved against the supplied home directory;
    /// no user-specific path is embedded in the application.
    public static func normalizedPath(
        _ path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let normalizedHome = homeDirectory.standardizedFileURL
        if trimmed == "~" {
            return normalizedHome.path
        }
        if trimmed.hasPrefix("~/") {
            return normalizedHome
                .appendingPathComponent(String(trimmed.dropFirst(2)), isDirectory: false)
                .standardizedFileURL
                .path
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    /// Distinguishes an unconfigured slot, a missing path, a regular file,
    /// an unreadable directory, and a usable directory.
    public static func validatePath(
        _ path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileSystem: AccountPathFileSystem = .live
    ) -> AccountPathValidation {
        let normalized = normalizedPath(path, homeDirectory: homeDirectory)
        guard !normalized.isEmpty else { return .empty }

        let metadata = fileSystem.metadata(normalized)
        guard metadata.exists else { return .missing }
        guard metadata.isDirectory else { return .notDirectory }
        guard metadata.isReadable else { return .unreadable }
        return .valid
    }

    /// Builds stable C1-C4 configurations from persisted settings paths.
    public static func accounts(
        for paths: [String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        providers: [String: AccountProvider] = [:]
    ) -> [AccountConfig] {
        let defaults = defaultAccounts(homeDirectory: homeDirectory)
        return stableAccountIDs.enumerated().map { index, id in
            guard paths.indices.contains(index) else { return defaults[index] }
            return AccountConfig(
                id: id,
                path: paths[index],
                position: index < 2 ? .left : .right,
                homeDirectory: homeDirectory,
                provider: providers[id] ?? .codex
            )
        }
    }

    /// The four accounts used by the monitor by default.
    public static func defaultAccounts(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AccountConfig] {
        [
            AccountConfig(id: "C1", home: homeDirectory.appendingPathComponent(".codex-1"), position: .left),
            AccountConfig(id: "C2", home: homeDirectory.appendingPathComponent(".codex-2"), position: .left),
            AccountConfig(id: "C3", home: homeDirectory.appendingPathComponent(".codex-3"), position: .right),
            AccountConfig(id: "C4", home: homeDirectory.appendingPathComponent(".codex-4"), position: .right),
        ]
    }
}
