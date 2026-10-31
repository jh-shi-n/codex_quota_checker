// 목적: 당일 증분 집계의 정확성·읽기 비용·실패 시 기존 값 보존 검증
// 이용처: 당일 사용량 자동 반영 회귀 테스트
// 사용방법: swift test --filter TodayTokenUsageTests
import Foundation
import SQLite3
import XCTest
@testable import CodexQuotaMonitorKit

/// 사용자 계정과 분리된 SQLite·JSONL 파일을 이용한 자동 수집 검증
@MainActor
final class TodayTokenUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_756_800)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    /// 이전 날짜에 시작한 재개 세션의 당일 증가분만 집계하고 추가 바이트만 읽는지 검증
    func testResumedSessionUsesDailyDeltasAndReadsOnlyAppendedBytes() async throws {
        let fixture = try TodayUsageFixture()
        defer { fixture.remove() }
        let yesterday = now.addingTimeInterval(-86400)
        let file = try fixture.rollout("2026/10/22", name: "old", data:
            tokenLine(at: yesterday, input: 100) + tokenLine(at: now, input: 150), updatedAt: now)
        let provider = TodayTokenUsageProvider(calendar: calendar, now: { [now] in now })
        let first = await provider.todaySnapshot(home: fixture.home)
        XCTAssertEqual(first?.today.inputTokens, 50)
        let firstRead = await provider.lastReadBytes
        XCTAssertGreaterThan(firstRead, 0)
        let repeated = await provider.todaySnapshot(home: fixture.home)
        let repeatedRead = await provider.lastReadBytes
        XCTAssertEqual(repeated?.today.inputTokens, 50)
        XCTAssertEqual(repeatedRead, 0)
        let appended = tokenLine(at: now, input: 180)
        try append(appended, to: file)
        let updated = await provider.todaySnapshot(home: fixture.home)
        let updateRead = await provider.lastReadBytes
        XCTAssertEqual(updated?.today.inputTokens, 80)
        XCTAssertEqual(updateRead, appended.count)
    }

    /// 기록 중인 미완성 행을 부분 숫자로 반영하지 않고 완결 후 한 번만 집계하는지 검증
    func testPartialLineIsDeferredUntilCompleted() async throws {
        let fixture = try TodayUsageFixture()
        defer { fixture.remove() }
        let line = tokenLine(at: now, input: 25)
        let cut = line.count / 2
        let file = try fixture.rollout("2026/10/23", name: "partial", data: line.prefix(cut), updatedAt: now)
        let provider = TodayTokenUsageProvider(calendar: calendar, now: { [now] in now })
        let partial = await provider.todaySnapshot(home: fixture.home)
        XCTAssertNil(partial)
        try append(line.suffix(from: cut), to: file)
        let complete = await provider.todaySnapshot(home: fixture.home)
        XCTAssertEqual(complete?.today.inputTokens, 25)
        let repeated = await provider.todaySnapshot(home: fixture.home)
        XCTAssertEqual(repeated?.today.inputTokens, 25)
    }

    /// 큰 초기 파일의 분할 수집과 읽기 상한 및 부분 합계 비공개 검증
    func testInitialScanIsBoundedAndMakesProgressAcrossPolls() async throws {
        let fixture = try TodayUsageFixture()
        defer { fixture.remove() }
        let data = (1...20).reduce(into: Data()) { $0.append(tokenLine(at: now, input: Int64($1))) }
        _ = try fixture.rollout("2026/10/23", name: "large", data: data, updatedAt: now)
        let provider = TodayTokenUsageProvider(calendar: calendar, now: { [now] in now }, maxReadBytes: 512)
        var snapshot: TokenUsageSnapshot?
        for iteration in 0..<30 {
            snapshot = await provider.todaySnapshot(home: fixture.home)
            let read = await provider.lastReadBytes
            XCTAssertLessThanOrEqual(read, 512)
            if iteration == 0 { XCTAssertNil(snapshot) }
            if snapshot != nil { break }
        }
        XCTAssertEqual(snapshot?.today.inputTokens, 20)
    }

    /// 파일 절단·원자 교체 시 이전 커서와 누계를 폐기하는지 검증
    func testTruncationAndReplacementResetCursor() async throws {
        let fixture = try TodayUsageFixture()
        defer { fixture.remove() }
        let file = try fixture.rollout("2026/10/23", name: "replaced", data:
            tokenLine(at: now, input: 10) + tokenLine(at: now, input: 90), updatedAt: now)
        let provider = TodayTokenUsageProvider(calendar: calendar, now: { [now] in now })
        let first = await provider.todaySnapshot(home: fixture.home)
        XCTAssertEqual(first?.today.inputTokens, 90)
        try tokenLine(at: now, input: 7).write(to: file)
        let truncated = await provider.todaySnapshot(home: fixture.home)
        XCTAssertEqual(truncated?.today.inputTokens, 7)
        try tokenLine(at: now, input: 9).write(to: file, options: .atomic)
        let replaced = await provider.todaySnapshot(home: fixture.home)
        XCTAssertEqual(replaced?.today.inputTokens, 9)
    }

    /// 목록 상한·DB 부재·다른 계정 경로를 자동 읽기와 분리하는지 검증
    func testFileLimitAndMissingDatabaseDoNotPublishPartialTotals() async throws {
        let fixture = try TodayUsageFixture()
        defer { fixture.remove() }
        _ = try fixture.rollout("2026/10/23", name: "one", data: tokenLine(at: now, input: 10), updatedAt: now)
        _ = try fixture.rollout("2026/10/23", name: "two", data: tokenLine(at: now, input: 20), updatedAt: now)
        let provider = TodayTokenUsageProvider(calendar: calendar, now: { [now] in now }, maxFiles: 1)
        let limited = await provider.todaySnapshot(home: fixture.home)
        let read = await provider.lastReadBytes
        XCTAssertNil(limited)
        XCTAssertEqual(read, 0)
        let absent = await provider.todaySnapshot(home: fixture.home.appendingPathComponent("missing"))
        XCTAssertNil(absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("missing/state_5.sqlite").path))
    }

    /// 오늘 합계의 하향 정정·과거 기록 보존·실패 시 마지막 성공 유지 검증
    func testLiveMergeReplacesCorrectedTotalsAndPreservesHistory() async throws {
        let fixture = try TodayUsageFixture()
        defer { fixture.remove() }
        let date = now
        let yesterday = calendar.startOfDay(for: now.addingTimeInterval(-86400))
        let live = MutableTodayProvider(value: source(input: 15))
        let initial = TokenUsageAggregator(calendar: calendar).aggregate(dailyPoints: [
            TokenUsageDailyPoint(date: yesterday, inputTokens: 7, outputTokens: 0, cachedInputTokens: nil, sessionCount: 1),
            TokenUsageDailyPoint(date: now, inputTokens: 10, outputTokens: 0, cachedInputTokens: nil, sessionCount: 1)
        ], generatedAt: now)
        let database = fixture.home.appendingPathComponent("cache.sqlite")
        let history = fixture.home.appendingPathComponent("history.sqlite")
        let cache = TokenUsageSnapshotCache(provider: FixedTodayHistory(value: initial), databaseURL: database,
            accountHomes: ["C1": fixture.home], now: { date }, calendar: calendar,
            historyDatabaseURL: history, todayProvider: live)
        _ = await cache.refresh(accountID: "C1", home: fixture.home)
        let updated = await cache.refreshToday(accountID: "C1", home: fixture.home)
        XCTAssertEqual(updated?.today.inputTokens, 15)
        XCTAssertEqual(updated?.dailyPoints.first { $0.date == yesterday }?.inputTokens, 7)
        let repeated = await cache.refreshToday(accountID: "C1", home: fixture.home)
        XCTAssertEqual(repeated?.last7Days.inputTokens, 22)
        await live.set(source(input: 2))
        let lower = await cache.refreshToday(accountID: "C1", home: fixture.home)
        XCTAssertEqual(lower?.today.inputTokens, 2)
        await live.set(nil)
        let failed = await cache.refreshToday(accountID: "C1", home: fixture.home)
        XCTAssertEqual(failed?.today.inputTokens, 2)
        let restarted = TokenUsageSnapshotCache(databaseURL: database, accountHomes: ["C1": fixture.home],
            now: { date }, calendar: calendar, historyDatabaseURL: history)
        let restored = await restarted.cachedSnapshot(for: "C1")
        XCTAssertEqual(restored?.last7Days.inputTokens, 9)
    }

    /// 계정 무효화와 보관 정책 변경 이후 늦게 끝난 당일 집계의 저장 차단 검증
    func testLateLiveResultCannotRestoreRemovedAccountOrOldPolicy() async throws {
        for changePolicy in [false, true] {
            let fixture = try TodayUsageFixture()
            defer { fixture.remove() }
            let date = now
            let gate = GatedTodayProvider(value: source(input: 50))
            let cache = TokenUsageSnapshotCache(accountHomes: ["C1": fixture.home], now: { date },
                calendar: calendar, historyDatabaseURL: fixture.home.appendingPathComponent("history.sqlite"), todayProvider: gate)
            let request = Task { await cache.refreshToday(accountID: "C1", home: fixture.home) }
            await gate.waitUntilStarted()
            if changePolicy { _ = await cache.setHistoryRetention(months: 3) }
            else { cache.invalidate(accountID: "C1") }
            await gate.release()
            let result = await request.value
            XCTAssertNil(result)
            let stored = await cache.cachedSnapshot(for: "C1")
            XCTAssertNil(stored)
        }
    }

    /// 동일 파일명을 사용하는 서로 다른 계정의 누계·커서 분리 검증
    func testTwoAccountHomesHaveIndependentCursorsAndTotals() async throws {
        let first = try TodayUsageFixture()
        let second = try TodayUsageFixture()
        defer { first.remove(); second.remove() }
        _ = try first.rollout("2026/10/23", name: "same-name", data: tokenLine(at: now, input: 11), updatedAt: now)
        _ = try second.rollout("2026/10/23", name: "same-name", data: tokenLine(at: now, input: 22), updatedAt: now)
        let provider = TodayTokenUsageProvider(calendar: calendar, now: { [now] in now })
        let a = await provider.todaySnapshot(home: first.home)
        let b = await provider.todaySnapshot(home: second.home)
        let again = await provider.todaySnapshot(home: first.home)
        XCTAssertEqual(a?.today.inputTokens, 11)
        XCTAssertEqual(b?.today.inputTokens, 22)
        XCTAssertEqual(again?.today.inputTokens, 11)
    }

    /// 자정 이후에도 파일 커서를 재사용하고 새 날짜의 증가분만 반영하는지 검증
    func testMidnightRollsOverWithoutRecountingPreviousDay() async throws {
        let fixture = try TodayUsageFixture()
        defer { fixture.remove() }
        let clock = TodayUsageClock(now)
        let file = try fixture.rollout("2026/10/23", name: "cross-day", data: tokenLine(at: now, input: 100), updatedAt: now)
        let provider = TodayTokenUsageProvider(calendar: calendar, now: { clock.read() })
        let first = await provider.todaySnapshot(home: fixture.home)
        XCTAssertEqual(first?.today.inputTokens, 100)
        let next = now.addingTimeInterval(86400)
        clock.set(next)
        try fixture.updateTimestamps(next)
        let added = tokenLine(at: next, input: 140)
        try append(added, to: file)
        let second = await provider.todaySnapshot(home: fixture.home)
        let read = await provider.lastReadBytes
        XCTAssertEqual(second?.today.inputTokens, 40)
        XCTAssertEqual(read, added.count)
    }

    /// 큰 원문 행은 보관하지 않고 주기별 상한 내에서 건너뛰는지 검증
    func testOversizedLineAcrossPollsDoesNotBlockTokenEvents() async throws {
        let fixture = try TodayUsageFixture()
        defer { fixture.remove() }
        let data = Data(repeating: 120, count: 5 * 1024 * 1024) + Data([10]) + tokenLine(at: now, input: 35)
        _ = try fixture.rollout("2026/10/23", name: "oversized", data: data, updatedAt: now)
        let provider = TodayTokenUsageProvider(calendar: calendar, now: { [now] in now })
        let first = await provider.todaySnapshot(home: fixture.home)
        let initialRead = await provider.lastReadBytes
        XCTAssertNil(first)
        XCTAssertEqual(initialRead, TodayTokenUsageProvider.maximumReadBytes)
        let second = await provider.todaySnapshot(home: fixture.home)
        XCTAssertEqual(second?.today.inputTokens, 35)
    }

    /// 전체 새로고침 진행 중에는 별도의 자동 수집을 시작하지 않는지 검증
    func testAutomaticCollectionWaitsForManualRefresh() async throws {
        let fixture = try TodayUsageFixture()
        defer { fixture.remove() }
        let gate = GatedTodayProvider(value: source(input: 40))
        let automatic = MutableTodayProvider(value: source(input: 50))
        let date = now
        let cache = TokenUsageSnapshotCache(provider: gate, accountHomes: ["C1": fixture.home],
            now: { date }, calendar: calendar, todayProvider: automatic)
        let manual = Task { await cache.refresh(accountID: "C1", home: fixture.home) }
        await gate.waitUntilStarted()
        let value = await cache.refreshToday(accountID: "C1", home: fixture.home)
        let calls = await automatic.requests
        XCTAssertNil(value)
        XCTAssertEqual(calls, 0)
        await gate.release()
        let result = await manual.value
        XCTAssertEqual(result.today.inputTokens, 40)
    }

    /// 현재 날짜의 한 계정 사용량 생성
    private func source(input: Int64) -> TokenUsageSnapshot {
        TokenUsageAggregator(calendar: calendar, dayCount: 1).aggregate(dailyPoints: [
            TokenUsageDailyPoint(date: now, inputTokens: input, outputTokens: 0, cachedInputTokens: nil, sessionCount: 1)
        ], generatedAt: now)
    }

    /// 원문 메시지 없이 숫자와 타임스탬프만 포함한 누적 사용량 행 생성
    private func tokenLine(at date: Date, input: Int64) -> Data {
        let object: [String: Any] = ["timestamp": date.timeIntervalSince1970, "type": "event_msg",
            "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": input, "output_tokens": 0]]]]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([10])
    }

    /// 기록 중인 로그 파일 뒤에 추가 바이트 연결
    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

