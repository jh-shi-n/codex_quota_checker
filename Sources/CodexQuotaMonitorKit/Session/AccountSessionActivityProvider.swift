import Foundation

/// Routes activity reads using the registered account provider, never the directory name.
public struct AccountSessionActivityProvider: SessionActivityProvider {
    private let codex: any SessionActivityProvider
    private let claude: any SessionActivityProvider

    public init(codex: any SessionActivityProvider = SQLiteSessionActivityProvider(),
                claude: any SessionActivityProvider = ClaudeSessionActivityProvider()) {
        self.codex = codex
        self.claude = claude
    }

    public func snapshot(for config: AccountConfig) async -> SessionActivitySnapshot {
        guard config.isConfigured else { return .unavailable(accountID: config.id) }
        let provider = config.provider == .claude ? claude : codex
        return await provider.snapshot(accountID: config.id, home: config.home)
    }

    public func snapshot(accountID: String, home: URL) async -> SessionActivitySnapshot {
        await codex.snapshot(accountID: accountID, home: home)
    }
}
