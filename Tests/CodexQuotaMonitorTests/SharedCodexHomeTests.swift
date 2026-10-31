// 목적: 공유 홈 인증 귀속·중복 제거·계정 격리 검증
// 이용처: 공유 Codex 홈 회귀 테스트
// 사용방법: 임시 홈·가상 인증·SQLite·JSONL만 사용
// 실행 예시: swift test --filter SharedCodexHomeTests
import Foundation
import SQLite3
import XCTest
@testable import CodexQuotaMonitorKit

/// 실제 사용자 홈과 분리된 공유 소스 검증
@MainActor
final class SharedCodexHomeTests: XCTestCase {
    /// 계정과 이메일의 동시 일치 및 팀 계정 ID 단독 일치 거부 검증
    func testIdentityRequiresAccountAndUser() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.auth(f.shared, account: "team", email: "a@example.test")
        try f.auth(f.slot.home, account: "team", email: "a@example.test")
        XCTAssertEqual(f.sources(), [f.slot.home, f.shared])
        try f.auth(f.slot.home, account: "team", email: "b@example.test")
        XCTAssertEqual(f.sources(), [f.slot.home])
        try f.auth(f.slot.home, account: "other", email: "a@example.test")
        XCTAssertEqual(f.sources(), [f.slot.home])
        try f.auth(f.slot.home, account: "team", email: nil)
        XCTAssertEqual(f.sources(), [f.slot.home])
    }

    /// 이메일 없는 안정 사용자 식별자 일치 및 충돌 거부 검증
    func testStableUserIdentity() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.auth(f.shared, email: nil, user: "user-a")
        try f.auth(f.slot.home, email: nil, user: "user-a")
        XCTAssertEqual(f.sources().count, 2)
        try f.auth(f.slot.home, email: nil, user: "user-b")
        XCTAssertEqual(f.sources().count, 1)
    }

    /// 누락·잘못된 JSON·잘못된 JWT·파일 크기 상한의 실패 폐쇄 검증
    func testMissingInvalidAndOversizedAuth() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.auth(f.slot.home)
        XCTAssertEqual(f.sources().count, 1)
        for data in [Data("invalid".utf8), Data("{\"tokens\":{\"account_id\":\"team\",\"id_token\":\"x.bad.x\"}}".utf8), Data(repeating: 32, count: 65_537)] {
            try data.write(to: f.shared.appendingPathComponent("auth.json"))
            XCTAssertEqual(f.sources().count, 1)
        }
        try FileManager.default.removeItem(at: f.shared.appendingPathComponent("auth.json"))
        try FileManager.default.createDirectory(at: f.shared.appendingPathComponent("auth.json"), withIntermediateDirectories: true)
        XCTAssertEqual(f.sources().count, 1)
    }

    /// 복수 일치·공유 홈 직접 등록·심볼릭 별칭 등록·Claude 제외 검증
    func testAmbiguousConfiguredAndClaudeSlots() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.auth(f.shared)
        try f.auth(f.slot.home)
        try f.auth(f.other.home)
        XCTAssertEqual(f.sources(accounts: [f.slot, f.other]).count, 1)
        let direct = AccountConfig(id: "C3", home: f.shared, position: .right)
        XCTAssertEqual(f.sources(accounts: [f.slot, direct]).count, 1)
        let alias = f.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.shared)
        XCTAssertEqual(f.sources(accounts: [f.slot, AccountConfig(id: "C4", home: alias, position: .right)]).count, 1)
        let claude = AccountConfig(id: "C4", home: f.root.appendingPathComponent(".claude"), position: .right)
        XCTAssertEqual(f.resolver.homes(for: claude, accounts: [f.slot, claude]), [claude.home])
    }

    /// 당일·전체 집계의 복사 세션·하드 링크·반복 홈 중복 제거와 비일치 슬롯 격리 검증
    func testTokenSourcesIncludeSharedExactlyOnce() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.prepare()
        let local = LocalTokenUsageProvider(calendar: f.calendar, now: { Fixture.date })
        let homes = f.sources(accounts: [f.slot, f.other])
        let full = await local.snapshot(homes: homes + [f.shared])
        XCTAssertEqual(full.today.inputTokens, 30)
        XCTAssertEqual(full.last7Days.inputTokens, 30)
        XCTAssertEqual(full.totalSessions, 2)
        let isolated = await local.snapshot(homes: f.resolver.homes(for: f.other, accounts: [f.slot, f.other]))
        XCTAssertEqual(isolated.today.inputTokens, 7)
        let today = TodayTokenUsageProvider(calendar: f.calendar, now: { Fixture.date })
        for _ in 0..<2 {
            let result = await today.todaySnapshot(homes: homes + [f.shared])
            XCTAssertEqual(result?.today.inputTokens, 30)
            XCTAssertEqual(result?.totalSessions, 2)
        }
        let single = await today.todaySnapshot(homes: [f.other.home])
        XCTAssertEqual(single?.today.inputTokens, 7)
    }

    /// 공유 세션의 과거 날짜 사용량과 오늘 사용량을 날짜별로 함께 집계하는지 검증
    func testSharedHistoryAggregates() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.prepare()
        let file = f.shared.appendingPathComponent("sessions/2026/10/23/history.jsonl")
        let lines = """
        {"type":"session_meta","payload":{"id":"history"}}
        {"type":"token_count","timestamp":\(Fixture.date.addingTimeInterval(-86400).timeIntervalSince1970),"usage":{"input_tokens":11}}

        """
        try Data(lines.utf8).write(to: file)
        let provider = LocalTokenUsageProvider(calendar: f.calendar, now: { Fixture.date })
        let result = await provider.snapshot(homes: f.sources())
        XCTAssertEqual(result.today.inputTokens, 30)
        XCTAssertEqual(result.last7Days.inputTokens, 41)
        XCTAssertEqual(result.last30Days.inputTokens, 41)
        XCTAssertEqual(result.totalSessions, 3)
    }

    /// 실제 SQLite 제공자·감시기의 추가 소스와 동일 세션 단일 표시 검증
    func testSessionSourcesAndMonitor() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.prepare()
        let provider = SQLiteSessionActivityProvider(now: { Fixture.date })
        let accounts = [f.slot, f.other]
        let monitor = SessionActivityMonitor(accounts: accounts, provider: provider, sharedHomeResolver: f.resolver)
        await monitor.pollNow()
        let matched = await monitor.snapshot(for: f.slot.id)
        let other = await monitor.snapshot(for: f.other.id)
        XCTAssertEqual(Set(matched?.sessions.map(\.threadID) ?? []), ["own", "shared"])
        XCTAssertEqual(matched?.sessions.count, 2)
        XCTAssertEqual(other?.sessions.map(\.threadID), ["other"])
        try f.auth(f.shared, email: "other@example.test")
        await monitor.pollNow()
        let after = await monitor.snapshot(for: f.slot.id)
        let switched = await monitor.snapshot(for: f.other.id)
        XCTAssertEqual(after?.sessions.map(\.threadID), ["own"])
        XCTAssertEqual(Set(switched?.sessions.map(\.threadID) ?? []), ["other", "own", "shared"])
    }

    /// 공유 홈 추가 시에도 홈별 파일·바이트 제한을 우회하지 않는지 검증
    func testSharedSourcesKeepReadLimits() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.prepare()
        let homes = f.sources()
        let provider = LocalTokenUsageProvider(calendar: f.calendar, now: { Fixture.date }, maxFileCount: 1)
        let full = await provider.snapshot(homes: homes)
        XCTAssertEqual(full.error, .fileLimitExceeded)
        let today = TodayTokenUsageProvider(calendar: f.calendar, now: { Fixture.date }, maxFiles: 1)
        let result = await today.todaySnapshot(homes: homes)
        XCTAssertNil(result)
    }

    /// 같은 세션 디렉터리의 심볼릭 별칭을 추가해도 단일 집계 여부 검증
    func testSymlinkedSessionDirectory() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.prepare()
        let sharedSessions = f.shared.appendingPathComponent("sessions")
        try FileManager.default.removeItem(at: sharedSessions)
        try FileManager.default.createSymbolicLink(at: sharedSessions, withDestinationURL: f.slot.home.appendingPathComponent("sessions"))
        let provider = LocalTokenUsageProvider(calendar: f.calendar, now: { Fixture.date })
        let result = await provider.snapshot(homes: f.sources())
        XCTAssertEqual(result.today.inputTokens, 10)
        XCTAssertEqual(result.totalSessions, 1)
    }

    /// 이미 표시된 당일 보완값도 공유 로그인 변경 즉시 조회 차단 검증
    func testFallbackHidesPreviousSharedIdentity() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.prepare()
        let store = AccountTokenUsageStore(now: { Fixture.date })
        let account = AccountState(id: f.slot.id, status: .normal)
        store.localTodayIdentity = { _ in f.resolver.signature(for: f.slot, accounts: [f.slot, f.other]) }
        store.localTodayLoader = { _ in
            await LocalTokenUsageProvider(calendar: f.calendar, now: { Fixture.date })
                .snapshot(homes: f.sources(accounts: [f.slot, f.other]))
        }
        await store.refresh(for: account)?.value
        XCTAssertEqual(store.localTodaySnapshot(for: account)?.today.inputTokens, 30)
        try f.auth(f.shared, email: "other@example.test")
        XCTAssertNil(store.localTodaySnapshot(for: account))
        await store.refresh(for: account, force: true)?.value
        XCTAssertEqual(store.localTodaySnapshot(for: account)?.today.inputTokens, 10)
    }

    /// 인증 변경 시 메모리·영속 집계 격리와 재조회 귀속 변경 검증
    func testCacheReevaluatesLoginAndHistory() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.prepare()
        let cache = TokenUsageSnapshotCache(provider: LocalTokenUsageProvider(calendar: f.calendar, now: { Fixture.date }),
            databaseURL: f.root.appendingPathComponent("cache.sqlite"),
            accountHomes: [f.slot.id: f.slot.home, f.other.id: f.other.home], now: { Fixture.date }, calendar: f.calendar,
            historyDatabaseURL: f.root.appendingPathComponent("history.sqlite"),
            todayProvider: TodayTokenUsageProvider(calendar: f.calendar, now: { Fixture.date }), sharedHomeResolver: f.resolver)
        let first = await cache.refresh(accountID: f.slot.id, home: f.slot.home)
        XCTAssertEqual(first.today.inputTokens, 30)
        let live = await cache.refreshToday(accountID: f.slot.id, home: f.slot.home)
        XCTAssertEqual(live?.today.inputTokens, 30)
        try f.auth(f.shared, email: "other@example.test")
        let stale = await cache.cachedSnapshot(for: f.slot.id)
        XCTAssertNil(stale)
        let own = await cache.refresh(accountID: f.slot.id, home: f.slot.home)
        let switched = await cache.refresh(accountID: f.other.id, home: f.other.home)
        XCTAssertEqual(own.today.inputTokens, 10)
        XCTAssertEqual(switched.today.inputTokens, 37)
    }
}