/// 당일 세션 목록과 롤아웃을 제공하는 격리된 파일 저장소
private final class TodayUsageFixture {
    let home: URL

    /// 읽기 전용 수집에 필요한 최소 인덱스 DB 생성
    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try execute("CREATE TABLE threads (rollout_path TEXT, updated_at REAL); CREATE INDEX recent ON threads(updated_at)")
    }

    /// 날짜별 로그 파일 생성 및 당일 업데이트 목록 등록
    func rollout(_ directory: String, name: String, data: Data, updatedAt: Date) throws -> URL {
        let folder = home.appendingPathComponent("sessions/" + directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name + ".jsonl")
        try data.write(to: url)
        let escaped = url.path.replacingOccurrences(of: "'", with: "''")
        try execute("INSERT INTO threads VALUES ('\(escaped)', \(updatedAt.timeIntervalSince1970))")
        return url
    }

    /// 테스트 목록 초기화와 행 등록을 위한 SQLite 실행
    private func execute(_ sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &handle) == SQLITE_OK,
              let handle else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    /// 검증 완료 후 임시 DB·로그 제거
    func remove() { try? FileManager.default.removeItem(at: home) }

    /// 자정 경계의 세션 갱신 시각 변경
    func updateTimestamps(_ date: Date) throws { try execute("UPDATE threads SET updated_at = \(date.timeIntervalSince1970)") }
}

