import Foundation

/// A deliberately small status vocabulary for last-known CLI metadata. Raw
/// database values are never exposed to the UI.
public enum SessionActivityStatus: String, Equatable, Sendable {
    case working
    case waiting
    case inactive
    case completed
    case stopped
    case error
    case unknown

    public static func map(raw: String?) -> SessionActivityStatus {
        guard let raw else { return .unknown }
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch normalized {
        case "open", "running", "pending", "pending_init", "pendinginit", "started", "active", "in_progress", "inprogress":
            return .working
        case "waiting", "waiting_on_user_input", "waitingonuserinput", "waiting_on_approval", "waitingonapproval":
            return .waiting
        case "completed", "closed", "shutdown", "done", "success":
            return .completed
        case "interrupted", "stopped", "cancelled", "canceled":
            return .stopped
        case "error", "errored", "failed", "failure", "system_error", "systemerror":
            return .error
        default:
            return .unknown
        }
    }

    /// 세션 화면과 활동 알림에서 공통 사용하는 한글 상태 문구
    public var displayText: String {
        switch self {
        case .working: return "작업 중"
        case .waiting: return "대기 중"
        case .inactive: return "활동 없음"
        case .completed: return "완료"
        case .stopped: return "중단"
        case .error: return "오류"
        case .unknown: return "확인 불가"
        }
    }

    public var isOpen: Bool {
        self == .working || self == .waiting
    }
}

public enum SessionActivitySnapshotState: String, Equatable, Sendable {
    case available
    case empty
    case unavailable
}

public enum SessionActivitySource: String, Equatable, Sendable {
    /// Normalized source values retained for source selection and compatibility.
    /// Source badges are intentionally not a presentation surface anymore.
    case cli = "CLI"
    case codexApp = "Codex App"
    case liveAppServer = "Live app-server"

    // Compatibility values retained for the original single-snapshot API.
    case localActivity = "Local activity"
    case lastKnown = "Last known"
    case unavailable = "Session status unavailable"

    /// Values accepted from the `threads.thread_source` column. Keep this
    /// list explicit: an unrecognized or web/browser value must never be
    /// silently mislabeled as a local source.
    public static let recognizedThreadSourceValues: Set<String> = [
        "cli", "user", "app", "codex_app",
    ]

    public static func normalize(raw: String?) -> SessionActivitySource? {
        guard let raw else { return nil }
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch normalized {
        case "cli", "user":
            return .cli
        case "app", "codex_app":
            return .codexApp
        default:
            return nil
        }
    }

    public var badgeText: String? {
        // Sources remain useful for internal filtering and compatibility, but
        // are never rendered as badges in the activity cards.
        nil
    }

    public var isSupportedLocalSource: Bool {
        self == .cli || self == .codexApp
    }
}

/// The only operation categories that may cross the app-server privacy
/// boundary. A command's text, output, path, and raw item identifier are
/// deliberately not represented here.
public enum SessionActivityOperationCategory: String, Equatable, Sendable {
    case command = "Command"
    case fileChange = "File change"
    case tool = "Tool"
    case review = "Review"
    case agent = "Agent"

    public static func normalize(raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch normalized {
        case "command", "command_execution", "commandexecution", "shell", "exec":
            return command.rawValue
        case "file_change", "filechange", "patch", "apply_patch", "applypatch":
            return fileChange.rawValue
        case "tool", "mcp", "mcp_tool_call", "mcptoolcall", "web_search", "websearch", "image_generation", "imagegeneration":
            return tool.rawValue
        case "review", "code_review", "codereview":
            return review.rawValue
        case "agent", "agent_message", "agentmessage", "collab_agent_tool_call", "collabagenttoolcall":
            return agent.rawValue
        default:
            return nil
        }
    }
}

/// Sanitizes text that is explicitly designated as a title or a completed
/// plan step. This helper rejects content-shaped fields and path-like values;
/// it is intentionally conservative because presentation must never become a
/// transcript or command-output viewer.
enum SessionActivityMetadataSanitizer {
    static let maximumLength = 80
    private static let protectedTokens = [
        "reasoning", "reasoning_summary", "summary", "prompt", "transcript",
        "command output", "aggregated output", "patch", "rollout", "history",
        "message content", "first user message",
    ]

    static func text(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }
        let normalized = cleaned.joined()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let lowercased = normalized.lowercased()
        guard !protectedTokens.contains(where: { lowercased.contains($0) }),
              !normalized.contains("/"),
              !normalized.contains("\\"),
              !lowercased.contains("://") else {
            return nil
        }
        return String(normalized.prefix(maximumLength))
    }

    /// 모델 식별자의 ASCII·길이 제한 및 표시용 대소문자 정규화
    static func modelIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 64,
              normalized.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-").contains($0)
              }),
              normalized.first?.isLetter == true, normalized.last?.isLetter == true || normalized.last?.isNumber == true
        else { return nil }
        let parts = normalized.lowercased().split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return parts.enumerated().map { index, part in
            index == 0 && part == "gpt" ? "GPT" : String(part).capitalized
        }.joined(separator: "-")
    }

    /// 지원하는 추론 등급만 소문자로 제한
    static func reasoningEffort(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].contains(normalized)
            ? normalized : nil
    }

    /// Returns only the final component of an agent path after converting it
    /// into a safe, title-shaped value. The raw path is never returned.
    static func agentPathComponent(_ value: String?) -> String? {
        guard let value else { return nil }
        let component = value
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map(String.init)
        guard let component else { return nil }
        return text(
            component
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
        )
    }
}