/// 가상 인증과 제한된 메타데이터만 포함한 임시 홈 묶음
private struct Fixture {
    static let date = Date(timeIntervalSince1970: 1_792_756_800)
    let root: URL
    let shared: URL
    let slot: AccountConfig
    let other: AccountConfig
    let resolver: SharedCodexHomeResolver
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// 기본 공유 홈까지 임시 루트 아래 구성
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        resolver = SharedCodexHomeResolver(homeDirectory: root)
        shared = resolver.sharedHome
        slot = AccountConfig(id: "C1", home: root.appendingPathComponent("slot"), position: .left)
        other = AccountConfig(id: "C2", home: root.appendingPathComponent("other"), position: .right)
        for home in [shared, slot.home, other.home] {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
    }

    /// 테스트 종료 시 임시 파일 전체 정리
    func remove() { try? FileManager.default.removeItem(at: root) }

    /// 현재 가상 인증 기준의 슬롯 소스 조회
    func sources(accounts: [AccountConfig]? = nil) -> [URL] {
        resolver.homes(for: slot, accounts: accounts ?? [slot])
    }

    /// 비밀 정보 없는 가상 JWT 인증 파일 작성
    func auth(_ home: URL, account: String = "team", email: String? = "a@example.test", user: String? = nil) throws {
        var claims: [String: Any] = [:]
        claims["email"] = email
        if let user { claims["https://api.openai.com/auth"] = ["chatgpt_user_id": user] }
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
        let data = try JSONSerialization.data(withJSONObject: ["tokens": ["account_id": account, "id_token": "fixture.\(payload).fixture"]])
        try data.write(to: home.appendingPathComponent("auth.json"))
    }