/// 정상·실패 자동 수집 결과를 바꾸는 대역
private actor MutableTodayProvider: TokenUsageTodayProvider {
    private var value: TokenUsageSnapshot?
    private(set) var requests = 0
    /// 반환 집계 설정
    init(value: TokenUsageSnapshot?) { self.value = value }
    /// 후속 자동 수집 응답 교체
    func set(_ value: TokenUsageSnapshot?) { self.value = value }
    /// 지정한 수집 결과 반환
    func todaySnapshot(home: URL) async -> TokenUsageSnapshot? { requests += 1; return value }
}

/// 과거·오늘 초기 전체 집계를 반환하는 대역
private struct FixedTodayHistory: TokenUsageProvider {
    let value: TokenUsageSnapshot
    /// 기존 전체 집계 반환
    func snapshot(home: URL) async -> TokenUsageSnapshot { value }
}

/// 계정·정책 변경과 당일 응답 완료 순서 제어
private actor GatedTodayProvider: TokenUsageTodayProvider, TokenUsageProvider {
    let value: TokenUsageSnapshot
    private var pending: CheckedContinuation<TokenUsageSnapshot?, Never>?
    private var started: CheckedContinuation<Void, Never>?
    /// 지연 후 반환할 집계 연결
    init(value: TokenUsageSnapshot) { self.value = value }
    /// 외부 해제까지 결과 보류
    func todaySnapshot(home: URL) async -> TokenUsageSnapshot? {
        await withCheckedContinuation { pending = $0; started?.resume(); started = nil }
    }
    /// 수동 집계 진입·완료 순서 검증용 대기
    func snapshot(home: URL) async -> TokenUsageSnapshot { await todaySnapshot(home: home)! }
    /// 요청 진입까지 대기
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    /// 보류한 집계 전달
    func release() { pending?.resume(returning: value); pending = nil }
}

/// 수집기 시계를 동기적으로 주입하는 테스트용 날짜 저장소
private final class TodayUsageClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    /// 최초 수집 시각 설정
    init(_ value: Date) { self.value = value }
    /// 동시 접근 중 현재 시각 조회
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    /// 다음 수집 시각으로 변경
    func set(_ value: Date) { lock.lock(); defer { lock.unlock() }; self.value = value }
}
