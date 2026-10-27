import Foundation
import SQLite3

/// Read-only connection configuration observed by tests without exposing the
/// mutable SQLite handle itself.
public struct SQLiteSessionActivityConnectionState: Equatable, Sendable {
    public let isReadOnly: Bool
    public let isQueryOnly: Bool

    public init(isReadOnly: Bool, isQueryOnly: Bool) {
        self.isReadOnly = isReadOnly
        self.isQueryOnly = isQueryOnly
    }
}

/// Internal test seam for proving that the bounded projection does not
/// materialize an unbounded number of rows.
struct SQLiteSessionActivityProjectionCounts: Equatable, Sendable {
    let threadRows: Int
    let edgeRows: Int
}

/// Reads only the local, last-known session metadata projection. This is not
/// a live app-server status; optional rollout metadata supplies main turn events.
public final class SQLiteSessionActivityProvider: SessionActivityProvider, @unchecked Sendable {
    public static let allowedThreadColumns = [
        "id", "updated_at", "archived", "name", "title", "agent_role", "agent_nickname", "agent_path", "thread_source",
        "model", "reasoning_effort",
    ]
    public static let allowedEdgeColumns = [
        "parent_thread_id", "child_thread_id", "status",
    ]

    public static let threadProjectionSQL = "SELECT id, updated_at, archived, name, title, agent_role, agent_nickname, agent_path, thread_source, model, reasoning_effort FROM threads"
    public static let edgeProjectionSQL = "SELECT parent_thread_id, child_thread_id, status FROM thread_spawn_edges"
    public static let defaultRecentActivityWindow: TimeInterval = 15 * 60
    /// A descendant's open/waiting state is active only when its own metadata
    /// was updated within this explicit window of the snapshot reference date.
    public static let agentActivityFreshnessWindow: TimeInterval = 120

    /// The projection is intentionally small and bounded. A busy local
    /// database may contain many historical threads, but only this many recent
    /// seeds are needed to find the current session candidates.
    public static let maxRecentSeedRows = 256
    /// The relationship walk includes ancestors and descendants of the recent
    /// seeds. Keep the walk bounded as well so a malformed or very large graph
    /// cannot materialize an unbounded number of IDs.
    public static let maxRelatedThreadRows = 512
    /// A thread graph normally has one edge per child, with a little room for
    /// retries and historical duplicate edges.
    public static let maxEdgeRows = 1_024

    private static let relatedIDsCTE = """
    WITH RECURSIVE
    recent_ids(id) AS (
        SELECT id
        FROM threads
        WHERE archived = 0
          AND CASE
                  WHEN ABS(updated_at) > 100000000000.0 THEN updated_at / 1000.0
                  ELSE updated_at
              END >= ?
          AND CASE
                  WHEN ABS(updated_at) > 100000000000.0 THEN updated_at / 1000.0
                  ELSE updated_at
              END <= ?
        ORDER BY updated_at DESC, id ASC
        LIMIT ?
    ),
    related_ids(id) AS (
        SELECT id FROM recent_ids
        UNION
        SELECT edge.parent_thread_id
        FROM thread_spawn_edges AS edge
        JOIN related_ids AS related ON related.id = edge.child_thread_id
        WHERE edge.parent_thread_id IS NOT NULL
        UNION
        SELECT edge.child_thread_id
        FROM thread_spawn_edges AS edge
        JOIN related_ids AS related ON related.id = edge.parent_thread_id
        WHERE edge.child_thread_id IS NOT NULL
        LIMIT ?
    )
    """

    /// 선택 열의 존재 여부를 반영한 제한 스레드 조회문 구성
    private static func boundedThreadProjectionSQL(modelExpression: String, reasoningEffortExpression: String) -> String {
        """
    \(relatedIDsCTE)
    SELECT t.id, t.updated_at, t.archived, t.name, t.title, t.agent_role,
           t.agent_nickname, t.agent_path, t.thread_source, \(modelExpression), \(reasoningEffortExpression)
    FROM threads AS t
    JOIN related_ids AS related ON related.id = t.id
    ORDER BY t.updated_at DESC, t.id ASC
    LIMIT ?
    """
    }