    /// 서로 다른 계정과 중복 세션을 가진 통합 fixture 구성
    func prepare() throws {
        try auth(shared)
        try auth(slot.home)
        try auth(other.home, email: "other@example.test")
        try database(home: slot.home, sessions: [("own", 10)])
        try database(home: shared, sessions: [("own", 10), ("shared", 20)])
        try database(home: other.home, sessions: [("other", 7)])
        let directory = shared.appendingPathComponent("sessions/2026/10/23")
        try FileManager.default.linkItem(at: directory.appendingPathComponent("shared.jsonl"),
                                         to: directory.appendingPathComponent("linked.jsonl"))
    }

    /// 당일 증분·활동 제공자 공용 최소 SQLite 및 JSONL 작성
    func database(home: URL, sessions: [(String, Int)]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK, let db else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE threads(id TEXT, updated_at REAL, archived INTEGER, name TEXT, title TEXT,
          agent_role TEXT, agent_nickname TEXT, agent_path TEXT, thread_source TEXT, rollout_path TEXT);
        CREATE TABLE thread_spawn_edges(parent_thread_id TEXT, child_thread_id TEXT, status TEXT);
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        let directory = home.appendingPathComponent("sessions/2026/10/23")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (id, input) in sessions {
            let file = directory.appendingPathComponent("\(id).jsonl")
            let meta: [String: Any] = ["type": "session_meta", "payload": ["id": id]]
            let event: [String: Any] = ["type": "event_msg", "timestamp": Self.date.timeIntervalSince1970,
                "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": input]]]]
            var data = try JSONSerialization.data(withJSONObject: meta)
            data.append(10)
            data.append(try JSONSerialization.data(withJSONObject: event))
            data.append(10)
            try data.write(to: file)
            let sql = "INSERT INTO threads VALUES ('\(id)', \(Self.date.timeIntervalSince1970), 0, '\(id)', NULL, NULL, NULL, NULL, 'cli', '\(file.path)')"
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        }
    }
}
