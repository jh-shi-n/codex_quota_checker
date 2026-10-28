// 목적: Claude 캐시·로그 병합과 계정 경계·증분 수집 회귀 검증
// 이용처: 과거 Stats 우선·오늘 로그 집계의 정확성 검증
// 사용방법: swift test --filter ClaudeLocalTokenUsageTests
// 실행 예시: CLAUDE_TOKEN_LIVE_HOME=~/.claude swift test --filter testLiveLocalTokenRead
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 실제 사용자 설정과 분리한 Claude 토큰 집계 검증
final class ClaudeLocalTokenUsageTests: XCTestCase, @unchecked Sendable {
    private let reference = Date(timeIntervalSince1970: 1793156400)

    /// 정리 가능한 독립 설정 폴더 구성
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-tokens-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 검증 기준일의 UTC 응답 시각 구성
    private func stamp(_ offset: Int = 0) -> String {
        ISO8601DateFormatter().string(from: reference.addingTimeInterval(Double(offset)))
    }

    /// 응답 식별자와 숫자 필드만 포함하는 로그 행 구성
    private func row(id: String = "m1", request: String = "r1", at: String? = nil,
                     input: Any = 10, output: Int = 2, cacheRead: Int = 3, cacheWrite: Int = 4,
                     session: String = "s1", sidechain: Bool = false) -> [String: Any] {
        ["type": "assistant", "timestamp": at ?? stamp(), "sessionId": session, "requestId": request,
         "isSidechain": sidechain, "message": ["id": id, "stop_reason": "end_turn",
         "usage": ["input_tokens": input, "output_tokens": output,
                   "cache_read_input_tokens": cacheRead, "cache_creation_input_tokens": cacheWrite]]]
    }

    /// 본 세션·하위 에이전트 로그를 지정 경로에 저장
    @discardableResult
    private func write(_ rows: [[String: Any]], home: URL, path: String = "project/s1.jsonl") throws -> URL {
        let url = home.appendingPathComponent("projects/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
        try data.write(to: url)
        return url
    }

    /// 토큰 정의 버전과 완료 날짜가 포함된 Stats 캐시 저장
    private func cache(home: URL, days: [(String, Int)], semantics: Int = 5) throws {
        try JSONSerialization.data(withJSONObject: ["version": 5, "dailyModelTokensVersion": semantics,
            "lastComputedDate": "2026-10-27", "dailyModelTokens": days.map {
                ["date": $0.0, "tokensByModel": ["claude-opus": $0.1]] as [String: Any]
            }]).write(to: home.appendingPathComponent("stats-cache.json"))
    }

    /// 큰 사용자·요청 기록 이후 정상 토큰 응답의 누락 없는 집계 검증
    func testLargeNonUsageRowsDoNotPreventTokenRefresh() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let large = String(repeating: "x", count: 1_100_000)
        try write([["type": "user", "message": ["content": large]],
                   ["type": "api-request-blob", "data": large], row()], home: home)
        let reader = ClaudeLocalTokenUsageReader(now: { self.reference })
        let result = try await reader.snapshot(home: home, email: nil)
        XCTAssertEqual(result.lifetimeTokens, 19)
        let refreshed = try await reader.snapshot(home: home, email: nil)
        XCTAssertEqual(refreshed.days, result.days)
    }