/// Metadata for one descendant thread. `threadID` is retained for internal
/// relation/deduplication work; presentation must never render it.
public struct SessionActivityAgent: Identifiable, Equatable, Sendable {
    public let threadID: String
    public let parentThreadID: String?
    /// Nickname/role identity, independent from the work description.
    public let displayName: String
    /// Privacy-filtered task text. It is never a raw path or prompt.
    public let taskName: String
    public let status: SessionActivityStatus
    /// 세션별 모델·추론 등급 메타데이터
    public let model: String?
    public let reasoningEffort: String?

    public var id: String { threadID }
    /// Compatibility alias for callers that use the generic display label.
    public var label: String { displayName }

    public init(
        threadID: String,
        parentThreadID: String?,
        taskName: String,
        status: SessionActivityStatus,
        displayName: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil
    ) {
        self.threadID = threadID
        self.parentThreadID = parentThreadID
        self.displayName = SessionActivityMetadataSanitizer.text(displayName)
            ?? SessionActivityMetadataSanitizer.text(taskName)
            ?? "Agent"
        self.taskName = SessionActivityMetadataSanitizer.text(taskName) ?? "Agent"
        self.status = status
        self.model = SessionActivityMetadataSanitizer.modelIdentifier(model)
        self.reasoningEffort = SessionActivityMetadataSanitizer.reasoningEffort(reasoningEffort)
    }

    public init(
        threadID: String,
        parentThreadID: String?,
        label: String,
        status: SessionActivityStatus,
        taskName: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil
    ) {
        self.init(
            threadID: threadID,
            parentThreadID: parentThreadID,
            taskName: taskName ?? label,
            status: status,
            displayName: label,
            model: model,
            reasoningEffort: reasoningEffort
        )
    }
}

/// One local main/root session and all of its descendant agents.
public struct SessionActivityMainSession: Identifiable, Equatable, Sendable {
    public let threadID: String
    public let source: SessionActivitySource
    public let taskName: String
    public let status: SessionActivityStatus
    /// 명시적 메인 응답 이벤트의 중복 판별용 턴 번호
    public let turnID: String?
    /// 완료 알림의 신규 발생 여부를 판단하는 원본 이벤트 시각
    public let turnEventAt: Date?
    public let agents: [SessionActivityAgent]
    public let isActive: Bool
    /// Safe public progress metadata. SQLite fallback leaves these values nil.
    public let planStep: String?
    public let activeOperation: String?
    /// 메인 세션에서 관측한 모델·추론 등급
    public let model: String?
    public let reasoningEffort: String?
    /// Last metadata activity used only for deterministic card ordering.
    public let lastActivityAt: Date?

    public var id: String { threadID }
    public var sessionID: String { threadID }
    public var displayName: String { taskName }
    public var title: String { taskName }
    public var recencyAt: Date? { lastActivityAt }
    public var operationCategory: String? { activeOperation }

    public init(
        threadID: String,
        source: SessionActivitySource,
        taskName: String,
        status: SessionActivityStatus,
        agents: [SessionActivityAgent],
        isActive: Bool = true,
        planStep: String? = nil,
        activeOperation: String? = nil,
        lastActivityAt: Date? = nil,
        turnID: String? = nil,
        turnEventAt: Date? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil
    ) {
        self.threadID = threadID
        self.source = source
        self.taskName = SessionActivityMetadataSanitizer.text(taskName) ?? "Codex session"
        self.status = status
        self.turnID = turnID
        self.turnEventAt = turnEventAt
        self.agents = agents
        self.isActive = isActive
        self.planStep = SessionActivityMetadataSanitizer.text(planStep)
        self.activeOperation = SessionActivityOperationCategory.normalize(raw: activeOperation)
        self.lastActivityAt = lastActivityAt
        self.model = SessionActivityMetadataSanitizer.modelIdentifier(model)
        self.reasoningEffort = SessionActivityMetadataSanitizer.reasoningEffort(reasoningEffort)
    }

