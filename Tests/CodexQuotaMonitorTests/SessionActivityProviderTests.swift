import Foundation
import SQLite3
import XCTest
@testable import CodexQuotaMonitorKit

final class SessionActivityProviderTests: XCTestCase {
    func testSupportedLocalSourcesReturnEveryRootAndExcludeWebAndUnknown() async throws {
        let home = try makeTemporaryHome()
        try makeDatabase(
            at: home,
            threads: [
                .init(id: "cli-root", updatedAt: 1_999_910, archived: false, name: "CLI task", role: nil, nickname: nil, source: "cli"),
                .init(id: "app-root", updatedAt: 1_999_920, archived: false, name: "App task", role: nil, nickname: nil, source: "app"),
                .init(id: "web-root", updatedAt: 1_999_930, archived: false, name: "Web task", role: nil, nickname: nil, source: "web"),
                .init(id: "unknown-root", updatedAt: 1_999_940, archived: false, name: "Unknown task", role: nil, nickname: nil, source: "future"),
            ],
            edges: []
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let snapshot = await provider.snapshot(accountID: "C1", home: home)

        XCTAssertEqual(snapshot.sessions.map(\.threadID), ["app-root", "cli-root"])
        XCTAssertEqual(snapshot.sessions.map(\.source), [.codexApp, .cli])
        XCTAssertEqual(snapshot.sessions.map(\.taskName), ["App task", "CLI task"])
    }

    func testDisplayTitlesFallbackFromNameToTitleAndStayAttachedToTheirRoots() async throws {
        let home = try makeTemporaryHome()
        try makeDatabase(
            at: home,
            threads: [
                .init(
                    id: "root-a",
                    updatedAt: 1_999_900,
                    archived: false,
                    name: nil,
                    title: "  Root A\nfrom title  ",
                    role: nil,
                    nickname: nil
                ),
                .init(
                    id: "child-a",
                    updatedAt: 1_999_901,
                    archived: false,
                    name: "/private/should-not-display",
                    title: "  Agent A\tfrom title  ",
                    role: "Worker A",
                    nickname: nil,
                    source: "subagent"
                ),
                .init(
                    id: "root-b",
                    updatedAt: 1_999_920,
                    archived: false,
                    name: "Root B from name",
                    title: "Root B from title (must lose to name)",
                    role: nil,
                    nickname: nil
                ),
                .init(
                    id: "child-b",
                    updatedAt: 1_999_921,
                    archived: false,
                    name: "Agent B from name",
                    title: "Agent B from title (must lose to name)",
                    role: "Worker B",
                    nickname: "Nickname B",
                    source: "subagent"
                ),
            ],
            edges: [
                .init(parent: "root-a", child: "child-a", status: "waiting"),
                .init(parent: "root-b", child: "child-b", status: "completed"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let snapshot = await provider.snapshot(accountID: "C1", home: home)
        let sessionsByID = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.threadID, $0) })

        XCTAssertEqual(sessionsByID["root-a"]?.taskName, "Root A from title")
        XCTAssertEqual(sessionsByID["root-a"]?.agents.map(\.taskName), ["Agent A from title"])
        XCTAssertEqual(sessionsByID["root-a"]?.agents.map(\.status), [.waiting])
        XCTAssertEqual(sessionsByID["root-b"]?.taskName, "Root B from name")
        XCTAssertEqual(sessionsByID["root-b"]?.agents.map(\.taskName), ["Agent B from name"])
        XCTAssertEqual(sessionsByID["root-b"]?.agents.map(\.status), [.completed])
    }

    func testAgentIdentityUsesNicknameThenRoleAndKeepsTaskNameSeparate() async throws {
        let home = try makeTemporaryHome()
        try makeDatabase(
            at: home,
            threads: [
                .init(id: "root", updatedAt: 1_999_900, archived: false, name: "Main task", role: nil, nickname: nil),
                .init(id: "named", updatedAt: 1_999_901, archived: false, name: "Fix settings", role: "Worker", nickname: "Nora", source: "subagent"),
                .init(id: "role-only", updatedAt: 1_999_902, archived: false, name: nil, role: "Reviewer", nickname: nil, source: "subagent"),
                .init(id: "generic", updatedAt: 1_999_903, archived: false, name: nil, role: nil, nickname: nil, source: "subagent"),
            ],
            edges: [
                .init(parent: "root", child: "named", status: "running"),
                .init(parent: "root", child: "role-only", status: "completed"),
                .init(parent: "root", child: "generic", status: "error"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let snapshot = await provider.snapshot(accountID: "C1", home: home)
        let agents = try XCTUnwrap(snapshot.sessions.first?.agents)

        XCTAssertEqual(agents.map(\.displayName), ["Agent", "Nora", "Reviewer"])
        XCTAssertEqual(agents.map(\.taskName), ["Agent", "Fix settings", "Agent"])
        XCTAssertEqual(snapshot.sessions.first?.taskName, "Main task")
    }

    /// 메인·하위 세션의 서로 다른 모델과 추론 등급 반영 검증
    func testModelMetadataProjectsIndependentlyForMainAndAgent() async throws {
        let home = try makeTemporaryHome()
        try makeDatabase(at: home, threads: [
            .init(id: "root", updatedAt: 1_999_900, archived: false, name: "Main", role: nil, nickname: nil,
                model: "gpt-6.1-sol", reasoningEffort: "medium"),
            .init(id: "agent", updatedAt: 1_999_901, archived: false, name: "Review", role: "Reviewer", nickname: "R",
                source: "subagent", model: "gpt-6-luna", reasoningEffort: "high"),
        ], edges: [.init(parent: "root", child: "agent", status: "running")])
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let snapshot = await provider.snapshot(accountID: "C1", home: home)
        let session = try XCTUnwrap(snapshot.sessions.first)
        let agent = try XCTUnwrap(session.agents.first)
        XCTAssertEqual(session.model, "GPT-6.1-Sol")
        XCTAssertEqual(session.reasoningEffort, "medium")
        XCTAssertEqual(agent.model, "GPT-6-Luna")
        XCTAssertEqual(agent.reasoningEffort, "high")
    }

    /// 구형 threads 스키마와 null·불완전 메타데이터의 안전한 기본 처리 검증
    func testOldSchemaAndInvalidModelMetadataRemainOptional() async throws {
        let oldHome = try makeTemporaryHome()
        try makeRawDatabase(at: oldHome, statements: [
            "CREATE TABLE threads (id TEXT PRIMARY KEY, updated_at REAL, archived INTEGER, name TEXT, title TEXT, agent_role TEXT, agent_nickname TEXT, agent_path TEXT, thread_source TEXT)",
            "CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT, status TEXT)",
            "INSERT INTO threads VALUES ('old-root', 1999900, 0, 'Old', NULL, NULL, NULL, NULL, 'cli')",
        ])
        defer { try? FileManager.default.removeItem(at: oldHome) }
        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let oldSnapshot = await provider.snapshot(accountID: "C1", home: oldHome)
        XCTAssertNil(oldSnapshot.sessions.first?.model)
        XCTAssertNil(oldSnapshot.sessions.first?.reasoningEffort)

        for schema in ["model TEXT", "reasoning_effort TEXT"] {
            let partialHome = try makeTemporaryHome()
            let field = schema.hasPrefix("model") ? "model" : "reasoning_effort"
            let value = field == "model" ? "'gpt-6.1-sol'" : "'high'"
            try makeRawDatabase(at: partialHome, statements: [
                "CREATE TABLE threads (id TEXT PRIMARY KEY, updated_at REAL, archived INTEGER, name TEXT, title TEXT, agent_role TEXT, agent_nickname TEXT, agent_path TEXT, thread_source TEXT, \(schema))",
                "CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT, status TEXT)",
                "INSERT INTO threads VALUES ('partial', 1999900, 0, 'Partial', NULL, NULL, NULL, NULL, 'cli', \(value))",
            ])
            let partial = await provider.snapshot(accountID: "C1", home: partialHome).sessions.first
            XCTAssertEqual(partial?.model, field == "model" ? "GPT-6.1-Sol" : nil)
            XCTAssertEqual(partial?.reasoningEffort, field == "reasoning_effort" ? "high" : nil)
            try? FileManager.default.removeItem(at: partialHome)
        }

        let currentHome = try makeTemporaryHome()
        try makeDatabase(at: currentHome, threads: [
            .init(id: "invalid-root", updatedAt: 1_999_900, archived: false, name: "Invalid", role: nil, nickname: nil,
                model: "gpt-6.1-sol/secret", reasoningEffort: "secret"),
        ], edges: [])
        defer { try? FileManager.default.removeItem(at: currentHome) }
        let invalidSnapshot = await provider.snapshot(accountID: "C2", home: currentHome)
        XCTAssertNil(invalidSnapshot.sessions.first?.model)
        XCTAssertNil(invalidSnapshot.sessions.first?.reasoningEffort)
    }

    /// 새 snapshot에서 변경된 모델과 계정별 DB 경로 분리 검증
    func testModelRefreshAndAccountHomesRemainIsolated() async throws {
        let firstHome = try makeTemporaryHome()
        let secondHome = try makeTemporaryHome()
        try makeDatabase(at: firstHome, threads: [
            .init(id: "first", updatedAt: 1_999_900, archived: false, name: "First", role: nil, nickname: nil,
                model: "gpt-6-sol", reasoningEffort: "low"),
        ], edges: [])
        try makeDatabase(at: secondHome, threads: [
            .init(id: "second", updatedAt: 1_999_900, archived: false, name: "Second", role: nil, nickname: nil,
                model: "gpt-6-astra", reasoningEffort: "high"),
        ], edges: [])
        defer {
            try? FileManager.default.removeItem(at: firstHome)
            try? FileManager.default.removeItem(at: secondHome)
        }
        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let first = await provider.snapshot(accountID: "C1", home: firstHome)
        let second = await provider.snapshot(accountID: "C2", home: secondHome)
        XCTAssertEqual(first.sessions.first?.model, "GPT-6-Sol")
        XCTAssertEqual(second.sessions.first?.model, "GPT-6-Astra")
        XCTAssertEqual(first.sessions.first?.reasoningEffort, "low")
        XCTAssertEqual(second.sessions.first?.reasoningEffort, "high")

        try execute("UPDATE threads SET model='gpt-6.1-sol', reasoning_effort='medium' WHERE id='first'", at: firstHome)
        let refreshed = await provider.snapshot(accountID: "C1", home: firstHome)
        XCTAssertEqual(refreshed.sessions.first?.model, "GPT-6.1-Sol")
        XCTAssertEqual(refreshed.sessions.first?.reasoningEffort, "medium")
        let secondAfterRefresh = await provider.snapshot(accountID: "C2", home: secondHome)
        XCTAssertEqual(secondAfterRefresh.sessions.first?.model, "GPT-6-Astra")
    }

    func testThreadSourceNormalizationRecognizesOnlyLocalCliAndAppValues() {
        XCTAssertEqual(SessionActivitySource.normalize(raw: "cli"), .cli)
        XCTAssertEqual(SessionActivitySource.normalize(raw: "user"), .cli)
        XCTAssertEqual(SessionActivitySource.normalize(raw: "app"), .codexApp)
        XCTAssertEqual(SessionActivitySource.normalize(raw: "codex_app"), .codexApp)
        XCTAssertNil(SessionActivitySource.normalize(raw: "web"))
        XCTAssertNil(SessionActivitySource.normalize(raw: "browser"))
        XCTAssertNil(SessionActivitySource.normalize(raw: "subagent"))
        XCTAssertNil(SessionActivitySource.normalize(raw: "future"))
    }

    /// 세션 제목 뒤 모델·추론 등급 표기와 안전 필터 검증
    @MainActor
    func testModelSuffixFormattingRejectsUnsafeOrUnknownMetadata() {
        XCTAssertEqual(CLIActivitySection.modelMetadataText(model: "gpt-6.1-sol", reasoningEffort: "MEDIUM"),
            "GPT-6.1-Sol medium")
        XCTAssertNil(CLIActivitySection.modelMetadataText(model: nil, reasoningEffort: nil))
        XCTAssertEqual(CLIActivitySection.modelMetadataText(model: "bad/model", reasoningEffort: "ultra"), "ultra")
        XCTAssertEqual(CLIActivitySection.modelMetadataText(model: nil, reasoningEffort: "MAX"), "max")
        XCTAssertEqual(CLIActivitySection.modelMetadataText(model: "gpt-6.1-sol", reasoningEffort: "secret"), "GPT-6.1-Sol")
        XCTAssertNil(CLIActivitySection.modelMetadataText(model: String(repeating: "a", count: 65), reasoningEffort: nil))
    }

    func testNewestRecentRootWinsAndIncludesAllDescendants() async throws {
        let home = try makeTemporaryHome()
        try makeDatabase(
            at: home,
            threads: [
                .init(id: "root-old", updatedAt: 1_999_900, archived: false, role: nil, nickname: nil),
                .init(id: "root-new", updatedAt: 1_999_950, archived: false, role: nil, nickname: nil),
                .init(id: "archived", updatedAt: 1_999_999, archived: true, role: nil, nickname: nil),
                .init(id: "worker", updatedAt: 1_999_960, archived: false, role: "Worker", nickname: "w"),
                .init(id: "reviewer", updatedAt: 1_999_970, archived: false, role: nil, nickname: "Review Agent"),
            ],
            edges: [
                .init(parent: "root-new", child: "worker", status: "running"),
                .init(parent: "worker", child: "reviewer", status: "completed"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let snapshot = await provider.snapshot(accountID: "C1", home: home)

        XCTAssertEqual(snapshot.state, .available)
        XCTAssertEqual(snapshot.source, .localActivity)
        XCTAssertEqual(snapshot.sessionID, "root-new")
        XCTAssertEqual(snapshot.status, .working)
        XCTAssertEqual(snapshot.agents.map(\.threadID), ["worker", "reviewer"])
        XCTAssertEqual(snapshot.agents.map(\.status), [.working, .completed])
    }

    func testStaleOpenDescendantExpiresWhenAllThreadActivityIsOld() async throws {
        let home = try makeTemporaryHome()
        try makeDatabase(
            at: home,
            threads: [
                .init(id: "stale-root", updatedAt: 1_000, archived: false, role: nil, nickname: nil),
                .init(id: "active-child", updatedAt: 1_000, archived: false, role: "Worker", nickname: nil),
            ],
            edges: [
                .init(parent: "stale-root", child: "active-child", status: "pending_init"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let snapshot = await provider.snapshot(accountID: "C2", home: home)

        XCTAssertEqual(snapshot.state, .empty)
        XCTAssertEqual(snapshot.source, .localActivity)
        XCTAssertNil(snapshot.sessionID)
        XCTAssertEqual(snapshot.status, .unknown)
        XCTAssertTrue(snapshot.agents.isEmpty)
    }

    func testRecentOpenDescendantKeepsStaleRootActive() async throws {
        let home = try makeTemporaryHome()
        try makeDatabase(
            at: home,
            threads: [
                .init(id: "stale-root", updatedAt: 1_000, archived: false, role: nil, nickname: nil),
                .init(id: "active-child", updatedAt: 1_999_950, archived: false, role: "Worker", nickname: nil),
            ],
            edges: [
                .init(parent: "stale-root", child: "active-child", status: "running"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let snapshot = await provider.snapshot(accountID: "C2", home: home)

        XCTAssertEqual(snapshot.state, .available)
        XCTAssertEqual(snapshot.source, .localActivity)
        XCTAssertEqual(snapshot.sessionID, "stale-root")
        XCTAssertEqual(snapshot.status, .working)
        XCTAssertEqual(snapshot.agents.map(\.status), [.working])
    }

    func testFreshOpenDescendantIsWorkingWithinExplicitAgentFreshnessWindow() async throws {
        let home = try makeTemporaryHome()
        try makeDatabase(
            at: home,
            threads: [
                .init(id: "root", updatedAt: 1_999_800, archived: false, role: nil, nickname: nil),
                .init(id: "fresh-child", updatedAt: 1_999_900, archived: false, role: nil, nickname: nil),
            ],
            edges: [
                .init(parent: "root", child: "fresh-child", status: "running"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let snapshot = await provider.snapshot(accountID: "C1", home: home)

        XCTAssertEqual(snapshot.agents.map(\.status), [.working])
        XCTAssertEqual(snapshot.status, .working)
    }

    func testStaleOpenDescendantBecomesInactiveWhileFreshRootRemainsSelected() async throws {
        let home = try makeTemporaryHome()
        try makeDatabase(
            at: home,
            threads: [
                .init(id: "root", updatedAt: 1_999_900, archived: false, role: nil, nickname: nil),
                .init(id: "stale-child", updatedAt: 1_999_850, archived: false, role: nil, nickname: nil),
            ],
            edges: [
                .init(parent: "root", child: "stale-child", status: "running"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let snapshot = await provider.snapshot(accountID: "C1", home: home)

        XCTAssertEqual(snapshot.sessionID, "root")
        XCTAssertEqual(snapshot.agents.map { $0.status.rawValue }, ["inactive"])
        XCTAssertEqual(snapshot.status, .working)
    }

    func testFreshRootAndStaleOpenChildKeepMainWorking() async throws {
        let home = try makeTemporaryHome()
        try makeDatabase(
            at: home,
            threads: [
                .init(id: "fresh-root", updatedAt: 1_999_950, archived: false, role: nil, nickname: nil),
                .init(id: "stale-child", updatedAt: 1_999_850, archived: false, role: "Worker", nickname: nil),
            ],
            edges: [
                .init(parent: "fresh-root", child: "stale-child", status: "running"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let snapshot = await provider.snapshot(accountID: "C1", home: home)

        XCTAssertEqual(snapshot.sessions.first?.status, .working)
        XCTAssertEqual(snapshot.sessions.first?.agents.map(\.status), [.inactive])
    }

    func testStaleRootWithOnlyInactiveOrCompletedChildrenIsInactive() async throws {
        let home = try makeTemporaryHome()
        try makeDatabase(
            at: home,
            threads: [
                .init(id: "stale-root", updatedAt: 1_000, archived: false, role: nil, nickname: nil),
                .init(id: "inactive-child", updatedAt: 1_999_850, archived: false, role: "Worker", nickname: nil),
                .init(id: "completed-child", updatedAt: 1_999_999, archived: false, role: "Reviewer", nickname: nil),
            ],
            edges: [
                .init(parent: "stale-root", child: "inactive-child", status: "running"),
                .init(parent: "stale-root", child: "completed-child", status: "completed"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let snapshot = await provider.snapshot(accountID: "C1", home: home)

        XCTAssertEqual(snapshot.sessions.first?.status, .inactive)
        XCTAssertEqual(snapshot.sessions.first?.agents.map(\.status), [.completed, .inactive])
    }

    func testFreshRootWithoutFreshChildrenIsWorking() async throws {
        let home = try makeTemporaryHome()
        try makeDatabase(
            at: home,
            threads: [
                .init(id: "fresh-root", updatedAt: 1_999_950, archived: false, role: nil, nickname: nil),
            ],
            edges: []
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let snapshot = await provider.snapshot(accountID: "C1", home: home)

        XCTAssertEqual(snapshot.sessions.first?.status, .working)
        XCTAssertTrue(snapshot.sessions.first?.agents.isEmpty == true)
    }

    func testExplicitCompletedDescendantRemainsCompletedEvenWhenFresh() async throws {
        let home = try makeTemporaryHome()
        try makeDatabase(
            at: home,
            threads: [
                .init(id: "root", updatedAt: 1_999_900, archived: false, role: nil, nickname: nil),
                .init(id: "completed-child", updatedAt: 1_999_999, archived: false, role: nil, nickname: nil),
            ],
            edges: [
                .init(parent: "root", child: "completed-child", status: "completed"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let snapshot = await provider.snapshot(accountID: "C1", home: home)

        XCTAssertEqual(snapshot.agents.map(\.status), [.completed])
        XCTAssertEqual(snapshot.status, .working)
    }

    func testMissingOrUnrecognizedDescendantStatusRemainsUnknownWhileFreshRootIsWorking() async throws {
        let home = try makeTemporaryHome()
        try makeDatabase(
            at: home,
            threads: [
                .init(id: "root", updatedAt: 1_999_900, archived: false, role: nil, nickname: nil),
                .init(id: "missing-child", updatedAt: 1_999_999, archived: false, role: nil, nickname: nil),
                .init(id: "future-child", updatedAt: 1_999_999, archived: false, role: nil, nickname: nil),
            ],
            edges: [
                .init(parent: "root", child: "missing-child", status: nil),
                .init(parent: "root", child: "future-child", status: "future_status"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let snapshot = await provider.snapshot(accountID: "C1", home: home)

        XCTAssertEqual(snapshot.agents.map(\.status), [.unknown, .unknown])
        XCTAssertEqual(snapshot.status, .working)
    }

    func testAgentTaskTitleFallsBackToSafeDerivedPathComponentWithoutExposingRawPath() async throws {
        let home = try makeTemporaryHome()
        let rawPath = "/root/local_activity_impl"
        try makeDatabase(
            at: home,
            threads: [
                .init(id: "root", updatedAt: 1_999_900, archived: false, role: nil, nickname: nil),
                .init(
                    id: "path-child",
                    updatedAt: 1_999_999,
                    archived: false,
                    name: nil,
                    title: nil,
                    role: "Worker",
                    nickname: "Nora",
                    agentPath: rawPath
                ),
            ],
            edges: [
                .init(parent: "root", child: "path-child", status: "running"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let snapshot = await provider.snapshot(accountID: "C1", home: home)
        let agent = try XCTUnwrap(snapshot.agents.first)

        XCTAssertEqual(agent.displayName, "Nora")
        XCTAssertEqual(agent.taskName, "local activity impl")
        XCTAssertFalse(agent.taskName.contains(rawPath))
        XCTAssertFalse(String(describing: snapshot).contains(rawPath))
    }

    func testLargeHistoricalFixtureUsesBoundedProjectionAndKeepsRecentDescendants() async throws {
        let home = try makeTemporaryHome()
        let historicalThreads = (0..<2_000).map { index in
            ThreadFixture(
                id: "historical-\(index)",
                updatedAt: Double(index),
                archived: false,
                role: nil,
                nickname: nil
            )
        }
        let historicalEdges = (0..<2_000).map { index in
            EdgeFixture(
                parent: "historical-\(index)",
                child: "historical-child-\(index)",
                status: "completed"
            )
        }
        try makeDatabase(
            at: home,
            threads: historicalThreads + [
                .init(id: "root-live", updatedAt: 1_999_950, archived: false, role: nil, nickname: nil),
                .init(id: "recent-child", updatedAt: 1_999_960, archived: false, role: "Worker", nickname: nil),
                .init(id: "old-descendant", updatedAt: 1_000, archived: false, role: "Reviewer", nickname: nil),
            ],
            edges: historicalEdges + [
                .init(parent: "root-live", child: "recent-child", status: "running"),
                .init(parent: "recent-child", child: "old-descendant", status: "completed"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let recorder = ProjectionCountRecorder()
        let provider = SQLiteSessionActivityProvider(
            now: { Date(timeIntervalSince1970: 2_000_000) },
            connectionProbe: { _ in },
            projectionProbe: { counts in
                await recorder.record(counts)
            }
        )
        let snapshot = await provider.snapshot(accountID: "C1", home: home)
        let counts = await recorder.value

        XCTAssertEqual(snapshot.sessionID, "root-live")
        XCTAssertEqual(snapshot.agents.map(\.threadID), ["recent-child", "old-descendant"])
        XCTAssertNotNil(counts)
        XCTAssertLessThanOrEqual(counts?.threadRows ?? .max, SQLiteSessionActivityProvider.maxRelatedThreadRows)
        XCTAssertLessThanOrEqual(counts?.edgeRows ?? .max, SQLiteSessionActivityProvider.maxEdgeRows)
    }

    func testStatusMappingIsTotalAndPreservesUnknownAsUnknown() {
        let expected: [String: SessionActivityStatus] = [
            "open": .working,
            "running": .working,
            "pending": .working,
            "pending_init": .working,
            "waiting": .waiting,
            "waiting_on_user_input": .waiting,
            "completed": .completed,
            "closed": .completed,
            "shutdown": .completed,
            "interrupted": .stopped,
            "stopped": .stopped,
            "error": .error,
            "errored": .error,
        ]

        for (raw, status) in expected {
            XCTAssertEqual(SessionActivityStatus.map(raw: raw), status, raw)
        }
        XCTAssertEqual(SessionActivityStatus.map(raw: "future_status"), .unknown)
        XCTAssertEqual(SessionActivityStatus.map(raw: nil), .unknown)
    }

    func testAccountHomesAreIsolated() async throws {
        let firstHome = try makeTemporaryHome()
        let secondHome = try makeTemporaryHome()
        try makeDatabase(
            at: firstHome,
            threads: [.init(id: "C1-root", updatedAt: 1_999_900, archived: false, role: nil, nickname: nil)],
            edges: []
        )
        try makeDatabase(
            at: secondHome,
            threads: [.init(id: "C2-root", updatedAt: 1_999_900, archived: false, role: nil, nickname: nil)],
            edges: []
        )
        defer {
            try? FileManager.default.removeItem(at: firstHome)
            try? FileManager.default.removeItem(at: secondHome)
        }

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let first = await provider.snapshot(accountID: "C1", home: firstHome)
        let second = await provider.snapshot(accountID: "C2", home: secondHome)

        XCTAssertEqual(first.sessionID, "C1-root")
        XCTAssertEqual(second.sessionID, "C2-root")
        XCTAssertEqual(first.accountID, "C1")
        XCTAssertEqual(second.accountID, "C2")
    }

    func testMissingDatabaseReturnsUnavailableWithoutActivity() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = SQLiteSessionActivityProvider()
        let snapshot = await provider.snapshot(accountID: "C3", home: home)

        XCTAssertEqual(snapshot.state, .unavailable)
        XCTAssertEqual(snapshot.source, .unavailable)
        XCTAssertNil(snapshot.sessionID)
        XCTAssertTrue(snapshot.agents.isEmpty)
    }

    func testIncompatibleSchemaReturnsUnavailable() async throws {
        let home = try makeTemporaryHome()
        try makeRawDatabase(
            at: home,
            statements: [
                "CREATE TABLE threads (id TEXT PRIMARY KEY)",
                "CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT)",
            ]
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = SQLiteSessionActivityProvider()
        let snapshot = await provider.snapshot(accountID: "C4", home: home)

        XCTAssertEqual(snapshot.state, .unavailable)
        XCTAssertEqual(snapshot.source, .unavailable)
    }

    func testQueryOnlyWriteAttemptIsRejectedAndFixtureRemainsReadable() async throws {
        let home = try makeTemporaryHome()
        try makeDatabase(
            at: home,
            threads: [
                .init(id: "root", updatedAt: 1_999_900, archived: false, role: nil, nickname: nil),
            ],
            edges: []
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let path = home.appendingPathComponent("state_5.sqlite").path
        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil),
            SQLITE_OK
        )
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(database, "INSERT INTO threads (id) VALUES ('must-not-write')", nil, nil, nil),
            SQLITE_READONLY
        )

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let snapshot = await provider.snapshot(accountID: "C1", home: home)
        XCTAssertEqual(snapshot.sessionID, "root")
    }

    func testProviderProbeObservesReadOnlyAndQueryOnlyOnItsActualConnection() async throws {
        let home = try makeTemporaryHome()
        try makeDatabase(
            at: home,
            threads: [
                .init(id: "root", updatedAt: 1_999_900, archived: false, role: nil, nickname: nil),
            ],
            edges: []
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let recorder = ConnectionStateRecorder()
        let provider = SQLiteSessionActivityProvider(
            now: { Date(timeIntervalSince1970: 2_000_000) },
            connectionProbe: { state in
                await recorder.record(state)
            }
        )

        let snapshot = await provider.snapshot(accountID: "C1", home: home)
        let observed = await recorder.value

        XCTAssertEqual(snapshot.sessionID, "root")
        XCTAssertEqual(observed, SQLiteSessionActivityConnectionState(isReadOnly: true, isQueryOnly: true))
    }

    func testLockedDatabaseFailsClosedAtReadTransactionBoundary() async throws {
        let home = try makeTemporaryHome()
        try makeDatabase(
            at: home,
            threads: [
                .init(id: "root", updatedAt: 1_999_900, archived: false, role: nil, nickname: nil),
            ],
            edges: []
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let path = home.appendingPathComponent("state_5.sqlite").path
        var writer: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil),
            SQLITE_OK
        )
        defer {
            sqlite3_exec(writer, "ROLLBACK", nil, nil, nil)
            sqlite3_close(writer)
        }
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let snapshot = await provider.snapshot(accountID: "C1", home: home)

        XCTAssertEqual(snapshot.state, .unavailable)
        XCTAssertEqual(snapshot.source, .unavailable)
    }

    func testAgentLabelUsesRoleThenSafeGenericWithoutNicknameFallback() async throws {
        let home = try makeTemporaryHome()
        try makeDatabase(
            at: home,
            threads: [
                .init(id: "root", updatedAt: 1_999_900, archived: false, role: nil, nickname: nil),
                .init(id: "role-child", updatedAt: 1_999_901, archived: false, role: "  Worker  ", nickname: "nickname"),
                .init(id: "nickname-child", updatedAt: 1_999_902, archived: false, role: " \n", nickname: "Review\nAgent"),
                .init(id: "unknown-child", updatedAt: 1_999_903, archived: false, role: nil, nickname: "  "),
            ],
            edges: [
                .init(parent: "root", child: "role-child", status: "running"),
                .init(parent: "root", child: "nickname-child", status: "running"),
                .init(parent: "root", child: "unknown-child", status: "running"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let snapshot = await provider.snapshot(accountID: "C1", home: home)

        XCTAssertEqual(snapshot.agents.map(\.label), ["Review Agent", "nickname", "Agent"])
    }

    func testExplicitTaskNamePrecedesRoleAndNicknameWithoutExposingAgentPath() async throws {
        let home = try makeTemporaryHome()
        try makeDatabase(
            at: home,
            threads: [
                .init(id: "root", updatedAt: 1_999_900, archived: false, role: nil, nickname: nil),
                .init(
                    id: "named-child",
                    updatedAt: 1_999_901,
                    archived: false,
                    name: "  Settings\nwindow fix  ",
                    role: "Worker",
                    nickname: "Nickname",
                    agentPath: "/private/should-never-be-displayed"
                ),
            ],
            edges: [
                .init(parent: "root", child: "named-child", status: "running"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let snapshot = await provider.snapshot(accountID: "C1", home: home)

        XCTAssertEqual(snapshot.agents.map(\.label), ["Nickname"])
        XCTAssertEqual(snapshot.agents.map(\.taskName), ["Settings window fix"])
        XCTAssertFalse(snapshot.agents.map(\.label).joined().contains("private"))
    }

    func testOrphanAndArchivedChildrenAreExcludedFromDescendants() async throws {
        let home = try makeTemporaryHome()
        try makeDatabase(
            at: home,
            threads: [
                .init(id: "root", updatedAt: 1_999_900, archived: false, role: nil, nickname: nil),
                .init(id: "valid-child", updatedAt: 1_999_901, archived: false, role: "Worker", nickname: nil),
                .init(id: "archived-child", updatedAt: 1_999_902, archived: true, role: "Archived", nickname: nil),
            ],
            edges: [
                .init(parent: "root", child: "orphan-child", status: "running"),
                .init(parent: "root", child: "archived-child", status: "running"),
                .init(parent: "root", child: "valid-child", status: "completed"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let snapshot = await provider.snapshot(accountID: "C1", home: home)

        XCTAssertEqual(snapshot.sessionID, "root")
        XCTAssertEqual(snapshot.agents.map(\.threadID), ["valid-child"])
        XCTAssertEqual(snapshot.status, .working)
    }

    func testOrphanAndArchivedOpenChildrenDoNotQualifyStaleRoot() async throws {
        let home = try makeTemporaryHome()
        try makeDatabase(
            at: home,
            threads: [
                .init(id: "stale-root", updatedAt: 1_000, archived: false, role: nil, nickname: nil),
                .init(id: "archived-child", updatedAt: 1_001, archived: true, role: nil, nickname: nil),
            ],
            edges: [
                .init(parent: "stale-root", child: "orphan-child", status: "running"),
                .init(parent: "stale-root", child: "archived-child", status: "running"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let snapshot = await provider.snapshot(accountID: "C1", home: home)

        XCTAssertEqual(snapshot.state, .empty)
        XCTAssertEqual(snapshot.source, .localActivity)
        XCTAssertNil(snapshot.sessionID)
    }

    func testSuccessfulReadWithNoQualifyingRootUsesLocalActivitySource() async throws {
        let home = try makeTemporaryHome()
        try makeDatabase(
            at: home,
            threads: [
                .init(id: "stale-root", updatedAt: 1_000, archived: false, role: nil, nickname: nil),
            ],
            edges: []
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let snapshot = await provider.snapshot(accountID: "C1", home: home)

        XCTAssertEqual(snapshot, SessionActivitySnapshot(
            accountID: "C1",
            state: .empty,
            source: .localActivity,
            sessionID: nil,
            status: .unknown,
            agents: []
        ))
    }

    func testEqualTimestampsAndDatabaseRowOrderProduceStableRootAndAgentOrder() async throws {
        let home = try makeTemporaryHome()
        try makeDatabase(
            at: home,
            threads: [
                .init(id: "root-z", updatedAt: 1_999_900, archived: false, role: nil, nickname: nil),
                .init(id: "child-z", updatedAt: 1_999_901, archived: false, role: nil, nickname: nil),
                .init(id: "root-a", updatedAt: 1_999_900, archived: false, role: nil, nickname: nil),
                .init(id: "child-a", updatedAt: 1_999_902, archived: false, role: nil, nickname: nil),
            ],
            edges: [
                .init(parent: "root-a", child: "child-z", status: "completed"),
                .init(parent: "root-a", child: "child-a", status: "running"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let snapshot = await provider.snapshot(accountID: "C1", home: home)

        XCTAssertEqual(snapshot.sessionID, "root-a")
        XCTAssertEqual(snapshot.agents.map(\.threadID), ["child-a", "child-z"])
    }

    func testCyclesDoNotDuplicateDescendantsOrLoop() async throws {
        let home = try makeTemporaryHome()
        try makeDatabase(
            at: home,
            threads: [
                .init(id: "root", updatedAt: 1_999_900, archived: false, role: nil, nickname: nil),
                .init(id: "child-a", updatedAt: 1_999_901, archived: false, role: nil, nickname: nil),
                .init(id: "child-b", updatedAt: 1_999_902, archived: false, role: nil, nickname: nil),
            ],
            edges: [
                .init(parent: "root", child: "child-b", status: "running"),
                .init(parent: "child-b", child: "child-a", status: "waiting"),
                .init(parent: "child-a", child: "child-b", status: "completed"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let snapshot = await provider.snapshot(accountID: "C1", home: home)

        XCTAssertEqual(snapshot.agents.map(\.threadID), ["child-b", "child-a"])
        XCTAssertEqual(Set(snapshot.agents.map(\.threadID)).count, 2)
    }

    func testPrivacyProjectionUsesExactAllowlistAndProtectedWords() {
        let protected = [
            "preview", "first_user_message", "rollout_path", "cwd",
            "auth", "config", "log", "history", "memory", "prompt", "transcript",
            "token",
        ]
        let sql = [
            SQLiteSessionActivityProvider.threadProjectionSQL,
            SQLiteSessionActivityProvider.edgeProjectionSQL,
        ].joined(separator: " ").lowercased()

        XCTAssertEqual(SQLiteSessionActivityProvider.allowedThreadColumns, [
            "id", "updated_at", "archived", "name", "title", "agent_role", "agent_nickname", "agent_path", "thread_source",
            "model", "reasoning_effort",
        ])
        XCTAssertEqual(SQLiteSessionActivityProvider.allowedEdgeColumns, [
            "parent_thread_id", "child_thread_id", "status",
        ])
        for column in protected {
            XCTAssertFalse(sql.contains(column), "privacy projection contains protected token \(column)")
        }
        XCTAssertTrue(sql.contains("title"))
    }

    func testProviderProtocolSupportsInjectedFake() async {
        let expected = SessionActivitySnapshot(
            accountID: "C1",
            state: .available,
            source: .localActivity,
            sessionID: "fake",
            status: .working,
            agents: []
        )
        let provider = FakeSessionActivityProvider(snapshot: expected)

        let actual = await provider.snapshot(accountID: "C1", home: URL(fileURLWithPath: "/unused"))

        XCTAssertEqual(actual, expected)
    }

    private func makeTemporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSessionActivityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func makeDatabase(
        at home: URL,
        threads: [ThreadFixture],
        edges: [EdgeFixture]
    ) throws {
        var statements = [
            "CREATE TABLE threads (id TEXT PRIMARY KEY, updated_at REAL, archived INTEGER, name TEXT, title TEXT, agent_role TEXT, agent_nickname TEXT, agent_path TEXT, thread_source TEXT, model TEXT, reasoning_effort TEXT)",
            "CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT, status TEXT)",
        ]
        statements.append(contentsOf: threads.map { thread in
            "INSERT INTO threads VALUES (\(literal(thread.id)), \(thread.updatedAt), \(thread.archived ? 1 : 0), \(literal(thread.name)), \(literal(thread.title)), \(literal(thread.role)), \(literal(thread.nickname)), \(literal(thread.agentPath)), \(literal(thread.source)), \(literal(thread.model)), \(literal(thread.reasoningEffort)))"
        })
        statements.append(contentsOf: edges.map { edge in
            "INSERT INTO thread_spawn_edges VALUES (\(literal(edge.parent)), \(literal(edge.child)), \(literal(edge.status)))"
        })
        try makeRawDatabase(at: home, statements: statements)
    }

    private func makeRawDatabase(at home: URL, statements: [String]) throws {
        let path = home.appendingPathComponent("state_5.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                path.path,
                &database,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                nil
            ),
            SQLITE_OK
        )
        defer { sqlite3_close(database) }

        for statement in statements {
            XCTAssertEqual(sqlite3_exec(database, statement, nil, nil, nil), SQLITE_OK, statement)
        }
    }

    private func literal(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    /// 격리 데이터베이스에 단일 메타데이터 갱신 실행
    private func execute(_ sql: String, at home: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(home.appendingPathComponent("state_5.sqlite").path,
            &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK, sql)
    }
}

private struct ThreadFixture {
    let id: String
    let updatedAt: Double
    let archived: Bool
    let name: String?
    let title: String?
    let role: String?
    let nickname: String?
    let agentPath: String?
    let source: String?
    let model: String?
    let reasoningEffort: String?

    init(
        id: String,
        updatedAt: Double,
        archived: Bool,
        name: String? = nil,
        title: String? = nil,
        role: String?,
        nickname: String?,
        agentPath: String? = nil,
        source: String? = "cli",
        model: String? = nil,
        reasoningEffort: String? = nil
    ) {
        self.id = id
        self.updatedAt = updatedAt
        self.archived = archived
        self.name = name
        self.title = title
        self.role = role
        self.nickname = nickname
        self.agentPath = agentPath
        self.source = source
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

private struct EdgeFixture {
    let parent: String
    let child: String
    let status: String?
}

private struct FakeSessionActivityProvider: SessionActivityProvider {
    let snapshotValue: SessionActivitySnapshot

    init(snapshot: SessionActivitySnapshot) {
        self.snapshotValue = snapshot
    }

    func snapshot(accountID: String, home: URL) async -> SessionActivitySnapshot {
        snapshotValue
    }
}

private actor ConnectionStateRecorder {
    private(set) var value: SQLiteSessionActivityConnectionState?

    func record(_ state: SQLiteSessionActivityConnectionState) {
        value = state
    }
}

private actor ProjectionCountRecorder {
    private var recorded: SQLiteSessionActivityProjectionCounts?

    func record(_ counts: SQLiteSessionActivityProjectionCounts) {
        recorded = counts
    }

    var value: SQLiteSessionActivityProjectionCounts? {
        recorded
    }
}
