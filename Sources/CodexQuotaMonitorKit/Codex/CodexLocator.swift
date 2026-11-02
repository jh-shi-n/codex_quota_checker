import Foundation

public protocol CodexLocating: Sendable {
    func locate() -> URL?
}

/// Finds the Codex executable without mutating account state. A login shell is
/// consulted only after PATH, fixed locations, and version managers all miss.
public struct CodexLocator: CodexLocating, Sendable {
    public static let defaultCandidatePaths: [URL] = [
        URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
        URL(fileURLWithPath: "/usr/local/bin/codex"),
    ]

    public let pathEnvironment: String?
    public let candidatePaths: [URL]
    public let homeDirectory: URL
    private let loginShellPath: @Sendable () -> String?

    public init(
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"],
        candidatePaths: [URL] = CodexLocator.defaultCandidatePaths,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        loginShellPath: (@Sendable () -> String?)? = nil
    ) {
        self.pathEnvironment = pathEnvironment
        self.candidatePaths = candidatePaths
        self.homeDirectory = homeDirectory
        self.loginShellPath = loginShellPath ?? CLIPathDiscovery.sharedLoginShellPath
    }

    public func locate() -> URL? {
        CLIPathDiscovery.locate(
            name: "codex",
            pathEnvironment: pathEnvironment,
            candidatePaths: candidatePaths,
            homeDirectory: homeDirectory,
            loginShellPath: loginShellPath
        )
    }
}
