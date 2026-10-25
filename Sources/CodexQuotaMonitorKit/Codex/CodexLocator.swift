import Foundation

public protocol CodexLocating: Sendable {
    func locate() -> URL?
}

/// Finds the Codex executable without invoking a shell or mutating account state.
public struct CodexLocator: CodexLocating, Sendable {
    public static let defaultCandidatePaths: [URL] = [
        URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
        URL(fileURLWithPath: "/usr/local/bin/codex"),
        URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
    ]

    public let pathEnvironment: String?
    public let candidatePaths: [URL]

    public init(
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"],
        candidatePaths: [URL] = CodexLocator.defaultCandidatePaths
    ) {
        self.pathEnvironment = pathEnvironment
        self.candidatePaths = candidatePaths
    }

    public func locate() -> URL? {
        var paths: [URL] = []
        if let pathEnvironment {
            paths.append(contentsOf: pathEnvironment.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("codex")
            })
        }
        paths.append(contentsOf: candidatePaths)

        var seen = Set<String>()
        for path in paths {
            let standardized = path.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { continue }
            if FileManager.default.isExecutableFile(atPath: standardized.path) {
                return standardized
            }
        }
        return nil
    }
}