    private static let boundedEdgeProjectionSQL = """
    \(relatedIDsCTE)
    SELECT edge.parent_thread_id, edge.child_thread_id, edge.status
    FROM thread_spawn_edges AS edge
    JOIN related_ids AS parent ON parent.id = edge.parent_thread_id
    JOIN related_ids AS child ON child.id = edge.child_thread_id
    ORDER BY edge.parent_thread_id ASC, edge.child_thread_id ASC,
             COALESCE(edge.status, '') ASC
    LIMIT ?
    """

    private let mainTurnReader = MainSessionTurnReader()
    private let recentActivityWindow: TimeInterval
    private let now: @Sendable () -> Date
    private let connectionProbe: (@Sendable (SQLiteSessionActivityConnectionState) async -> Void)?
    private let projectionProbe: (@Sendable (SQLiteSessionActivityProjectionCounts) async -> Void)?

    public init(
        recentActivityWindow: TimeInterval = SQLiteSessionActivityProvider.defaultRecentActivityWindow,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.recentActivityWindow = max(0, recentActivityWindow)
        self.now = now
        self.connectionProbe = nil
        self.projectionProbe = nil
    }

    // Internal test-only seam. It reports immutable state derived from the
    // provider's actual connection, never the mutable SQLite handle.
    init(
        recentActivityWindow: TimeInterval = SQLiteSessionActivityProvider.defaultRecentActivityWindow,
        now: @escaping @Sendable () -> Date = { Date() },
        connectionProbe: @escaping @Sendable (SQLiteSessionActivityConnectionState) async -> Void,
        projectionProbe: (@Sendable (SQLiteSessionActivityProjectionCounts) async -> Void)? = nil
    ) {
        self.recentActivityWindow = max(0, recentActivityWindow)
        self.now = now
        self.connectionProbe = connectionProbe
        self.projectionProbe = projectionProbe
    }

    public func snapshot(accountID: String, home: URL) async -> SessionActivitySnapshot {
        let databaseURL = home.standardizedFileURL.appendingPathComponent("state_5.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return .unavailable(accountID: accountID)
        }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return .unavailable(accountID: accountID)
        }
        defer { sqlite3_close(database) }

        guard sqlite3_busy_timeout(database, 0) == SQLITE_OK,
              sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK,
              let connectionState = connectionState(database),
              connectionState.isReadOnly,
              connectionState.isQueryOnly else {
            return .unavailable(accountID: accountID)
        }
        await connectionProbe?(connectionState)
        let referenceDate = now()
        guard let projection = readConsistentProjection(database, referenceDate: referenceDate) else {
            return .unavailable(accountID: accountID)
        }
        await projectionProbe?(SQLiteSessionActivityProjectionCounts(
            threadRows: projection.threads.count,
            edgeRows: projection.edges.count
        ))

