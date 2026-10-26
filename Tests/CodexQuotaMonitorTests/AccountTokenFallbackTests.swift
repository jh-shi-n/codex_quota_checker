// 목적: 서버 우선·당일 로컬 보완과 계정별 결과 격리 검증
// 이용처: 계정 토큰 조회·그래프 회귀 테스트
// 사용방법: swift test --filter AccountTokenFallbackTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

@MainActor
final class AccountTokenFallbackTests: XCTestCase {
    private let now = AccountUsageCalendar.date("2026-10-26")!.addingTimeInterval(3_600)

    /// 당일 미제공 응답 뒤 해당 계정만 수집하고 서버 원본 보존 검증
    func testMissingTodayLoadsLocalAfterServerWithoutChangingServerSnapshot() async throws {
        let reference = now
        let store = AccountTokenUsageStore(now: { reference })
        let account = AccountState(id: "C2", email: "two@example.test", status: .normal)
        let server = try usage([("2026-10-25", 100)])
        let local = localUsage(250)
        var calls: [String] = []
        store.loader = { value in calls.append("server-\(value.id)"); return .success(server) }
        store.localTodayLoader = { value in calls.append("local-\(value.id)"); return local }
        await store.refresh(for: account)?.value
        XCTAssertEqual(calls, ["server-C2", "local-C2"])
        XCTAssertEqual(store.snapshot(for: account), server)
        let model = AccountUsageCalendar(snapshot: store.snapshot(for: account), localToday: store.localTodaySnapshot(for: account), now: now)
        XCTAssertEqual(model.day(at: nil).tokens, 250)
        XCTAssertTrue(model.day(at: nil).isLocal)
        XCTAssertEqual(model.day(at: AccountUsageCalendar.date("2026-10-25")).tokens, 100)
        XCTAssertNil(model.day(at: AccountUsageCalendar.date("2026-10-24")).tokens)
    }

    /// 서버의 실제 0과 갱신된 당일 수치가 로컬 보완보다 우선하는지 검증
    func testServerZeroSkipsLocalAndReplacesEarlierFallback() async throws {
        let reference = now
        let store = AccountTokenUsageStore(now: { reference })
        let account = AccountState(id: "C1", status: .normal)
        let missing = try usage([])
        let zero = try usage([("2026-10-26", 0)])
        let local = localUsage(900)
        var calls = 0
        store.loader = { _ in .success(missing) }
        store.localTodayLoader = { _ in calls += 1; return local }
        await store.refresh(for: account)?.value
        XCTAssertNotNil(store.localTodaySnapshot(for: account))
        store.loader = { _ in .success(zero) }
        await store.refresh(for: account, force: true)?.value
        XCTAssertEqual(calls, 1)
        XCTAssertNil(store.localTodaySnapshot(for: account))
        let model = AccountUsageCalendar(snapshot: zero, localToday: local, now: now)
        XCTAssertEqual(model.day(at: nil).tokens, 0)
        XCTAssertFalse(model.day(at: nil).isLocal)
    }

    /// 서버 실패·일별 필드 미제공도 당일만 보완하고 로컬 실패를 0으로 표시하지 않는지 검증
    func testServerFailureAndUnavailableLocalRemainDistinctFromZero() async throws {
        let reference = now
        let store = AccountTokenUsageStore(now: { reference })
        let account = AccountState(id: "C3", status: .normal)
        let local = localUsage(10)
        store.loader = { _ in .failure(.timeout) }
        store.localTodayLoader = { _ in local }
        await store.refresh(for: account)?.value
        XCTAssertTrue(store.hasFailed(for: account))
        XCTAssertEqual(store.localTodaySnapshot(for: account)?.today.totalTokens, 10)
        store.invalidate(accountID: account.id)
        let unavailable = TokenUsageSnapshot(generatedAt: now, dailyPoints: [], availability: .unavailable)
        store.localTodayLoader = { _ in unavailable }
        await store.refresh(for: account, force: true)?.value
        XCTAssertNil(store.localTodaySnapshot(for: account))
        XCTAssertNil(AccountUsageCalendar(snapshot: nil, localToday: unavailable, now: now).day(at: nil).tokens)
        let absent = try AccountTokenUsage(result: .object(["summary": .object([:])]))
        XCTAssertEqual(AccountUsageCalendar(snapshot: absent, localToday: local, now: now).day(at: nil).tokens, 10)
    }