    /// 캐시 우선·누락 과거·오늘·하위 에이전트의 날짜별 독립 집계 검증
    func testCacheWinsAndLogsFillMissingHistoryAndToday() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try cache(home: home, days: [("2026-10-26", 100), ("2026-10-28", 999)])
        try write([row(at: "2026-10-26T12:00:00Z"), row(id: "past", at: "2026-10-27T12:00:00Z"), row(id: "today")], home: home)
        try write([row(id: "sub", session: "sub")], home: home, path: "project/s1/subagents/agent-sub.jsonl")
        let reader = ClaudeLocalTokenUsageReader(now: { self.reference })
        let result = try await reader.snapshot(home: home, email: "current@example.test")
        XCTAssertEqual(result.days?.map(\.tokens), [100, 19, 38])
        XCTAssertEqual(result.lifetimeTokens, 157)
        XCTAssertEqual(result.peakDailyTokens, 100)
        XCTAssertEqual(result.accountEmail, "current@example.test")
    }

    /// 파일 복사·응답 반복·최종 청크와 다른 요청의 구분 검증
    func testDuplicateResponsesAndFinalChunksAcrossFiles() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let first = row(output: 1)
        try write([first, first, row(at: stamp(1), output: 8), row(request: "different")], home: home)
        try write([row(at: stamp(2), output: 99, sidechain: true)], home: home, path: "copy/s1.jsonl")
        let reader = ClaudeLocalTokenUsageReader(now: { self.reference })
        let result = try await reader.snapshot(home: home, email: nil)
        XCTAssertEqual(result.days?.first?.tokens, 44)
        let repeated = try await reader.snapshot(home: home, email: nil)
        XCTAssertEqual(repeated.days, result.days)
    }

    /// 끝 행 완성·추가 기록·파일 축소 후 재집계 및 중복 제외 검증
    func testAppendPartialLineAndTruncation() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = try write([row()], home: home)
        let reader = ClaudeLocalTokenUsageReader(now: { self.reference })
        let initial = try await reader.snapshot(home: home, email: nil)
        XCTAssertEqual(initial.lifetimeTokens, 19)
        let extra = try JSONSerialization.data(withJSONObject: row(id: "second"))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: extra.prefix(extra.count / 2))
        let partial = try await reader.snapshot(home: home, email: nil)
        XCTAssertEqual(partial.lifetimeTokens, 19)
        try handle.write(contentsOf: extra.suffix(extra.count - extra.count / 2) + Data([10]))
        try handle.close()
        let complete = try await reader.snapshot(home: home, email: nil)
        XCTAssertEqual(complete.lifetimeTokens, 38)
        try write([row(input: 1)], home: home)
        let replaced = try await reader.snapshot(home: home, email: nil)
        XCTAssertEqual(replaced.lifetimeTokens, 10)
    }

    /// UTC 경계·0 토큰·미제공 날짜와 오래된 캐시 정의의 로그 대체 검증
    func testUTCDatesZeroAndLegacyCacheFallback() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try cache(home: home, days: [("2026-10-27", 999)], semantics: 1)
        try write([row(at: "2026-10-28T00:30:00+09:00"),
                   row(id: "zero", at: "2026-10-28T00:30:00Z", input: 0, output: 0, cacheRead: 0, cacheWrite: 0)], home: home)
        let reader = ClaudeLocalTokenUsageReader(now: { self.reference })
        let result = try await reader.snapshot(home: home, email: nil)
        XCTAssertEqual(result.days?.map(\.date), ["2026-10-27", "2026-10-28"])
        XCTAssertEqual(result.days?.map(\.tokens), [19, 0])
    }

    /// 빈 기록을 정상 0으로 채우지 않는 미제공 처리 검증
    func testMissingDataRemainsUnavailableAndCacheOnlyWorks() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let reader = ClaudeLocalTokenUsageReader(now: { self.reference })
        let empty = try await reader.snapshot(home: home, email: nil)
        XCTAssertEqual(empty.days, [])
        XCTAssertNil(empty.lifetimeTokens)
        try cache(home: home, days: [("2026-10-27", 35)])
        let cached = try await reader.snapshot(home: home, email: nil)
        XCTAssertEqual(cached.days?.map(\.tokens), [35])
    }

    /// 읽기 상한 초과·유효하지 않은 숫자의 부분 정상 집계 차단 검증
    func testLimitsAndInvalidCountersFail() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try write([row()], home: home)
        for reader in [ClaudeLocalTokenUsageReader(maximumFiles: 0), ClaudeLocalTokenUsageReader(maximumBytes: 1)] {
            do { _ = try await reader.snapshot(home: home, email: nil); XCTFail("상한 초과 거절 필요") } catch { }
        }
        for bad: Any in [true, -1, 0.5, 9_007_199_254_740_992.0] {
            try write([row(input: bad)], home: home)
            do { _ = try await ClaudeLocalTokenUsageReader(now: { self.reference }).snapshot(home: home, email: nil); XCTFail("숫자 검증 필요") } catch { }
        }
    }

    /// 다른 설정 폴더의 동일 응답 식별자·캐시·집계 분리 검증
    func testHomesRemainIsolated() async throws {
        let first = try home(), second = try home()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        try write([row()], home: first)
        try write([row(input: 20)], home: second)
        let reader = ClaudeLocalTokenUsageReader(now: { self.reference })
        let a = try await reader.snapshot(home: first, email: "a")
        let b = try await reader.snapshot(home: second, email: "b")
        XCTAssertEqual(a.lifetimeTokens, 19)
        XCTAssertEqual(b.lifetimeTokens, 29)
    }

    /// 손상된 Stats 캐시의 로그 대체와 과거 값 중복 가산 방지 검증
    func testCorruptCacheFallsBackWithoutDoubleCounting() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("{incomplete".utf8).write(to: home.appendingPathComponent("stats-cache.json"))
        try write([row(at: "2026-10-27T12:00:00Z")], home: home)
        let reader = ClaudeLocalTokenUsageReader(now: { self.reference })
        let fallback = try await reader.snapshot(home: home, email: nil)
        XCTAssertEqual(fallback.lifetimeTokens, 19)
        try cache(home: home, days: [("2026-10-27", 50)])
        let cached = try await reader.snapshot(home: home, email: nil)
        XCTAssertEqual(cached.lifetimeTokens, 50)
        XCTAssertEqual(cached.source, .claudeLocal)
    }

    /// 불완전 프록시 응답 제외·완료 응답 반영 및 캐시 포함 응답 보존 검증
    func testIncompleteRequestWaitsForCompletedUsage() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        var incomplete = row(output: 0, cacheRead: 0, cacheWrite: 0)
        var message = try XCTUnwrap(incomplete["message"] as? [String: Any])
        message["stop_reason"] = NSNull()
        incomplete["message"] = message
        try write([incomplete], home: home)
        let reader = ClaudeLocalTokenUsageReader(now: { self.reference })
        let waiting = try await reader.snapshot(home: home, email: nil)
        XCTAssertEqual(waiting.days, [])
        try write([incomplete, row()], home: home)
        let complete = try await reader.snapshot(home: home, email: nil)
        XCTAssertEqual(complete.lifetimeTokens, 19)
    }

    /// 폴더 밖 로그 링크 제외 및 줄 크기 상한의 실패 처리 검증
    func testSymlinkScopeAndOversizedLines() async throws {
        let home = try home(), outside = try self.home()
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: outside) }
        try write([row(input: 1000)], home: outside)
        try write([row()], home: home)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("projects/external"), withDestinationURL: outside.appendingPathComponent("projects"))
        let reader = ClaudeLocalTokenUsageReader(now: { self.reference })
        let result = try await reader.snapshot(home: home, email: nil)
        XCTAssertEqual(result.lifetimeTokens, 19)
        do {
            _ = try await ClaudeLocalTokenUsageReader(maximumLineBytes: 10, now: { self.reference }).snapshot(home: home, email: nil)
            XCTFail("과대 행의 부분 집계 차단 필요")
        } catch { }
    }

    /// 조회 중 계정 변경의 결과 차단과 불일치 계정의 사전 거절 검증
    func testProviderChecksIdentityBeforeAndAfterRead() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try write([row()], home: home)
        let executable = home.appendingPathComponent("claude-fixture")
        let script = """
        #!/bin/sh
        if [ -f "$CLAUDE_CONFIG_DIR/checked" ]; then
          printf '%s' '{"loggedIn":true,"email":"b@example.test","orgId":"org","authMethod":"claude.ai"}'
        else
          touch "$CLAUDE_CONFIG_DIR/checked"
          printf '%s' '{"loggedIn":true,"email":"a@example.test","orgId":"org","authMethod":"claude.ai"}'
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let config = AccountConfig(id: "C1", home: home, position: .left)
        let provider = ClaudeTokenUsageProvider(cli: ClaudeCLI(executable: executable), reader: ClaudeLocalTokenUsageReader(now: { self.reference }))
        let result = await provider.fetch(for: config, expectedEmail: "a@example.test")
        guard case .failure(.cancelled) = result else { return XCTFail("계정 변경 결과 차단 필요") }
        let mismatch = await provider.fetch(for: config, expectedEmail: "a@example.test")
        guard case .failure(.cancelled) = mismatch else { return XCTFail("현재 로그인 불일치 차단 필요") }
    }

    /// 이전 공식 수신 캐시와 새 폴더 집계의 영속 출처 구분 검증
    @MainActor
    func testSnapshotProvenanceSurvivesPersistence() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try write([row()], home: home)
        let local = try await ClaudeLocalTokenUsageReader(now: { self.reference }).snapshot(home: home, email: "a")
        let database = SQLiteAccountTokenUsageStore(databaseURL: home.appendingPathComponent("usage.sqlite"))
        try database.save(local, home: home.path)
        let restored = try XCTUnwrap(database.load(home: home.path, now: reference))
        XCTAssertEqual(restored.source, .claudeLocal)
        let store = AccountTokenUsageStore()
        let account = AccountState(id: "C1", email: "a", status: .normal, provider: .claude)
        let legacy = try AccountTokenUsage(result: .object(["summary": .object(["lifetimeTokens": .number(999)])]), accountEmail: "a")
        store.loader = { _ in .success(legacy) }
        await store.refresh(for: account, force: true)?.value
        XCTAssertNil(store.snapshot(for: account))
        store.loader = { _ in .success(local) }
        await store.refresh(for: account, force: true)?.value
        XCTAssertEqual(store.snapshot(for: account)?.lifetimeTokens, 19)
    }

    /// 명시한 실제 폴더의 읽기 전용 집계와 동일 갱신의 안정성 검증
    func testLiveLocalTokenRead() async throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_TOKEN_LIVE_HOME"] else { throw XCTSkip("실제 폴더를 지정한 경우에만 실행") }
        let home = URL(fileURLWithPath: path)
        let reader = ClaudeLocalTokenUsageReader()
        let result = try await reader.snapshot(home: home, email: nil)
        XCTAssertFalse(try XCTUnwrap(result.days).isEmpty)
        XCTAssertGreaterThan(try XCTUnwrap(result.lifetimeTokens), 0)
        let next = try await reader.snapshot(home: home, email: nil)
        XCTAssertGreaterThanOrEqual(next.lifetimeTokens ?? 0, result.lifetimeTokens ?? 0)
        let cli = ClaudeCLI()
        let auth = try await Task.detached { try cli.authentication(home: home) }.value
        let config = AccountConfig(id: "C1", home: home, position: .left)
        let fetched = await ClaudeTokenUsageProvider(cli: cli, reader: reader).fetch(for: config, expectedEmail: auth.email)
        guard case let .success(usage) = fetched else { return XCTFail("실제 계정의 로컬 토큰 연결 실패") }
        XCTAssertEqual(usage.source, .claudeLocal)
        XCTAssertEqual(usage.accountEmail, auth.email)
        XCTAssertGreaterThan(usage.lifetimeTokens ?? 0, 0)
    }
}
