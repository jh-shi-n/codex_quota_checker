// 목적: 일별 집계 장기 보관·보관 기간·주간 차트·설정 호환 검증
// 이용처: 주간 토큰 사용량 기능 회귀 테스트
// 사용방법: swift test --filter WeeklyTokenUsageTests
import AppKit
import Foundation
import SQLite3
import SwiftUI
import XCTest
@testable import CodexQuotaMonitorKit

/// 실제 사용자 데이터와 분리된 장기 집계·주간 화면 검증
@MainActor
final class WeeklyTokenUsageTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    /// 동일 날짜 재집계의 비중복과 수정값 교체 검증
    func testRepeatedDayReplacesTotalsWithoutDoubleCounting() throws {
        try withStore { store, _ in
            let now = date(2026, 10, 23)
            let source = snapshot([point(now, 12)], now: now)
            _ = try store.merge(source, accountID: "C1", homeIdentity: "/fixture", options: .init(), now: now, calendar: calendar)
            let repeated = try store.merge(source, accountID: "C1", homeIdentity: "/fixture", options: .init(), now: now, calendar: calendar)
            XCTAssertEqual(repeated.today.inputTokens, 12)
            let changed = try store.merge(snapshot([point(now, 20)], now: now.addingTimeInterval(1)),
                accountID: "C1", homeIdentity: "/fixture", options: .init(), now: now, calendar: calendar)
            XCTAssertEqual(changed.today.inputTokens, 20)
        }
    }

    /// 재구성된 0 사용량 하향 반영과 미수집 과거 행 보존 검증
    func testCorrectedZeroReplacesOnlyRecordedDays() throws {
        try withStore { store, _ in
            let now = date(2026, 10, 23)
            let yesterday = date(2026, 10, 22)
            _ = try store.merge(snapshot([point(yesterday, 80), point(now, 12)], now: now),
                accountID: "C1", homeIdentity: "/fixture", options: .init(), now: now, calendar: calendar)
            let correction = TokenUsageSnapshot(generatedAt: now.addingTimeInterval(1),
                dailyPoints: [point(yesterday, 0), point(now, 0)], recordedDates: [now])
            let updated = try store.merge(correction, accountID: "C1", homeIdentity: "/fixture",
                options: .init(), now: now.addingTimeInterval(1), calendar: calendar)

            XCTAssertEqual(updated.dailyPoints.first { $0.date == yesterday }?.inputTokens, 80)
            XCTAssertEqual(updated.today.inputTokens, 0)
        }
    }

    /// 재시작과 14일 캐시 만료 후에도 일별 기록을 보존하는지 검증
    func testHistorySurvivesRestartAndSnapshotExpiry() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = date(2026, 10, 23)
        let source = snapshot([point(now, 25)], now: now)
        let home = root.appendingPathComponent("account")
        let historyURL = root.appendingPathComponent("history.sqlite")
        let cacheURL = root.appendingPathComponent("cache.sqlite")
        let first = TokenUsageSnapshotCache(provider: FixedHistoryProvider(value: source), databaseURL: cacheURL,
            accountHomes: ["C1": home], now: { now }, calendar: calendar, historyDatabaseURL: historyURL)
        let initial = await first.refresh(accountID: "C1", home: home)
        XCTAssertEqual(initial.today.inputTokens, 25)
        let later = date(2026, 11, 10)
        let restarted = TokenUsageSnapshotCache(databaseURL: cacheURL, accountHomes: ["C1": home], now: { later },
            calendar: calendar, historyDatabaseURL: historyURL)
        let cached = await restarted.cachedSnapshot(for: "C1")
        let restored = try XCTUnwrap(cached)
        XCTAssertEqual(restored.generatedAt, now)
        XCTAssertEqual(restored.dailyPoints.first { $0.date == now }?.inputTokens, 25)
        XCTAssertEqual(restored.today.inputTokens, 0)
    }

    /// 구형 정규화 경로 데이터베이스를 이관하고 원본 부재·재시작 후 보존 검증
    func testLegacyPathHistoryMigratesAndSurvivesRefreshAndRestart() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("account")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let historyURL = root.appendingPathComponent("history.sqlite")
        let now = date(2026, 10, 23)
        do {
            var pointer: OpaquePointer?
            guard sqlite3_open_v2(historyURL.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
                  let db = pointer else { throw CocoaError(.fileWriteUnknown) }
            defer { sqlite3_close(db) }
            let legacySchema = """
            PRAGMA foreign_keys = ON;
            CREATE TABLE token_history_accounts (
                account_id TEXT PRIMARY KEY, home_identity TEXT NOT NULL, updated_at REAL NOT NULL
            ) WITHOUT ROWID;
            CREATE TABLE token_daily_history (
                account_id TEXT NOT NULL REFERENCES token_history_accounts(account_id) ON DELETE CASCADE,
                day TEXT NOT NULL, input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
                cached_input_tokens INTEGER, session_count INTEGER NOT NULL, updated_at REAL NOT NULL,
                PRIMARY KEY (account_id, day)
            ) WITHOUT ROWID;
            """
            guard sqlite3_exec(db, legacySchema, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            var accountStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO token_history_accounts VALUES (?, ?, ?)", -1,
                                     &accountStatement, nil) == SQLITE_OK,
                  let accountStatement else { throw CocoaError(.fileWriteUnknown) }
            defer { sqlite3_finalize(accountStatement) }
            guard "C1".withCString({ sqlite3_bind_text(accountStatement, 1, $0, -1, transient) }) == SQLITE_OK,
                  home.path.withCString({ sqlite3_bind_text(accountStatement, 2, $0, -1, transient) }) == SQLITE_OK,
                  sqlite3_bind_double(accountStatement, 3, now.timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_step(accountStatement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
            var historyStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO token_daily_history VALUES (?, ?, ?, ?, ?, ?, ?)", -1,
                                     &historyStatement, nil) == SQLITE_OK,
                  let historyStatement else { throw CocoaError(.fileWriteUnknown) }
            defer { sqlite3_finalize(historyStatement) }
            guard "C1".withCString({ sqlite3_bind_text(historyStatement, 1, $0, -1, transient) }) == SQLITE_OK,
                  "2026-10-22".withCString({ sqlite3_bind_text(historyStatement, 2, $0, -1, transient) }) == SQLITE_OK,
                  sqlite3_bind_int64(historyStatement, 3, 123) == SQLITE_OK,
                  sqlite3_bind_int64(historyStatement, 4, 45) == SQLITE_OK,
                  sqlite3_bind_int64(historyStatement, 5, 100) == SQLITE_OK,
                  sqlite3_bind_int64(historyStatement, 6, 1) == SQLITE_OK,
                  sqlite3_bind_double(historyStatement, 7, now.timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_step(historyStatement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
        }

        let cache = TokenUsageSnapshotCache(provider: LocalTokenUsageProvider(calendar: calendar, now: { now }),
            accountHomes: ["C1": home], now: { now }, calendar: calendar, historyDatabaseURL: historyURL,
            sharedHomeResolver: SharedCodexHomeResolver(homeDirectory: root))
        let cached = await cache.cachedSnapshot(for: "C1")
        XCTAssertEqual(cached?.dailyPoints.first { $0.date == date(2026, 10, 22) }?.inputTokens, 123)
        XCTAssertEqual(cached?.last30Days.inputTokens, 123)

        let refreshed = await cache.refresh(accountID: "C1", home: home)
        XCTAssertEqual(refreshed.dailyPoints.first { $0.date == date(2026, 10, 22) }?.inputTokens, 123)
        XCTAssertEqual(refreshed.last30Days.inputTokens, 123)

        let restarted = TokenUsageSnapshotCache(accountHomes: ["C1": home], now: { now }, calendar: calendar,
            historyDatabaseURL: historyURL, sharedHomeResolver: SharedCodexHomeResolver(homeDirectory: root))
        let restored = await restarted.cachedSnapshot(for: "C1")
        XCTAssertEqual(restored?.dailyPoints.first { $0.date == date(2026, 10, 22) }?.inputTokens, 123)
        XCTAssertEqual(restored?.last30Days.inputTokens, 123)
    }

    /// 구형 공유 소스 서명 키를 홈 경로로 이관하며 일별 행을 유지하는지 검증
    func testSourceSignatureHistoryMigratesWithoutDroppingRows() throws {
        try withStore { store, _ in
            let now = date(2026, 10, 23)
            let yesterday = date(2026, 10, 22)
            let oldIdentity = "/fixture#" + String(repeating: "a", count: 64)
            _ = try store.merge(snapshot([point(yesterday, 123)], now: now), accountID: "C1",
                homeIdentity: oldIdentity, options: .init(), now: now, calendar: calendar)

            let migrated = try XCTUnwrap(store.load(accountID: "C1", homeIdentity: "/fixture",
                options: .init(), now: now, calendar: calendar))
            XCTAssertEqual(migrated.dailyPoints.first { $0.date == yesterday }?.inputTokens, 123)
        }
    }

    /// 소유 계정을 확인할 수 없는 갱신이 기존 장기 기록을 덮거나 노출하지 않는지 검증
    func testUnverifiedOwnerPreservesArchivedHistory() throws {
        try withStore { store, _ in
            let now = date(2026, 10, 23)
            let yesterday = date(2026, 10, 22)
            _ = try store.merge(snapshot([point(yesterday, 123)], now: now), accountID: "C1",
                homeIdentity: "/fixture", accountIdentity: "owner-a", options: .init(), now: now, calendar: calendar)
            _ = try store.merge(snapshot([], now: now.addingTimeInterval(1)), accountID: "C1",
                homeIdentity: "/fixture", options: .init(), now: now.addingTimeInterval(1), calendar: calendar)

            let hidden = try store.load(accountID: "C1", homeIdentity: "/fixture",
                options: .init(), now: now, calendar: calendar)
            let preserved = try store.load(accountID: "C1", homeIdentity: "/fixture", accountIdentity: "owner-a",
                options: .init(), now: now, calendar: calendar)
            XCTAssertNil(hidden)
            XCTAssertEqual(preserved?.dailyPoints.first { $0.date == yesterday }?.inputTokens, 123)
        }
    }

    /// 달력 개월 수 경계 포함과 축소 후 실제 삭제·기간 재확대 시 비복원 검증
    func testRetentionCutoffAndPermanentPruning() throws {
        try withStore { store, _ in
            let now = date(2026, 10, 23)
            let cutoff = date(2026, 7, 23)
            let old = date(2026, 7, 22)
            _ = try store.merge(snapshot([point(old, 10), point(cutoff, 20), point(now, 30)], now: now),
                accountID: "C1", homeIdentity: "/fixture", options: .init(), now: now, calendar: calendar)
            try store.prune(options: .init(retentionMonths: 3), now: now, calendar: calendar)
            let restored = try XCTUnwrap(store.load(accountID: "C1", homeIdentity: "/fixture", options: .init(), now: now, calendar: calendar))
            XCTAssertFalse(restored.recordedDates!.contains(old))
            XCTAssertEqual(restored.dailyPoints.first { $0.date == old }?.inputTokens, 0)
            XCTAssertEqual(restored.dailyPoints.first { $0.date == cutoff }?.inputTokens, 20)
        }
    }

    /// 윤년의 1년 포함 경계 367일 및 월말 보정 검증
    func testLeapYearAndCalendarMonthBoundaries() {
        let value = TokenUsageOptions()
        let now = date(2025, 1, 1)
        XCTAssertEqual(value.cutoff(at: now, calendar: calendar), date(2024, 1, 1))
        XCTAssertEqual(TokenUsageOptions(retentionMonths: 3).cutoff(at: date(2024, 5, 31), calendar: calendar), date(2024, 2, 29))
        let count = calendar.dateComponents([.day], from: value.cutoff(at: now, calendar: calendar), to: now).day! + 1
        XCTAssertEqual(count, TokenUsageOptions.maximumHistoryDays)
    }

    /// 계정 경로 교체 시 해당 슬롯만 제거하고 다른 슬롯 보존 검증
    func testAccountReplacementDoesNotExposePreviousHistory() throws {
        try withStore { store, _ in
            let now = date(2026, 10, 23)
            let source = snapshot([point(now, 12)], now: now)
            for id in ["C1", "C2"] {
                _ = try store.merge(source, accountID: id, homeIdentity: "/old", options: .init(), now: now, calendar: calendar)
            }
            _ = try store.merge(snapshot([point(now, 5)], now: now), accountID: "C1", homeIdentity: "/new",
                options: .init(), now: now, calendar: calendar)
            XCTAssertNil(try store.load(accountID: "C1", homeIdentity: "/old", options: .init(), now: now, calendar: calendar))
            XCTAssertEqual(try store.load(accountID: "C1", homeIdentity: "/new", options: .init(), now: now, calendar: calendar)?.today.inputTokens, 5)
            XCTAssertEqual(try store.load(accountID: "C2", homeIdentity: "/old", options: .init(), now: now, calendar: calendar)?.today.inputTokens, 12)
            try store.remove(accountID: "C1")
            XCTAssertNil(try store.load(accountID: "C1", homeIdentity: "/new", options: .init(), now: now, calendar: calendar))
        }
    }

    /// 원본이 없는 과거 날짜의 저장값 보존과 당일 0 재집계 반영 검증
    func testMissingHistoricalRecordsPreserveArchiveAndTodayCanBecomeZero() throws {
        try withStore { store, _ in
            let now = date(2026, 10, 23)
            let yesterday = date(2026, 10, 22)
            _ = try store.merge(snapshot([point(yesterday, 10), point(now, 20)], now: now), accountID: "C1",
                homeIdentity: "/fixture", options: .init(), now: now, calendar: calendar)
            let result = try store.merge(snapshot([], now: now.addingTimeInterval(10)), accountID: "C1",
                homeIdentity: "/fixture", options: .init(), now: now, calendar: calendar)
            XCTAssertEqual(result.dailyPoints.first { $0.date == yesterday }?.inputTokens, 10)
            XCTAssertEqual(result.today.inputTokens, 0)
        }
    }

    /// 실패한 부분 집계가 이전 장기 집계를 덮어쓰지 않는지 검증
    func testUnavailableSnapshotDoesNotReplaceHistory() throws {
        try withStore { store, _ in
            let now = date(2026, 10, 23)
            _ = try store.merge(snapshot([point(now, 12)], now: now), accountID: "C1", homeIdentity: "/fixture",
                options: .init(), now: now, calendar: calendar)
            let failed = TokenUsageSnapshot(generatedAt: now, dailyPoints: [], availability: .unavailable, error: .readLimitExceeded)
            _ = try store.merge(failed, accountID: "C1", homeIdentity: "/fixture", options: .init(), now: now, calendar: calendar)
            XCTAssertEqual(try store.load(accountID: "C1", homeIdentity: "/fixture", options: .init(), now: now, calendar: calendar)?.today.inputTokens, 12)
        }
    }

    /// 연도 경계를 넘는 월~일 구성과 미래 날짜·누계 구분 검증
    func testWeekCrossesYearAndExcludesFutureDays() {
        let now = date(2026, 1, 1)
        let source = snapshot([point(date(2025, 12, 29), 10), point(now, 20)], now: now)
        let week = TokenUsageWeek(snapshot: source, now: now, calendar: calendar)
        XCTAssertEqual(week.start, date(2025, 12, 29))
        XCTAssertEqual(week.end, date(2026, 1, 5))
        XCTAssertEqual(week.days.count, 7)
        XCTAssertEqual(week.total.inputTokens, 30)
        XCTAssertEqual(week.days.filter(\.isFuture).count, 3)
        XCTAssertTrue(week.days.filter(\.isFuture).allSatisfy { $0.point == nil })
    }

    /// 보관되지 않은 날짜와 실제 0 사용량의 구분 및 주간 탐색 제한 검증
    func testMissingDaysAreNotShownAsRecordedZerosAndNavigationClamps() {
        let now = date(2026, 10, 23)
        let source = TokenUsageSnapshot(generatedAt: now,
            dailyPoints: [point(date(2026, 10, 22), 0), point(now, 10)], recordedDates: [now])
        let week = TokenUsageWeek(snapshot: source, now: now, calendar: calendar)
        XCTAssertNil(week.days.first { $0.date == date(2026, 10, 22) }?.point)
        XCTAssertNotNil(week.days.first { $0.date == now }?.point)
        let first = TokenUsageWeek(snapshot: source, now: now, weekOffset: -200, retentionMonths: 3, calendar: calendar)
        XCTAssertFalse(first.canGoBack)
        XCTAssertTrue(first.canGoForward)
        let future = TokenUsageWeek(snapshot: source, now: now, weekOffset: 20, calendar: calendar)
        XCTAssertEqual(future.offset, 0)
    }

    /// 누락 설정 기본값·사용자 선택 재시작 복원 검증
    func testOptionsCompatibilityAndPersistence() throws {
        XCTAssertEqual(try JSONDecoder().decode(TokenUsageOptions.self, from: Data("{}".utf8)), TokenUsageOptions())
        let suite = "WeeklyTokenUsageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(userDefaults: defaults)
        XCTAssertFalse(store.tokenUsageOptions.weeklyChartEnabled)
        let options = TokenUsageOptions(weeklyChartEnabled: true, chartStyle: .line, retentionMonths: 6)
        store.updateTokenUsageOptions(options)
        XCTAssertEqual(PreferencesStore(userDefaults: defaults).tokenUsageOptions, options)
    }

    /// 빌드 폴더 의존 없이 설치 앱의 SQL 리소스를 우선 선택하는지 검증
    func testInstalledResourceBundleProvidesHistorySchema() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let resource = try XCTUnwrap(SQLiteTokenUsageHistoryStore.schemaURL())
        let bundle = root.appendingPathComponent("CodexQuotaMonitor_CodexQuotaMonitorKit.bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let destination = bundle.appendingPathComponent("token-history-schema.sql")
        try FileManager.default.copyItem(at: resource, to: destination)
        let installed = try XCTUnwrap(SQLiteTokenUsageHistoryStore.schemaURL(installedResources: root))
        XCTAssertEqual(installed.standardizedFileURL, destination.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: installed), try Data(contentsOf: resource))
    }

    /// 설정 파일 저장 실패 시 표시·보관 정책의 부분 변경 차단 검증
    func testOptionsRollbackWhenSettingsWriteFails() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "WeeklyTokenUsageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = AppConfigurationFile(fileURL: root.appendingPathComponent("config.json"))
        let store = PreferencesStore(userDefaults: defaults, configurationFile: file)
        try Data("invalid".utf8).write(to: file.fileURL)
        store.updateTokenUsageOptions(.init(weeklyChartEnabled: true, chartStyle: .line, retentionMonths: 3))
        XCTAssertEqual(store.tokenUsageOptions, TokenUsageOptions())
        XCTAssertNotNil(store.persistenceError)
    }

    /// 3개월·6개월 보관 시 원본 수집 범위도 해당 날짜 수로 줄어드는지 검증
    func testCollectionWindowMatchesRetention() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = date(2026, 10, 23)
        let provider = RecordingRangeProvider(now: now, calendar: calendar)
        let home = root.appendingPathComponent("account")
        let cache = TokenUsageSnapshotCache(provider: provider, accountHomes: ["C1": home], now: { now },
            calendar: calendar, historyDatabaseURL: root.appendingPathComponent("history.sqlite"), retentionMonths: 3)
        _ = await cache.refresh(accountID: "C1", home: home)
        let accepted = await cache.setHistoryRetention(months: 6)
        XCTAssertTrue(accepted)
        _ = await cache.refresh(accountID: "C1", home: home)
        let counts = await provider.counts
        XCTAssertEqual(counts, [93, 184])
    }

    /// 보관 정책 변경 이전의 늦은 수집 결과가 삭제한 날짜를 복구하지 못하는지 검증
    func testLateCollectionCannotUndoRetentionChange() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = date(2026, 10, 23)
        let provider = SuspendedHistoryProvider(value: snapshot([point(date(2026, 1, 1), 50)], now: now))
        let home = root.appendingPathComponent("account")
        let cache = TokenUsageSnapshotCache(provider: provider, accountHomes: ["C1": home], now: { now },
            calendar: calendar, historyDatabaseURL: root.appendingPathComponent("history.sqlite"))
        let collection = Task { await cache.refresh(accountID: "C1", home: home) }
        await provider.waitUntilStarted()
        let accepted = await cache.setHistoryRetention(months: 3)
        XCTAssertTrue(accepted)
        await provider.release()
        let stale = await collection.value
        XCTAssertEqual(stale.error, .superseded)
        let cached = await cache.cachedSnapshot(for: "C1")
        XCTAssertNil(cached)
    }

    /// 유효한 기존 14일 캐시를 장기 집계로 1회 이관하고 캐시 파일 없이 복원하는지 검증
    func testLegacySnapshotMigratesToIndependentHistory() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = date(2026, 10, 23)
        let source = snapshot([point(now, 25)], now: now)
        let home = root.appendingPathComponent("account")
        let cacheURL = root.appendingPathComponent("cache.sqlite")
        let historyURL = root.appendingPathComponent("history.sqlite")
        let legacy = TokenUsageSnapshotCache(provider: FixedHistoryProvider(value: source), databaseURL: cacheURL,
            accountHomes: ["C1": home], now: { now }, calendar: calendar)
        _ = await legacy.refresh(accountID: "C1", home: home)
        let upgraded = TokenUsageSnapshotCache(databaseURL: cacheURL, accountHomes: ["C1": home], now: { now },
            calendar: calendar, historyDatabaseURL: historyURL)
        let migrated = await upgraded.cachedSnapshot(for: "C1")
        XCTAssertEqual(migrated?.today.inputTokens, 25)
        try FileManager.default.removeItem(at: cacheURL)
        let archived = TokenUsageSnapshotCache(accountHomes: ["C1": home], now: { now }, calendar: calendar,
            historyDatabaseURL: historyURL)
        let restored = await archived.cachedSnapshot(for: "C1")
        XCTAssertEqual(restored, migrated)
    }

    /// 월 길이가 바뀌어도 메모리 캐시에서 보관 경계를 지난 날짜가 제거되는지 검증
    func testMemorySnapshotRollsCalendarRetentionBoundary() {
        let sourceDate = date(2026, 10, 23)
        let old = date(2026, 7, 31)
        let boundary = date(2026, 8, 1)
        let source = snapshot([point(old, 10), point(boundary, 20)], now: sourceDate)
        let retained = source.retained(months: 3, at: date(2026, 11, 1), calendar: calendar)
        XCTAssertEqual(retained.generatedAt, sourceDate)
        XCTAssertNil(retained.dailyPoints.first { $0.date == old })
        XCTAssertEqual(retained.dailyPoints.first { $0.date == boundary }?.inputTokens, 20)
    }

    /// 실제 막대·선·미로드 화면의 네이티브 렌더 검증
    func testChartStylesAndEmptyStateRender() throws {
        let now = date(2026, 10, 23)
        let source = snapshot((0..<7).map { point(calendar.date(byAdding: .day, value: -$0, to: now)!, Int64(($0 + 1) * 10000)) }, now: now)
        for style in TokenChartStyle.allCases {
            let renderer = ImageRenderer(content: WeeklyTokenUsageChart(snapshot: source,
                options: .init(weeklyChartEnabled: true, chartStyle: style), now: now, calendar: calendar)
                .padding(16).frame(width: 608).background(Color.black).environment(\.colorScheme, .dark))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, 608)
            XCTAssertGreaterThan(image.height, 200)
        }
        let empty = ImageRenderer(content: WeeklyTokenUsageChart(snapshot: nil, options: .init()).frame(width: 608))
        XCTAssertNotNil(empty.cgImage)
    }

    /// 고정 UTC 날짜의 테스트 값 구성
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// 캐시의 중복 합산이 없는 일별 카운터 구성
    private func point(_ day: Date, _ input: Int64) -> TokenUsageDailyPoint {
        TokenUsageDailyPoint(date: day, inputTokens: input, outputTokens: 0, cachedInputTokens: input / 2, sessionCount: input > 0 ? 1 : 0)
    }

    /// 1년 수집 데이터를 사용한 기존 스냅샷 경계 생성
    private func snapshot(_ points: [TokenUsageDailyPoint], now: Date) -> TokenUsageSnapshot {
        TokenUsageAggregator(calendar: calendar, dayCount: TokenUsageOptions.maximumHistoryDays).aggregate(dailyPoints: points, generatedAt: now)
    }

    /// 임시 폴더로 제한한 실제 SQLite 저장 경계 제공
    private func withStore(_ operation: (SQLiteTokenUsageHistoryStore, URL) throws -> Void) throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try operation(SQLiteTokenUsageHistoryStore(databaseURL: root.appendingPathComponent("history.sqlite")), root)
    }

    /// 사용자 인증·기록을 참조하지 않는 격리 폴더 생성
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