    public init(
        sessionID: String,
        source: SessionActivitySource,
        taskName: String,
        status: SessionActivityStatus,
        agents: [SessionActivityAgent],
        isActive: Bool = true,
        planStep: String? = nil,
        activeOperation: String? = nil,
        lastActivityAt: Date? = nil,
        turnID: String? = nil,
        turnEventAt: Date? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil
    ) {
        self.init(
            threadID: sessionID,
            source: source,
            taskName: taskName,
            status: status,
            agents: agents,
            isActive: isActive,
            planStep: planStep,
            activeOperation: activeOperation,
            lastActivityAt: lastActivityAt,
            turnID: turnID,
            turnEventAt: turnEventAt,
            model: model,
            reasoningEffort: reasoningEffort
        )
    }

    /// Title-shaped initializer used by app-server projections. The legacy
    /// `taskName` initializer remains source-compatible with the SQLite path.
    public init(
        threadID: String,
        title: String,
        status: SessionActivityStatus,
        agents: [SessionActivityAgent],
        source: SessionActivitySource = .liveAppServer,
        isActive: Bool = true,
        planStep: String? = nil,
        activeOperation: String? = nil,
        lastActivityAt: Date? = nil,
        turnID: String? = nil,
        turnEventAt: Date? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil
    ) {
        self.init(
            threadID: threadID,
            source: source,
            taskName: title,
            status: status,
            agents: agents,
            isActive: isActive,
            planStep: planStep,
            activeOperation: activeOperation,
            lastActivityAt: lastActivityAt,
            turnID: turnID,
            turnEventAt: turnEventAt,
            model: model,
            reasoningEffort: reasoningEffort
        )
    }
}

public extension SessionActivityMainSession {
    /// Stable card ordering: active work first, then waiting work, then all
    /// remaining states by most recent safe metadata activity.
    static func ordered(_ sessions: [SessionActivityMainSession]) -> [SessionActivityMainSession] {
        sessions.sorted(by: precedes)
    }

    /// 중간 배열 없이 작업 상태·최근 시각·번호 순서 직접 비교
    static func precedes(_ lhs: SessionActivityMainSession, _ rhs: SessionActivityMainSession) -> Bool {
        let lhsRank = orderingRank(for: lhs)
        let rhsRank = orderingRank(for: rhs)
        if lhsRank != rhsRank { return lhsRank < rhsRank }

        let lhsDate = lhs.lastActivityAt ?? .distantPast
        let rhsDate = rhs.lastActivityAt ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return lhs.threadID < rhs.threadID
    }

    static func orderingRank(for session: SessionActivityMainSession) -> Int {
        switch session.status {
        case .working:
            return 0
        case .waiting:
            return 1
        case .inactive, .completed, .stopped, .error, .unknown:
            return 2
        }
    }
}

public struct SessionActivitySnapshot: Equatable, Sendable {
    public let accountID: String
    public let state: SessionActivitySnapshotState
    public let source: SessionActivitySource
    public let sessionID: String?
    public let status: SessionActivityStatus
    public let agents: [SessionActivityAgent]
    /// All currently projected local main sessions. The legacy scalar fields
    /// above mirror the first session for existing toast/monitor callers.
    public let sessions: [SessionActivityMainSession]

    public var mainSessions: [SessionActivityMainSession] { sessions }

    public init(
        accountID: String,
        state: SessionActivitySnapshotState,
        source: SessionActivitySource,
        sessionID: String?,
        status: SessionActivityStatus,
        agents: [SessionActivityAgent],
        sessions: [SessionActivityMainSession]? = nil
    ) {
        self.accountID = accountID
        self.state = state
        self.source = source
        self.sessionID = sessionID
        self.status = status
        self.agents = agents
        if let sessions {
            self.sessions = sessions
        } else if let sessionID, state == .available {
            self.sessions = [
                SessionActivityMainSession(
                    threadID: sessionID,
                    source: source,
                    taskName: "Agent",
                    status: status,
                    agents: agents
                ),
            ]
        } else {
            self.sessions = []
        }
    }

    public init(
        accountID: String,
        state: SessionActivitySnapshotState,
        sessions: [SessionActivityMainSession],
        source: SessionActivitySource = .localActivity
    ) {
        let first = sessions.first
        self.init(
            accountID: accountID,
            state: sessions.isEmpty ? (state == .available ? .empty : state) : .available,
            source: source,
            sessionID: first?.threadID,
            status: first?.status ?? .unknown,
            agents: first?.agents ?? [],
            sessions: sessions
        )
    }

    public static func empty(
        accountID: String,
        source: SessionActivitySource = .localActivity
    ) -> SessionActivitySnapshot {
        SessionActivitySnapshot(
            accountID: accountID,
            state: .empty,
            source: source,
            sessionID: nil,
            status: .unknown,
            agents: [],
            sessions: []
        )
    }

    public static func unavailable(accountID: String) -> SessionActivitySnapshot {
        SessionActivitySnapshot(
            accountID: accountID,
            state: .unavailable,
            source: .unavailable,
            sessionID: nil,
            status: .unknown,
            agents: [],
            sessions: []
        )
    }
}

public protocol SessionActivityProvider: Sendable {
    func snapshot(accountID: String, home: URL) async -> SessionActivitySnapshot
}