        let snapshot = buildSnapshot(
            accountID: accountID,
            threads: projection.threads,
            edges: projection.edges,
            referenceDate: referenceDate
        )
        let paths = mainTurnPaths(database, sessionIDs: Array(snapshot.sessions.prefix(16).map(\.threadID)))
        var sessions: [SessionActivityMainSession] = []
        for session in snapshot.sessions {
            guard let path = paths[session.threadID],
                  let turn = await mainTurnReader.state(home: home, path: path) else {
                sessions.append(session)
                continue
            }
            let age = referenceDate.timeIntervalSince(turn.occurredAt)
            if turn.status != .working && (age < 0 || age > Self.agentActivityFreshnessWindow) {
                sessions.append(session)
                continue
            }
            sessions.append(SessionActivityMainSession(
                threadID: session.threadID, source: session.source, taskName: session.taskName,
                // 시작 이벤트가 오래 남아도 기존 메타데이터의 활동 만료 기준 유지
                status: turn.status == .working ? session.status : turn.status,
                agents: session.agents, isActive: session.isActive,
                lastActivityAt: session.lastActivityAt, turnID: turn.turnID, turnEventAt: turn.occurredAt,
                model: session.model, reasoningEffort: session.reasoningEffort
            ))
        }
        return SessionActivitySnapshot(accountID: accountID, state: snapshot.state,
            sessions: SessionActivityMainSession.ordered(sessions), source: snapshot.source)
    }

    /// 선택된 메인 세션 최대 16개의 로그 경로만 추가 조회, 구형 DB는 기존 상태 유지
    private func mainTurnPaths(_ database: OpaquePointer, sessionIDs: [String]) -> [String: String] {
        guard !sessionIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ",")
        let sql = "SELECT id, rollout_path FROM threads WHERE id IN (\(placeholders)) LIMIT 16"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [:] }
        defer { sqlite3_finalize(statement) }
        for (index, id) in sessionIDs.enumerated() {
            let result = id.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard result == SQLITE_OK else { return [:] }
        }
        var paths: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, index: 0), let path = text(statement, index: 1) else { continue }
            paths[id] = path
        }
        return paths
    }

    private func connectionState(_ database: OpaquePointer) -> SQLiteSessionActivityConnectionState? {
        let isReadOnly = sqlite3_db_readonly(database, nil) == 1
        guard let isQueryOnly = queryOnlyValue(database) else { return nil }
        return SQLiteSessionActivityConnectionState(
            isReadOnly: isReadOnly,
            isQueryOnly: isQueryOnly
        )
    }

    private func queryOnlyValue(_ database: OpaquePointer) -> Bool? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA query_only", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int(statement, 0) != 0
    }

    private func readConsistentProjection(
        _ database: OpaquePointer,
        referenceDate: Date
    ) -> (threads: [ThreadRow], edges: [EdgeRow])? {
        guard sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK else {
            return nil
        }
        // A read transaction is deliberately rolled back on success and on
        // every read failure; no metadata mutation is ever committed.
        defer { _ = sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }

        let upperBound = referenceDate.timeIntervalSince1970
        let lowerBound = upperBound - recentActivityWindow
        guard let threads = readThreads(
                database,
                lowerBound: lowerBound,
                upperBound: upperBound
            ),
            let edges = readEdges(
                database,
                lowerBound: lowerBound,
                upperBound: upperBound
            ) else {
            return nil
        }
        return (threads: threads, edges: edges)
    }

    private func readThreads(
        _ database: OpaquePointer,
        lowerBound: TimeInterval,
        upperBound: TimeInterval
    ) -> [ThreadRow]? {
        let availableColumns = availableThreadColumns(database)
        return readRows(
            database,
            sql: Self.boundedThreadProjectionSQL(
                modelExpression: availableColumns.contains("model") ? "t.model" : "NULL",
                reasoningEffortExpression: availableColumns.contains("reasoning_effort") ? "t.reasoning_effort" : "NULL"
            ),
            bind: { statement in
                self.bindActivityBounds(
                    statement,
                    lowerBound: lowerBound,
                    upperBound: upperBound,
                    resultLimit: Self.maxRelatedThreadRows
                )
            }
        ) { statement in
            guard let id = text(statement, index: 0) else { return nil }
            return ThreadRow(
                id: id,
                updatedAt: timestamp(statement, index: 1),
                archived: sqlite3_column_int(statement, 2) != 0,
                name: text(statement, index: 3),
                title: text(statement, index: 4),
                role: text(statement, index: 5),
                nickname: text(statement, index: 6),
                agentPath: text(statement, index: 7),
                source: text(statement, index: 8),
                model: text(statement, index: 9),
                reasoningEffort: text(statement, index: 10)
            )
        }
    }

    /// 구형 SQLite threads 스키마의 선택 열 집합 조회
    private func availableThreadColumns(_ database: OpaquePointer) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(threads)", -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let column = text(statement, index: 1) { columns.insert(column) }
        }
        return columns
    }

    private func readEdges(
        _ database: OpaquePointer,
        lowerBound: TimeInterval,
        upperBound: TimeInterval
    ) -> [EdgeRow]? {
        readRows(
            database,
            sql: Self.boundedEdgeProjectionSQL,
            bind: { statement in
                self.bindActivityBounds(
                    statement,
                    lowerBound: lowerBound,
                    upperBound: upperBound,
                    resultLimit: Self.maxEdgeRows
                )
            }
        ) { statement in
            guard let parentID = text(statement, index: 0),
                  let childID = text(statement, index: 1) else { return nil }
            return EdgeRow(
                parentID: parentID,
                childID: childID,
                rawStatus: text(statement, index: 2)
            )
        }
    }

    private func readRows<T>(
        _ database: OpaquePointer,
        sql: String,
        bind: ((OpaquePointer) -> Bool)? = nil,
        makeRow: (OpaquePointer) -> T?
    ) -> [T]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        if let bind, !bind(statement) { return nil }

        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let row = makeRow(statement) else { return nil }
                rows.append(row)
            case SQLITE_DONE:
                return rows
            default:
                return nil
            }
        }
    }

    /// 단일 인접 목록을 이용한 세션 그래프 투영
    private func buildSnapshot(
        accountID: String,
        threads: [ThreadRow],
        edges: [EdgeRow],
        referenceDate: Date
    ) -> SessionActivitySnapshot {
        var threadsByID: [String: ThreadRow] = [:]
        for thread in threads where threadsByID[thread.id] == nil {
            threadsByID[thread.id] = thread
        }

        let orderedEdges = edges.sorted(by: edgeComesBefore)
        var edgesByParent: [String: [EdgeRow]] = [:]
        for edge in orderedEdges {
            edgesByParent[edge.parentID, default: []].append(edge)
        }
        let childIDs = Set(orderedEdges.map(\.childID))
        let roots = threads.filter { !$0.archived && !childIDs.contains($0.id) }
        let candidates = roots.compactMap { root -> RootCandidate? in
            guard let source = SessionActivitySource.normalize(raw: root.source) else {
                // Web/browser, subagent, and future source values are never
                // promoted to a visible main session.
                return nil
            }
            let descendants = descendants(
                of: root.id,
                edgesByParent: edgesByParent,
                threadsByID: threadsByID
            )
            // Edge status can remain open after an interrupted Codex process,
            // so recency of thread metadata—not the status alone—proves that
            // this session still belongs in the live activity projection.
            let latestActivityAt = ([root.updatedAt] + descendants.map { edge in
                threadsByID[edge.childID]?.updatedAt
            })
            .compactMap { $0 }
            .max()
            guard isRecent(latestActivityAt, relativeTo: referenceDate) else { return nil }
            return RootCandidate(
                root: root,
                descendants: descendants,
                latestActivityAt: latestActivityAt,
                source: source
            )
        }
        let selected = candidates.sorted(by: rootComesBefore)

        guard !selected.isEmpty else {
            return .empty(accountID: accountID, source: .localActivity)
        }

        let sessions = SessionActivityMainSession.ordered(selected.map { candidate in
            let agents = candidate.descendants.compactMap { edge -> SessionActivityAgent? in
                guard let thread = threadsByID[edge.childID] else { return nil }
                return SessionActivityAgent(
                    threadID: edge.childID,
                    parentThreadID: edge.parentID,
                    taskName: sanitizedTaskName(
                        name: thread.name,
                        title: thread.title,
                        agentPath: thread.agentPath,
                        fallback: "Agent"
                    ),
                    status: descendantStatus(
                        rawStatus: edge.rawStatus,
                        updatedAt: thread.updatedAt,
                        referenceDate: referenceDate
                    ),
                    displayName: sanitizedDisplayName(
                        nickname: thread.nickname,
                        role: thread.role
                    ),
                    model: thread.model,
                    reasoningEffort: thread.reasoningEffort
                )
            }
            return SessionActivityMainSession(
                threadID: candidate.root.id,
                source: candidate.source,
                taskName: sanitizedTaskName(
                    name: candidate.root.name,
                    title: candidate.root.title,
                    agentPath: nil,
                    fallback: "Codex session"
                ),
                status: mainStatus(
                    rootUpdatedAt: candidate.root.updatedAt,
                    descendantStatuses: agents.map(\.status),
                    referenceDate: referenceDate
                ),
                agents: agents,
                isActive: true,
                lastActivityAt: candidate.latestActivityAt,
                model: candidate.root.model,
                reasoningEffort: candidate.root.reasoningEffort
            )
        })
        let first = sessions[0]

        return SessionActivitySnapshot(
            accountID: accountID,
            state: .available,
            source: .localActivity,
            sessionID: first.threadID,
            status: first.status,
            agents: first.agents,
            sessions: sessions
        )
    }

    private func edgeComesBefore(_ lhs: EdgeRow, _ rhs: EdgeRow) -> Bool {
        if lhs.parentID != rhs.parentID { return lhs.parentID < rhs.parentID }
        if lhs.childID != rhs.childID { return lhs.childID < rhs.childID }
        return (lhs.rawStatus ?? "") < (rhs.rawStatus ?? "")
    }

    private func rootComesBefore(_ lhs: RootCandidate, _ rhs: RootCandidate) -> Bool {
        let lhsDate = lhs.latestActivityAt ?? .distantPast
        let rhsDate = rhs.latestActivityAt ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return lhs.root.id < rhs.root.id
    }

    /// 인접 목록과 인덱스 큐 기반 너비 우선 descendant 탐색
    private func descendants(
        of rootID: String,
        edgesByParent: [String: [EdgeRow]],
        threadsByID: [String: ThreadRow]
    ) -> [EdgeRow] {
        var queue = [rootID]
        var queueIndex = 0
        var visited: Set<String> = [rootID]
        var result: [EdgeRow] = []

        while queueIndex < queue.count {
            let parent = queue[queueIndex]
            queueIndex += 1
            guard let outgoingEdges = edgesByParent[parent] else { continue }
            for edge in outgoingEdges {
                guard let child = threadsByID[edge.childID],
                      !child.archived,
                      !visited.contains(edge.childID) else { continue }
                visited.insert(edge.childID)
                result.append(edge)
                queue.append(edge.childID)
            }
        }
        return result
    }

    private func isRecent(_ date: Date?, relativeTo referenceDate: Date) -> Bool {
        guard let date else { return false }
        let age = referenceDate.timeIntervalSince(date)
        return age >= 0 && age <= recentActivityWindow
    }

    private func bindActivityBounds(
        _ statement: OpaquePointer,
        lowerBound: TimeInterval,
        upperBound: TimeInterval,
        resultLimit: Int
    ) -> Bool {
        sqlite3_bind_double(statement, 1, lowerBound) == SQLITE_OK
            && sqlite3_bind_double(statement, 2, upperBound) == SQLITE_OK
            && sqlite3_bind_int(statement, 3, Int32(Self.maxRecentSeedRows)) == SQLITE_OK
            && sqlite3_bind_int(statement, 4, Int32(Self.maxRelatedThreadRows)) == SQLITE_OK
            && sqlite3_bind_int(statement, 5, Int32(resultLimit)) == SQLITE_OK
    }

    private func mainStatus(
        rootUpdatedAt: Date?,
        descendantStatuses: [SessionActivityStatus],
        referenceDate: Date
    ) -> SessionActivityStatus {
        if descendantStatuses.contains(.working) { return .working }
        if isFreshAgentActivity(rootUpdatedAt, relativeTo: referenceDate) { return .working }
        if descendantStatuses.contains(.waiting) { return .waiting }
        return .inactive
    }

    private func descendantStatus(
        rawStatus: String?,
        updatedAt: Date?,
        referenceDate: Date
    ) -> SessionActivityStatus {
        let mapped = SessionActivityStatus.map(raw: rawStatus)
        switch mapped {
        case .working, .waiting:
            return isFreshAgentActivity(updatedAt, relativeTo: referenceDate)
                ? mapped
                : .inactive
        case .inactive, .completed, .stopped, .error, .unknown:
            return mapped
        }
    }

    private func isFreshAgentActivity(_ date: Date?, relativeTo referenceDate: Date) -> Bool {
        guard let date else { return false }
        let age = referenceDate.timeIntervalSince(date)
        return age >= 0 && age <= Self.agentActivityFreshnessWindow
    }

    private func sanitizedTaskName(
        name: String?,
        title: String?,
        agentPath: String?,
        fallback: String
    ) -> String {
        for candidate in [name, title] {
            if let normalized = SessionActivityMetadataSanitizer.text(candidate) {
                return normalized
            }
        }
        if let normalized = SessionActivityMetadataSanitizer.agentPathComponent(agentPath) {
            return normalized
        }
        return fallback
    }

    private func sanitizedDisplayName(nickname: String?, role: String?) -> String {
        for candidate in [nickname, role] {
            if let normalized = SessionActivityMetadataSanitizer.text(candidate) {
                return normalized
            }
        }
        return "Agent"
    }

    private func text(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func timestamp(_ statement: OpaquePointer, index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        var seconds = sqlite3_column_double(statement, index)
        if abs(seconds) > 100_000_000_000 {
            seconds /= 1_000
        }
        return Date(timeIntervalSince1970: seconds)
    }
}

private struct ThreadRow {
    let id: String
    let updatedAt: Date?
    let archived: Bool
    let name: String?
    let title: String?
    let role: String?
    let nickname: String?
    let agentPath: String?
    let source: String?
    let model: String?
    let reasoningEffort: String?
}

private struct RootCandidate {
    let root: ThreadRow
    let descendants: [EdgeRow]
    let latestActivityAt: Date?
    let source: SessionActivitySource
}

private struct EdgeRow {
    let parentID: String
    let childID: String
    let rawStatus: String?
}