/// 정상 고정 집계를 반환하는 로컬 기록 읽기 대역
private struct FixedHistoryProvider: TokenUsageProvider {
    let value: TokenUsageSnapshot
    /// I/O를 수행하지 않는 고정 스냅샷 반환
    func snapshot(home: URL) async -> TokenUsageSnapshot { value }
}

/// 실제 요청받은 수집 범위를 기록하는 날짜 범위 제공자 대역
private actor RecordingRangeProvider: TokenUsageRangeProvider {
    let now: Date
    let calendar: Calendar
    private(set) var counts: [Int] = []

    /// 검증용 시계와 달력 연결
    init(now: Date, calendar: Calendar) { self.now = now; self.calendar = calendar }

    /// 범위 미지정 호출의 구분을 위한 기본 집계 반환
    func snapshot(home: URL) async -> TokenUsageSnapshot {
        TokenUsageAggregator(calendar: calendar).emptySnapshot(generatedAt: now)
    }

    /// 범위를 기록하고 지정한 날짜 수의 정상 집계 반환
    func snapshot(home: URL, historyDayCount: Int) async -> TokenUsageSnapshot {
        counts.append(historyDayCount)
        return TokenUsageAggregator(calendar: calendar, dayCount: historyDayCount).emptySnapshot(generatedAt: now)
    }
}

/// 보관 정책 변경과 수집 완료 순서를 제어하는 제공자 대역
private actor SuspendedHistoryProvider: TokenUsageProvider {
    let value: TokenUsageSnapshot
    private var pending: CheckedContinuation<TokenUsageSnapshot, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?

    /// 반환할 이전 정책의 집계 연결
    init(value: TokenUsageSnapshot) { self.value = value }

    /// 외부 해제까지 실제 수집 완료 보류
    func snapshot(home: URL) async -> TokenUsageSnapshot {
        await withCheckedContinuation { pending in
            self.pending = pending
            startWaiter?.resume()
            startWaiter = nil
        }
    }

    /// 수집 시작까지 비동기 테스트 동기화
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    /// 이전 정책으로 시작한 조회의 늦은 결과 전달
    func release() { pending?.resume(returning: value); pending = nil }
}