    /// 이전 날짜·다른 슬롯·변경된 로그인·설정 세대의 로컬값 노출 차단 검증
    func testLocalFallbackIsolatesAccountsAndRejectsYesterday() async throws {
        let reference = now
        let store = AccountTokenUsageStore(now: { reference })
        let one = AccountState(id: "C1", email: "one@example.test", status: .normal)
        let two = AccountState(id: "C2", email: "two@example.test", status: .normal)
        let local = localUsage(123)
        store.localTodayLoader = { _ in local }
        await store.refresh(for: one)?.value
        XCTAssertNil(store.localTodaySnapshot(for: two))
        var changed = one
        changed.email = two.email
        XCTAssertNil(store.localTodaySnapshot(for: changed))
        changed = one
        changed.configurationGeneration += 1
        XCTAssertNil(store.localTodaySnapshot(for: changed))
        store.invalidate(accountID: one.id)
        XCTAssertNil(store.localTodaySnapshot(for: one))
        let yesterday = localUsage(999, at: now.addingTimeInterval(-86_400))
        store.localTodayLoader = { _ in yesterday }
        await store.refresh(for: one)?.value
        XCTAssertNil(store.localTodaySnapshot(for: one))
        XCTAssertNil(AccountUsageCalendar(snapshot: nil, localToday: yesterday, now: now).day(at: nil).tokens)
    }

    /// 한국 자정 이후에도 서버·로컬 모두 동일 UTC 버킷에만 보완되는지 검증
    func testFallbackUsesSameUTCDateAsServer() throws {
        let instant = ISO8601DateFormatter().date(from: "2026-10-26T16:00:00Z")!
        let local = localUsage(77, at: instant)
        let model = AccountUsageCalendar(snapshot: nil, localToday: local, now: instant)
        XCTAssertEqual(AccountUsageCalendar.label(model.today), "2026-10-26")
        XCTAssertEqual(model.day(at: nil).tokens, 77)
        XCTAssertNil(model.day(at: AccountUsageCalendar.date("2026-10-27")).tokens)
    }

    /// 이전 설정의 로컬 읽기가 늦게 끝나도 현재 결과에 반영되지 않는지 검증
    func testInvalidationRejectsLateLocalResult() async throws {
        let reference = now
        let store = AccountTokenUsageStore(now: { reference })
        let account = AccountState(id: "C1", status: .normal)
        let gate = LocalFallbackGate()
        let local = localUsage(500)
        store.localTodayLoader = { _ in await gate.wait(); return local }
        let task = try XCTUnwrap(store.refresh(for: account))
        await gate.waitUntilStarted()
        store.invalidate(accountID: account.id)
        await gate.release()
        await task.value
        XCTAssertNil(store.localTodaySnapshot(for: account))
        XCTAssertFalse(store.isLoading(for: account))
    }

    /// 연결된 경로의 실제 JSONL에서 당일 증가분만 보완하는지 검증
    func testLocalProviderReadsOnlyConnectedHomeAndTodayDelta() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("sessions/2026/10/25")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = [
            #"{"timestamp":"2026-10-25T23:59:00Z","type":"token_count","usage":{"input_tokens":100,"output_tokens":20}}"#,
            #"{"timestamp":"2026-10-26T00:01:00Z","type":"token_count","usage":{"input_tokens":150,"output_tokens":30}}"#
        ].joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: folder.appendingPathComponent("session.jsonl"))
        let reference = now
        let store = AccountTokenUsageStore(now: { reference })
        let account = AccountState(id: "C2", status: .normal)
        store.localTodayLoader = { _ in
            await LocalTokenUsageProvider(calendar: AccountTokenUsage.reportingCalendar,
                now: { reference }, historyDayCount: 1).snapshot(home: directory)
        }
        await store.refresh(for: account)?.value
        let snapshot = try XCTUnwrap(store.localTodaySnapshot(for: account))
        XCTAssertEqual(snapshot.today.totalTokens, 60)
        XCTAssertEqual(snapshot.dailyPoints.count, 1)
        XCTAssertNil(store.localTodaySnapshot(for: AccountState(id: "C3", status: .normal)))
    }

    /// 날짜별 토큰만 포함한 서버 응답 대역 구성
    private func usage(_ days: [(String, Int64)]) throws -> AccountTokenUsage {
        try AccountTokenUsage(result: .object([
            "summary": .object(["lifetimeTokens": .number(1_000)]),
            "dailyUsageBuckets": .array(days.map { date, tokens in
                .object(["startDate": .string(date), "tokens": .number(Double(tokens))])
            })
        ]), fetchedAt: now)
    }

    /// 당일 총량과 조회 시각을 가진 로컬 응답 대역 구성
    private func localUsage(_ tokens: Int64, at date: Date? = nil) -> TokenUsageSnapshot {
        TokenUsageSnapshot(generatedAt: date ?? now, dailyPoints: [], today: TokenUsageTotals(inputTokens: tokens))
    }
}

/// 로컬 응답 완료 시점을 제어하는 취소 비협조형 대역
private actor LocalFallbackGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    /// 명시적 해제까지 로컬 읽기 완료 보류
    func wait() async {
        await withCheckedContinuation { continuation in
            pending = continuation
            observers.forEach { $0.resume() }
            observers.removeAll()
        }
    }

    /// 로컬 읽기 진입 확인
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }

    /// 이전 설정의 로컬 응답 반환 재개
    func release() { pending?.resume(); pending = nil }
}
