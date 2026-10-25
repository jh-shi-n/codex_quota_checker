import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

final class ClaudeSessionActivityTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testChangingProviderAtTheSameHomeEstablishesANewBaseline() async throws {
        let fixture = try ActivityFixture()
        defer { fixture.remove() }
        try fixture.write(status: "busy", at: fixture.clock.time)
        let events = ActivityEvents()
        let monitor = SessionActivityMonitor(
            accounts: [AccountConfig(id: "C2", home: fixture.root, position: .left)],
            provider: AccountSessionActivityProvider(codex: CodexActivitySpy(), claude: fixture.provider),
            now: { fixture.clock.date }, onTransition: { events.values.append($0) })
        await monitor.pollNow()
        await monitor.reconfigure(accounts: [AccountConfig(id: "C2", home: fixture.root, position: .left, provider: .claude)])
        await monitor.pollNow()
        XCTAssertTrue(events.values.isEmpty)
        let snapshot = await monitor.snapshot(for: "C2")
        XCTAssertEqual(snapshot?.sessions.first?.status, .working)
    }

    func testIdleBaselineDoesNotClaimCompletionAndRepeatedReadsKeepTurnIdentity() async throws {
        let fixture = try ActivityFixture()
        defer { fixture.remove() }
        try fixture.write(status: "idle", at: 1_900_000_000)
        let first = await fixture.provider.snapshot(accountID: "C2", home: fixture.root)
        let second = await fixture.provider.snapshot(accountID: "C2", home: fixture.root)
        XCTAssertEqual(first.sessions.first?.status, .waiting)
        XCTAssertEqual(first, second)
    }

    @MainActor
    func testClaudeMonitorEmitsStartAndCompletionOnceWithoutAConversationRead() async throws {
        let fixture = try ActivityFixture()
        defer { fixture.remove() }
        try fixture.write(status: "idle", at: fixture.clock.time - 1)
        let events = ActivityEvents()
        let config = AccountConfig(id: "C2", home: fixture.root, position: .left, provider: .claude)
        let monitor = SessionActivityMonitor(accounts: [config],
            provider: AccountSessionActivityProvider(claude: fixture.provider), now: { fixture.clock.date },
            onTransition: { events.values.append($0) })
        await monitor.pollNow()
        XCTAssertTrue(events.values.isEmpty)
        fixture.clock.advance(1)
        try fixture.write(status: "busy", at: fixture.clock.time)
        await monitor.pollNow()
        let startedTurn = events.values.first?.turnID
        fixture.clock.advance(3)
        try fixture.write(status: "idle", at: fixture.clock.time)
        await monitor.pollNow()
        await monitor.pollNow()
        XCTAssertEqual(events.values.map(\.status), [.working, .completed])
        XCTAssertEqual(events.values.map(\.turnID), [startedTurn, startedTurn])
        XCTAssertEqual(events.values.map(\.sessionTitle), ["Example session", "Example session"])
    }

    func testQuickTurnBetweenIdlePollsStillProducesOnlyOneNewCompletion() async throws {
        let fixture = try ActivityFixture()
        defer { fixture.remove() }
        try fixture.write(status: "idle", at: fixture.clock.time - 1)
        let baseline = await fixture.provider.snapshot(accountID: "C2", home: fixture.root)
        fixture.clock.advance(3)
        try fixture.write(status: "idle", at: fixture.clock.time)
        let finished = await fixture.provider.snapshot(accountID: "C2", home: fixture.root)
        let same = await fixture.provider.snapshot(accountID: "C2", home: fixture.root)
        XCTAssertEqual(finished.sessions.first?.status, .completed)
        XCTAssertNotEqual(finished.sessions.first?.turnID, baseline.sessions.first?.turnID)
        XCTAssertEqual(finished, same)
    }

    func testProcessExitIsStoppedAndOldDeadFilesNeverBecomeNewCompletions() async throws {
        let fixture = try ActivityFixture()
        defer { fixture.remove() }
        try fixture.write(status: "busy", at: fixture.clock.time)
        let working = await fixture.provider.snapshot(accountID: "C2", home: fixture.root)
        XCTAssertEqual(working.sessions.first?.status, .working)
        fixture.clock.advance(2)
        fixture.clock.alive = false
        let exited = await fixture.provider.snapshot(accountID: "C2", home: fixture.root)
        let repeated = await fixture.provider.snapshot(accountID: "C2", home: fixture.root)
        XCTAssertEqual(exited.sessions.first?.status, .stopped)
        XCTAssertEqual(exited, repeated)
        let fresh = ClaudeSessionActivityProvider(now: { fixture.clock.date }, isProcessAlive: { _ in false })
        let stale = await fresh.snapshot(accountID: "C2", home: fixture.root)
        XCTAssertEqual(stale.state, .empty)
    }

    func testDescriptorRemovalRetainsAnExplicitStoppedEvent() async throws {
        let fixture = try ActivityFixture()
        defer { fixture.remove() }
        try fixture.write(status: "busy", at: fixture.clock.time)
        _ = await fixture.provider.snapshot(accountID: "C2", home: fixture.root)
        fixture.clock.advance(2)
        try FileManager.default.removeItem(at: fixture.file)
        let stopped = await fixture.provider.snapshot(accountID: "C2", home: fixture.root)
        XCTAssertEqual(stopped.sessions.first?.status, .stopped)
        XCTAssertEqual(stopped.sessions.first?.isActive, false)
    }

    func testLongRunningSessionsStillReportExitAndExpiredExitRecordsAreRemoved() async throws {
        let fixture = try ActivityFixture()
        defer { fixture.remove() }
        try fixture.write(status: "busy", at: fixture.clock.time - 3_600)
        let working = await fixture.provider.snapshot(accountID: "C2", home: fixture.root)
        XCTAssertEqual(working.sessions.first?.status, .working)
        try FileManager.default.removeItem(at: fixture.file)
        fixture.clock.advance(2)
        let stopped = await fixture.provider.snapshot(accountID: "C2", home: fixture.root)
        XCTAssertEqual(stopped.sessions.first?.status, .stopped)
        fixture.clock.advance(ClaudeSessionActivityProvider.recentActivityWindow + 1)
        let expired = await fixture.provider.snapshot(accountID: "C2", home: fixture.root)
        XCTAssertEqual(expired.state, .empty)
    }

    func testPartialWritesAndMissingDirectoryNeverFabricateCompletion() async throws {
        let fixture = try ActivityFixture()
        defer { fixture.remove() }
        try fixture.write(status: "busy", at: fixture.clock.time)
        _ = await fixture.provider.snapshot(accountID: "C2", home: fixture.root)
        try Data("{".utf8).write(to: fixture.file)
        let partial = await fixture.provider.snapshot(accountID: "C2", home: fixture.root)
        XCTAssertEqual(partial.state, .unavailable)
        try FileManager.default.removeItem(at: fixture.directory)
        let missing = await fixture.provider.snapshot(accountID: "C2", home: fixture.root)
        XCTAssertEqual(missing.state, .unavailable)
    }

    func testOnlyWhitelistedMetadataIsProjectedAndPrivateFilesAreUntouched() async throws {
        let fixture = try ActivityFixture()
        defer { fixture.remove() }
        try fixture.write(status: "busy", at: fixture.clock.time, title: "/private/example/path")
        let secret = Data("PRIVATE-CONTENT-MUST-NOT-APPEAR".utf8)
        let key = fixture.directory.appendingPathComponent("123.secret.key")
        let projects = fixture.root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let transcript = projects.appendingPathComponent("conversation.jsonl")
        try secret.write(to: key)
        try secret.write(to: transcript)
        let descriptorBefore = try Data(contentsOf: fixture.file)
        let snapshot = await fixture.provider.snapshot(accountID: "C2", home: fixture.root)
        XCTAssertEqual(snapshot.sessions.first?.title, "Claude session")
        XCTAssertFalse(String(describing: snapshot).contains("PRIVATE-CONTENT"))
        XCTAssertEqual(try Data(contentsOf: key), secret)
        XCTAssertEqual(try Data(contentsOf: transcript), secret)
        XCTAssertEqual(try Data(contentsOf: fixture.file), descriptorBefore)
    }

    func testSymlinksOversizedDescriptorsAndForeignProcessIDsAreIgnored() async throws {
        let fixture = try ActivityFixture()
        defer { fixture.remove() }
        try fixture.write(status: "busy", at: fixture.clock.time)
        let outside = fixture.root.appendingPathComponent("outside.json")
        try FileManager.default.moveItem(at: fixture.file, to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: outside)
        let linked = await fixture.provider.snapshot(accountID: "C2", home: fixture.root)
        XCTAssertEqual(linked.state, .empty)
        try FileManager.default.removeItem(at: fixture.file)
        try Data(repeating: 32, count: ClaudeSessionActivityProvider.maximumFileBytes + 1).write(to: fixture.file)
        let huge = await fixture.provider.snapshot(accountID: "C2", home: fixture.root)
        XCTAssertEqual(huge.state, .empty)
        try fixture.write(status: "busy", at: fixture.clock.time, pidDomain: "linux")
        let foreign = await fixture.provider.snapshot(accountID: "C2", home: fixture.root)
        XCTAssertEqual(foreign.state, .empty)
    }

    func testAccountRoutingNeverReadsCodexDataForClaudeAndKeepsHomesIsolated() async throws {
        let first = try ActivityFixture()
        let second = try ActivityFixture()
        defer { first.remove(); second.remove() }
        try first.write(status: "busy", at: first.clock.time, title: "First session")
        try second.write(status: "idle", at: second.clock.time, title: "Second session")
        let codex = CodexActivitySpy()
        let router = AccountSessionActivityProvider(codex: codex, claude: first.provider)
        let one = await router.snapshot(for: AccountConfig(id: "C2", home: first.root, position: .left, provider: .claude))
        let two = await router.snapshot(for: AccountConfig(id: "C3", home: second.root, position: .right, provider: .claude))
        XCTAssertEqual(one.sessions.first?.title, "First session")
        XCTAssertEqual(two.sessions.first?.title, "Second session")
        let before = await codex.reads
        XCTAssertEqual(before, 0)
        _ = await router.snapshot(for: AccountConfig(id: "C1", home: first.root, position: .left))
        let after = await codex.reads
        XCTAssertEqual(after, 1)
    }
}

