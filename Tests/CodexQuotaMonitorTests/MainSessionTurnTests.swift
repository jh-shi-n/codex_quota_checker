// 목적: 메인 답변 완료 알림·턴별 중복 제거·읽기 경계 검증
// 이용처: 실제 SQLite·JSONL·세션 모니터 연결 회귀 테스트
// 사용방법: swift test --filter MainSessionTurnTests
import Foundation
import SQLite3
import XCTest
@testable import CodexQuotaMonitorKit

/// 명시적 메인 턴 이벤트만 알림으로 이어지는지 확인
@MainActor
final class MainSessionTurnTests: XCTestCase {
    /// JSONL 상태 재구성에서 SQLite 모델 메타데이터 보존 검증
    func testMainTurnReconstructionPreservesModelMetadata() async throws {
        let (home, _) = try fixture(contents: event("task_started", turn: "active"))
        defer { try? FileManager.default.removeItem(at: home) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database,
            "UPDATE threads SET model='gpt-6.1-sol', reasoning_effort='medium' WHERE id='root'", nil, nil, nil), SQLITE_OK)

        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let snapshot = await provider.snapshot(accountID: "C1", home: home)
        XCTAssertEqual(snapshot.sessions.first?.status, .working)
        XCTAssertEqual(snapshot.sessions.first?.model, "GPT-6.1-Sol")
        XCTAssertEqual(snapshot.sessions.first?.reasoningEffort, "medium")
    }

    /// 답변 도중 모델 용량 초과로 끝난 턴의 오류 표시·1회 알림과 다음 턴 정상 복구 검증
    func testCapacityFailureIsReportedAsErrorAndNextTurnCanComplete() async throws {
        let (home, log) = try fixture(contents: event("task_started", turn: "failed-turn"))
        defer { try? FileManager.default.removeItem(at: home) }
        var events: [SessionActivityTransition] = []
        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let monitor = SessionActivityMonitor(accounts: [AccountConfig(id: "C1", home: home, position: .left)],
            provider: provider, now: { Date(timeIntervalSince1970: 1_999_999) }, onTransition: { events.append($0) })
        await monitor.pollNow()
        try append(terminalEvent(turn: "failed-turn", error: [
            "message": "Selected model is at capacity. Please try a different model.",
            "codex_error_info": "server_overloaded",
        ]), to: log)
        await monitor.pollNow()
        await monitor.pollNow()
        XCTAssertEqual(events.map(\.status), [.error])
        XCTAssertEqual(events.map(\.turnID), ["failed-turn"])
        let failed = await monitor.snapshot(for: "C1")
        XCTAssertEqual(failed?.status, .error)
        let toast = SessionActivityToast(content: .transition(try XCTUnwrap(events.first)), durationSeconds: 3)
        XCTAssertEqual(NotchActivityToastCopy.make(for: toast).secondLine?.contains("오류"), true)

        try append(event("task_started", turn: "recovered-turn"), to: log)
        await monitor.pollNow()
        try append(terminalEvent(turn: "recovered-turn", error: NSNull()), to: log)
        await monitor.pollNow()
        XCTAssertEqual(events.map(\.status), [.error, .working, .completed])
    }

    /// 오류 문구의 본문 인용은 완료 상태 유지, 과거 종료 오류의 신규 알림 제외 검증
    func testQuotedCapacityMessageDoesNotFailAndHistoricalErrorDoesNotNotify() async throws {
        let (home, log) = try fixture(contents: terminalEvent(turn: "old-error", error: [
            "message": "Selected model is at capacity. Please try a different model.",
        ], at: 1_998_000))
        defer { try? FileManager.default.removeItem(at: home) }
        var events: [SessionActivityTransition] = []
        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let monitor = SessionActivityMonitor(accounts: [AccountConfig(id: "C1", home: home, position: .left)],
            provider: provider, now: { Date(timeIntervalSince1970: 1_999_999) }, onTransition: { events.append($0) })
        await monitor.pollNow()
        let old = await monitor.snapshot(for: "C1")
        XCTAssertNotEqual(old?.status, .error)
        XCTAssertTrue(events.isEmpty)

        try append(terminalEvent(turn: "success", error: NSNull(), lastMessage:
            "Selected model is at capacity. Please try a different model."), to: log)
        await monitor.pollNow()
        XCTAssertEqual(events.map(\.status), [.completed])
    }

    /// 답변 완료·빠른 다음 답변의 각 1회 전달 및 알림 큐 구분 검증
    func testMainRepliesDeliverOncePerTurnIncludingFastNextReply() async throws {
        let (home, log) = try fixture(contents: event("task_started", turn: "turn-1"))
        defer { try? FileManager.default.removeItem(at: home) }
        var events: [SessionActivityTransition] = []
        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let monitor = SessionActivityMonitor(accounts: [AccountConfig(id: "C1", home: home, position: .left)],
            provider: provider, now: { Date(timeIntervalSince1970: 1_999_999) }, onTransition: { events.append($0) })
        await monitor.pollNow()
        XCTAssertTrue(events.isEmpty)
        try append(event("task_complete", turn: "turn-1"), to: log)
        await monitor.pollNow()
        await monitor.pollNow()
        try append(event("task_started", turn: "turn-2") + event("task_complete", turn: "turn-2"), to: log)
        await monitor.pollNow()
        await monitor.pollNow()
        XCTAssertEqual(events.map(\.status), [.completed, .completed])
        XCTAssertEqual(events.map(\.turnID), ["turn-1", "turn-2"])
        XCTAssertEqual(events.map(\.sessionTitle), ["메인 세션", "메인 세션"])
        XCTAssertNotEqual(events[0].id, events[1].id)
        let queue = SessionActivityToastQueue(sleep: { _ in await Task.yield() })
        for event in events {
            queue.enqueue(event)
        }
        XCTAssertEqual(queue.currentLeft?.transition?.turnID, "turn-1")
        XCTAssertEqual(queue.pendingLeft.first?.transition?.turnID, "turn-2")
        let copy = NotchActivityToastCopy.make(for: try XCTUnwrap(queue.currentLeft))
        XCTAssertEqual(copy.secondLine, "답변 완료")
        queue.cancel()
    }

    /// 앱 시작 이전 완료는 기준 상태로만 사용하고 새 턴 시작을 즉시 반영하는지 검증
    func testHistoricalCompletionDoesNotNotifyAndNewTurnResumesWorking() async throws {
        let (home, log) = try fixture(contents: event("task_complete", turn: "old-turn"))
        defer { try? FileManager.default.removeItem(at: home) }
        var events: [SessionActivityTransition] = []
        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_000) })
        let monitor = SessionActivityMonitor(accounts: [AccountConfig(id: "C1", home: home, position: .left)],
            provider: provider, now: { Date(timeIntervalSince1970: 1_999_999) }, onTransition: { events.append($0) })
        await monitor.pollNow()
        await monitor.pollNow()
        XCTAssertTrue(events.isEmpty)
        let initial = await monitor.snapshot(for: "C1")
        XCTAssertEqual(initial?.status, .completed)
        try append(event("task_started", turn: "new-turn"), to: log)
        await monitor.pollNow()
        XCTAssertEqual(events.map(\.status), [.working])
        try append(event("turn_aborted", turn: "new-turn"), to: log)
        await monitor.pollNow()
        XCTAssertEqual(events.map(\.status), [.working, .stopped])
    }

    /// 오래된 시작 기록만으로 메인 세션을 계속 작업 중으로 표시하지 않는지 검증
    func testStaleStartRetainsExistingInactivityDeadline() async throws {
        let (home, _) = try fixture(contents: event("task_started", turn: "old-turn"))
        defer { try? FileManager.default.removeItem(at: home) }
        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_200) })
        let snapshot = await provider.snapshot(accountID: "C1", home: home)
        XCTAssertEqual(snapshot.status, .inactive)
        XCTAssertEqual(snapshot.sessions.first?.turnID, "old-turn")
    }

    /// 15분 이상 지난 완료 이벤트가 비활성 메인 상태를 덮어쓰지 않는지 검증
    func testOldCompletionNeverOverridesInactiveMainSession() async throws {
        let (home, _) = try fixture(contents: event("task_complete", turn: "old-turn", at: 1_998_000))
        defer { try? FileManager.default.removeItem(at: home) }
        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_200) })
        let snapshot = await provider.snapshot(accountID: "C2", home: home)
        XCTAssertEqual(snapshot.status, .inactive)
        XCTAssertNil(snapshot.sessions.first?.turnID)
    }

    /// 수집 시작 이후 뒤늦게 나타난 과거 완료 제외 및 실제 신규 완료 전달 검증
    func testLateDiscoveredHistoricalCompletionDoesNotNotify() async throws {
        let (home, log) = try fixture(contents: event("task_complete", turn: "old", at: 1_999_990))
        defer { try? FileManager.default.removeItem(at: home) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "UPDATE threads SET archived=1", nil, nil, nil), SQLITE_OK)
        var events: [SessionActivityTransition] = []
        let provider = SQLiteSessionActivityProvider(now: { Date(timeIntervalSince1970: 2_000_005) })
        let monitor = SessionActivityMonitor(accounts: [AccountConfig(id: "C2", home: home, position: .left)],
            provider: provider, now: { Date(timeIntervalSince1970: 2_000_000) }, onTransition: { events.append($0) })
        await monitor.pollNow()
        XCTAssertEqual(sqlite3_exec(database, "UPDATE threads SET archived=0", nil, nil, nil), SQLITE_OK)
        await monitor.pollNow()
        XCTAssertTrue(events.isEmpty)
        try append(event("task_complete", turn: "fresh", at: 2_000_001), to: log)
        await monitor.pollNow()
        XCTAssertEqual(events.map(\.status), [.completed])
        XCTAssertEqual(events.map(\.turnID), ["fresh"])
    }

    /// 시각이 없거나 해석할 수 없는 완료 기록의 신규 완료 오인 방지 검증
    func testCompletionWithoutValidTimestampIsIgnored() async throws {
        let (home, log) = try fixture(contents: "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"old\"}}\n")
        defer { try? FileManager.default.removeItem(at: home) }
        let reader = MainSessionTurnReader()
        let result = await reader.state(home: home, path: log.path)
        XCTAssertNil(result)
    }

    /// 최종 답변 본문·도구 완료를 메인 완료로 오인하지 않고 미완성 행을 보류하는지 검증
    func testOnlyCompleteLifecycleLinesAffectStatus() async throws {
        let (home, log) = try fixture(contents: "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"phase\":\"final_answer\"}}\n")
        defer { try? FileManager.default.removeItem(at: home) }
        let reader = MainSessionTurnReader()
        let ignored = await reader.state(home: home, path: log.path)
        XCTAssertNil(ignored)
        try append(String(event("task_complete", turn: "turn-1").dropLast()), to: log)
        let partial = await reader.state(home: home, path: log.path)
        XCTAssertNil(partial)
        try append("\n", to: log)
        let complete = await reader.state(home: home, path: log.path)
        XCTAssertEqual(complete, MainSessionTurnState(status: .completed, turnID: "turn-1", occurredAt: Date(timeIntervalSince1970: 2_000_000)))
    }

    /// 큰 로그의 끝부분 수집 및 큰 갱신·절단 후 오래된 완료 상태 배제 검증
    func testBoundedTailAndTruncationNeverReuseStaleCompletion() async throws {
        let (home, log) = try fixture(contents: String(repeating: "x", count: 200_000) + "\n" + event("task_complete", turn: "old"))
        defer { try? FileManager.default.removeItem(at: home) }
        let reader = MainSessionTurnReader()
        let initial = await reader.state(home: home, path: log.path)
        XCTAssertEqual(initial?.status, .completed)
        try append(String(repeating: "x", count: 100_000) + "\n", to: log)
        let gap = await reader.state(home: home, path: log.path)
        XCTAssertNil(gap)
        try Data(event("task_started", turn: "new").utf8).write(to: log)
        let restarted = await reader.state(home: home, path: log.path)
        XCTAssertEqual(restarted, MainSessionTurnState(status: .working, turnID: "new", occurredAt: Date(timeIntervalSince1970: 2_000_000)))
    }

    /// 서로 다른 계정의 같은 파일명 격리 및 다른 홈·심볼릭 링크 접근 차단 검증
    func testAccountAndSymlinkBoundaries() async throws {
        let (first, firstLog) = try fixture(contents: event("task_complete", turn: "first"))
        let (second, secondLog) = try fixture(contents: event("task_started", turn: "second"))
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let reader = MainSessionTurnReader()
        let complete = await reader.state(home: first, path: firstLog.path)
        let working = await reader.state(home: second, path: secondLog.path)
        XCTAssertEqual(complete?.turnID, "first")
        XCTAssertEqual(working?.turnID, "second")
        let crossAccount = await reader.state(home: first, path: secondLog.path)
        XCTAssertNil(crossAccount)
        let link = first.appendingPathComponent("sessions/escape.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secondLog)
        let escaped = await reader.state(home: first, path: link.path)
        XCTAssertNil(escaped)
    }

    /// 로컬 기록의 턴 메타데이터만 포함하는 합성 이벤트 생성
    private func event(_ type: String, turn: String, at time: TimeInterval = 2_000_000) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: time))
        return "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(type)\",\"turn_id\":\"\(turn)\"}}\n"
    }

    /// 실제 종료 오류 필드와 마지막 답변을 구분하는 합성 완료 이벤트 생성
    private func terminalEvent(
        turn: String, error: Any, at time: TimeInterval = 2_000_000, lastMessage: String = ""
    ) throws -> String {
        let value: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: time)),
            "type": "event_msg",
            "payload": ["type": "task_complete", "turn_id": turn,
                        "error": error, "last_agent_message": lastMessage],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) + "\n"
    }

    /// 파일 교체 없이 실행 중 로그의 추가 기록 재현
    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// 메인 세션 1개와 해당 로그를 연결한 읽기 전용 수집용 임시 계정 생성
    private func fixture(contents: String) throws -> (URL, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("main-turn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let log = home.appendingPathComponent("sessions/main.jsonl")
        try Data(contents.utf8).write(to: log)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let path = log.path.replacingOccurrences(of: "'", with: "''")
        let sql = """
            CREATE TABLE threads (id TEXT PRIMARY KEY, updated_at REAL, archived INTEGER, name TEXT,
                title TEXT, agent_role TEXT, agent_nickname TEXT, agent_path TEXT, thread_source TEXT,
                model TEXT, reasoning_effort TEXT, rollout_path TEXT);
            CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT, status TEXT);
            INSERT INTO threads VALUES ('root', 1999999, 0, '메인 세션', NULL, NULL, NULL, NULL, 'cli', NULL, NULL, '\(path)');
            """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        return (home, log)
    }
}