private final class ActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1_900_000_010
    private var living = true
    var time: TimeInterval { lock.withLock { value } }
    var date: Date { Date(timeIntervalSince1970: time) }
    var alive: Bool {
        get { lock.withLock { living } }
        set { lock.withLock { living = newValue } }
    }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

private struct ActivityFixture: Sendable {
    let root: URL
    let directory: URL
    let file: URL
    let clock: ActivityClock
    let provider: ClaudeSessionActivityProvider

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directory = root.appendingPathComponent("sessions")
        file = directory.appendingPathComponent("123.json")
        clock = ActivityClock()
        let clock = self.clock
        provider = ClaudeSessionActivityProvider(now: { clock.date }, isProcessAlive: { _ in clock.alive })
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func write(status: String, at: TimeInterval, title: String = "Example session", pidDomain: String = "darwin") throws {
        let object: [String: Any] = [
            "pid": 123, "sessionId": "11111111-2222-4333-8444-555555555555", "name": title,
            "status": status, "statusUpdatedAt": at * 1_000, "updatedAt": at * 1_000,
            "startedAt": 1_899_999_000_000.0, "pidDomain": pidDomain,
            "prompt": "PRIVATE-CONTENT-MUST-NOT-APPEAR", "cwd": "/private/example/path",
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@MainActor private final class ActivityEvents {
    var values: [SessionActivityTransition] = []
}

private actor CodexActivitySpy: SessionActivityProvider {
    var reads = 0
    func snapshot(accountID: String, home: URL) async -> SessionActivitySnapshot {
        reads += 1
        return .empty(accountID: accountID)
    }
}
