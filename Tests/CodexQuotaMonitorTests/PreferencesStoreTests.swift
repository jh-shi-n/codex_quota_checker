// 목적: 설정 묶음의 정규화·복원과 SQLite 할당량 캐시의 독립성 검증
// 이용처: 설정 변경·이관·손상 복구의 회귀 테스트
// 사용방법: 최종 통합 검증 시 PreferencesStoreTests 실행
// 실행 예시: swift test --filter PreferencesStoreTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 격리된 설정 도메인과 임시 DB를 이용한 저장 계약 검증
@MainActor
final class PreferencesStoreTests: XCTestCase {
    /// 새 필드가 없는 이전 묶음에서 자동 전송 기본 꺼짐 복원 검증
    func testLegacyBundleWithoutAutomaticPingKeepsItDisabled() throws {
        try withFixture { defaults, _, database in
            defaults.set(try bundleData(), forKey: PreferencesStore.Keys.settingsBundle)
            let store = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            XCTAssertFalse(store.automaticResetPingEnabled)
            XCTAssertNil(store.persistenceError)
        }
    }

    /// 저장 실패 시 자동 전송 선택 복원과 복구 후 영속 저장 검증
    func testAutomaticPingSettingRollsBackAfterWriteFailure() throws {
        try withFixture { defaults, root, database in
            let file = AppConfigurationFile(fileURL: root.appendingPathComponent("config.json"))
            let store = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: database)
            var changes: [Bool] = []
            store.onAutomaticResetPingChanged = { changes.append($0) }
            let original = try Data(contentsOf: file.fileURL)
            try Data("invalid marker".utf8).write(to: file.fileURL)
            store.updateAutomaticResetPing(true)
            XCTAssertFalse(store.automaticResetPingEnabled)
            XCTAssertNotNil(store.persistenceError)
            XCTAssertTrue(changes.isEmpty)
            try original.write(to: file.fileURL)
            store.updateAutomaticResetPing(true)
            XCTAssertTrue(store.automaticResetPingEnabled)
            XCTAssertNil(store.persistenceError)
            XCTAssertEqual(changes, [true])
            store.updateAutomaticResetPing(true)
            XCTAssertEqual(changes, [true])
            let restored = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: database)
            XCTAssertTrue(restored.automaticResetPingEnabled)
        }
    }

    /// 최초 설정의 기본값과 미등록 상태 복원 검증
    func testMissingValuesRestoreDefaultsFromSettingsBundle() throws {
        try withFixture { defaults, root, database in
            let store = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            XCTAssertEqual(store.refreshIntervalMinutes, 5)
            XCTAssertEqual(store.resetReminderMinutes, 5)
            XCTAssertFalse(store.automaticResetPingEnabled)
            XCTAssertEqual(store.accountPaths, ["", "", "", ""])
            XCTAssertEqual(store.enabledAccountIDs, PreferencesStore.defaultEnabledAccountIDs)
            XCTAssertEqual(store.accountDisplayOrder, PreferencesStore.defaultAccountDisplayOrder)
            XCTAssertEqual(store.accountDisplayNames, [:])
            XCTAssertEqual(store.displayName(for: "C1"), "C1")
            XCTAssertFalse(store.launchAtLogin)
            XCTAssertFalse(store.showAccountLabels)
            XCTAssertEqual(store.activityNotificationDurationSeconds, 3)
            XCTAssertFalse(store.hasRegisteredAccount)
            XCTAssertNil(store.firstAccountRegisteredAt)
            XCTAssertNotNil(defaults.data(forKey: PreferencesStore.Keys.settingsBundle))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("config.json").path))
            let restored = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            XCTAssertEqual(restored.accountPaths, store.accountPaths)
            XCTAssertFalse(restored.hasRegisteredAccount)
            XCTAssertNil(restored.persistenceError)
        }
    }

    /// 모든 설정의 단일 묶음 복원과 이전 개별 키 제거 검증
    func testEverySettingRoundTripsThroughBundleInsteadOfIndividualKeys() throws {
        try withFixture { defaults, root, database in
            let paths = try (1...4).map { try makeDirectory(at: root.appendingPathComponent("c\($0)")).path }
            let store = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            XCTAssertTrue(store.updateAccountPaths(paths))
            store.updateEnabledAccountIDs(["C3", "C1"])
            store.updateAccountDisplayOrder(["C4", "C3", "C2", "C1"])
            store.updateAccountDisplayNames(["C1": " 업무 🌟 ", "C3": "Cafe\u{301}", "C4": "  "])
            store.updateRefreshInterval(minutes: 7)
            store.updateResetReminder(minutes: 3)
            store.updateAutomaticResetPing(true)
            store.updateActivityNotificationDuration(seconds: 8)
            store.updateShowAccountLabels(true)
            store.updateLaunchAtLogin(true)
            let registrationDate = try XCTUnwrap(store.firstAccountRegisteredAt)

            defaults.set(99, forKey: PreferencesStore.Keys.refreshIntervalMinutes)
            defaults.set(["/stale", "", "", ""], forKey: PreferencesStore.Keys.accountPaths)
            defaults.set(["C1": "stale"], forKey: PreferencesStore.Keys.accountDisplayNames)
            let restored = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            XCTAssertEqual(restored.accountPaths, paths)
            XCTAssertEqual(restored.enabledAccountIDs, ["C3", "C1"])
            XCTAssertEqual(restored.accountDisplayOrder, ["C4", "C3", "C2", "C1"])
            XCTAssertEqual(restored.accountDisplayNames, ["C1": "업무", "C3": "Café"])
            XCTAssertEqual(restored.displayName(for: "C4"), "C4")
            XCTAssertEqual(restored.refreshIntervalMinutes, 7)
            XCTAssertEqual(restored.resetReminderMinutes, 3)
            XCTAssertTrue(restored.automaticResetPingEnabled)
            XCTAssertEqual(restored.activityNotificationDurationSeconds, 8)
            XCTAssertTrue(restored.launchAtLogin)
            XCTAssertTrue(restored.showAccountLabels)
            XCTAssertTrue(restored.hasRegisteredAccount)
            XCTAssertEqual(restored.firstAccountRegisteredAt, registrationDate)
            for key in legacySettingKeys {
                XCTAssertNil(defaults.object(forKey: key), key)
            }
        }
    }

    /// 활성 ID의 공백·대소문자·중복 정리와 전체 숨김 상태 복원 검증
    func testEnabledAccountIDsNormalizeAndEmptySelectionPersistsInBundle() throws {
        try withFixture { defaults, _, database in
            let store = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            store.updateEnabledAccountIDs([" c3 ", "C1", "c3", "unknown", "C2"])
            XCTAssertEqual(store.enabledAccountIDs, ["C3", "C1", "C2"])
            XCTAssertEqual(PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database).enabledAccountIDs, ["C3", "C1", "C2"])
            store.updateEnabledAccountIDs([])
            XCTAssertEqual(PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database).enabledAccountIDs, [])
        }
    }

    /// 표시 순서의 중복 제거와 누락 ID 보충·복원 검증
    func testDisplayOrderNormalizesToCompletePermutationInBundle() throws {
        try withFixture { defaults, _, database in
            let store = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            store.updateAccountDisplayOrder(["c3", "C3", "unknown", " C1 "])
            XCTAssertEqual(store.accountDisplayOrder, ["C3", "C1", "C2", "C4"])
            XCTAssertEqual(PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database).accountDisplayOrder, store.accountDisplayOrder)
            store.updateAccountDisplayOrder([])
            XCTAssertEqual(PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database).accountDisplayOrder, PreferencesStore.defaultAccountDisplayOrder)
        }
    }

    /// NFC·Swift Character 기준 길이 제한과 금지 기호·이모지 제거 검증
    func testAccountDisplayNamePolicyNormalizesUnicodeAndFiltersInvalidCharacters() {
        XCTAssertEqual(AccountDisplayName.maxLength, 14)
        XCTAssertEqual(AccountDisplayName.normalized("  Cafe\u{301} 한글 １２Ⅳ  "), "Café 한글 １２Ⅳ")
        XCTAssertEqual(AccountDisplayName.normalized(" A\tB\nC\u{00A0}D\u{200D}E\u{202E}F!_-+©😀👩‍💻♥️ "), "ABCDEF")
        XCTAssertEqual(AccountDisplayName.normalized("क\u{093F}a\u{20DD}"), "क\u{093F}a\u{20DD}")
        XCTAssertEqual(AccountDisplayName.normalized("1️⃣"), "1")
        for character in ["가", "e\u{301}", "क\u{093F}", "a\u{20DD}"] {
            let normalized = AccountDisplayName.normalized(String(repeating: character, count: 15))
            XCTAssertEqual(normalized.count, 14)
            XCTAssertEqual(normalized.unicodeScalars.map(\.value),
                String(repeating: character, count: 14).precomposedStringWithCanonicalMapping.unicodeScalars.map(\.value))
        }
        XCTAssertEqual(AccountDisplayName.normalized("가"), "가")
        XCTAssertEqual(AccountDisplayName.normalized("abcdefghijklmn  o"), "abcdefghijklmn")
        XCTAssertEqual(AccountDisplayName.normalized("abcdefghijklm n"), "abcdefghijklm")
        XCTAssertEqual(AccountDisplayName.resolved(nil, slotID: "C1"), "C1")
        XCTAssertEqual(AccountDisplayName.resolved(" 💥!\n ", slotID: "C2"), "C2")
        XCTAssertEqual(AccountDisplayName.resolved(" 이름 ", slotID: "C3"), "이름")
    }

    /// 새 필드가 없는 기존 묶음의 정상 로드와 빈 이름 맵 기본값 검증
    func testLegacyBundleWithoutDisplayNamesRestoresEmptyMap() throws {
        try withFixture { defaults, _, database in
            defaults.set(try bundleData(), forKey: PreferencesStore.Keys.settingsBundle)
            defaults.set(["C1": "stale"], forKey: PreferencesStore.Keys.accountDisplayNames)
            let store = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            XCTAssertNil(store.persistenceError)
            XCTAssertEqual(store.accountDisplayNames, [:])
            XCTAssertEqual(store.displayName(for: "C3"), "C3")
            XCTAssertEqual(store.accountPaths, ["", "", "", ""])
            XCTAssertNil(defaults.object(forKey: PreferencesStore.Keys.accountDisplayNames))
            XCTAssertEqual(PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database).accountDisplayNames, [:])
        }
    }

    /// 이름 변경의 슬롯 식별자·경로·표시 순서·정상 캐시 보존 검증
    func testDisplayNameUpdatesPreserveAccountConfigurationAndQuotaCache() throws {
        try withFixture { defaults, root, database in
            let store = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            XCTAssertTrue(store.updateAccountPaths([root.path, "", "", ""]))
            let snapshot = PreferencesStore.QuotaSnapshot(usedPercent: 25, lastUpdated: Date())
            store.updateQuotaSnapshot(for: root, snapshot: snapshot)
            let paths = store.accountPaths
            let ids = store.enabledAccountIDs
            let order = store.accountDisplayOrder
            let registrationDate = store.firstAccountRegisteredAt
            store.updateAccountDisplayNames(["C1": "작업", "C5": "제외", "c2": "제외", root.path: "제외"])
            XCTAssertEqual(store.accountDisplayNames, ["C1": "작업"])
            XCTAssertEqual(store.accountPaths, paths)
            XCTAssertEqual(store.enabledAccountIDs, ids)
            XCTAssertEqual(store.accountDisplayOrder, order)
            XCTAssertEqual(store.firstAccountRegisteredAt, registrationDate)
            XCTAssertEqual(store.quotaSnapshot(for: root), snapshot)
            let restored = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            XCTAssertEqual(restored.displayName(for: "C1"), "작업")
            XCTAssertEqual(restored.quotaSnapshot(for: root), snapshot)
            store.updateAccountDisplayNames(["C1": "😀! "])
            XCTAssertEqual(store.accountDisplayNames, [:])
            XCTAssertEqual(PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database).displayName(for: "C1"), "C1")
        }
    }

    /// 미설정·비활성·알 수 없는 계정의 제외와 표시 순서 검증
    func testVisibleAccountsFiltersUnconfiguredAndDisabledStatesInSelectedOrder() throws {
        try withFixture { defaults, _, database in
            let store = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            store.updateEnabledAccountIDs(["C1", "C3", "C4"])
            store.updateAccountDisplayOrder(["C4", "C1", "C3", "C2"])
            let states = [
                AccountState(id: "C1", status: .normal),
                AccountState(id: "C2", status: .normal),
                AccountState(id: "C3", status: .notConfigured),
                AccountState(id: "C4", status: .normal),
                AccountState(id: "unknown", status: .normal),
            ]
            XCTAssertEqual(store.visibleAccounts(states).map(\.id), ["C4", "C1"])
            store.updateEnabledAccountIDs([])
            XCTAssertTrue(store.visibleAccounts(states).isEmpty)
        }
    }

    /// 경계 밖 간격·알림 시간과 잘못된 사전 알림 선택값의 묶음 복원 검증
    func testNumericSettingsNormalizeBeforeBundlePersistence() throws {
        try withFixture { defaults, _, database in
            let store = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            for (input, expected) in [(0, 5), (-1, 5), (61, 60), (7, 7)] {
                store.updateRefreshInterval(minutes: input)
                XCTAssertEqual(store.refreshIntervalMinutes, expected)
                XCTAssertEqual(PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database).refreshIntervalMinutes, expected)
            }
            for (input, expected) in [(0, 1), (11, 10), (7, 7)] {
                store.updateActivityNotificationDuration(seconds: input)
                XCTAssertEqual(PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database).activityNotificationDurationSeconds, expected)
            }
            for (input, expected) in [(0, 0), (3, 3), (10, 10), (4, 5)] {
                store.updateResetReminder(minutes: input)
                XCTAssertEqual(PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database).resetReminderMinutes, expected)
            }
            store.updateShowAccountLabels(true)
            store.updateShowAccountLabels(false)
            XCTAssertFalse(PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database).showAccountLabels)
        }
    }

    /// 비정규 개별 설정의 정리와 유효한 묶음 재실행 후 이전 키 제거 검증
    func testLegacyValuesNormalizeAndMigrateToBundle() throws {
        try withFixture { defaults, root, database in
            defaults.set(0, forKey: PreferencesStore.Keys.refreshIntervalMinutes)
            defaults.set(4, forKey: PreferencesStore.Keys.resetReminderMinutes)
            defaults.set([" ~/one/../account ", "", "~/two", ""], forKey: PreferencesStore.Keys.accountPaths)
            defaults.set([" c3 ", "C3", "unknown"], forKey: PreferencesStore.Keys.enabledAccountIDs)
            defaults.set(["c2", "invalid", "C2"], forKey: PreferencesStore.Keys.accountDisplayOrder)
            defaults.set(["C1": " 팀😀 ", "C2": "💥!", "C3": String(repeating: "가", count: 15), "C5": "제외"],
                forKey: PreferencesStore.Keys.accountDisplayNames)
            defaults.set("yes", forKey: PreferencesStore.Keys.launchAtLogin)
            defaults.set("yes", forKey: PreferencesStore.Keys.showAccountLabels)
            defaults.set(99, forKey: PreferencesStore.Keys.activityNotificationDurationSeconds)
            let store = PreferencesStore(userDefaults: defaults, homeDirectory: root, quotaDatabaseURL: database)
            let expectedPaths = [root.appendingPathComponent("account").path, "", root.appendingPathComponent("two").path, ""]
            XCTAssertEqual(store.accountPaths, expectedPaths)
            XCTAssertEqual(store.refreshIntervalMinutes, 5)
            XCTAssertEqual(store.resetReminderMinutes, 5)
            XCTAssertEqual(store.enabledAccountIDs, ["C3"])
            XCTAssertEqual(store.accountDisplayOrder, ["C2", "C1", "C3", "C4"])
            XCTAssertEqual(store.accountDisplayNames, ["C1": "팀", "C3": String(repeating: "가", count: 14)])
            XCTAssertFalse(store.launchAtLogin)
            XCTAssertFalse(store.showAccountLabels)
            XCTAssertEqual(store.activityNotificationDurationSeconds, 10)
            XCTAssertTrue(store.hasRegisteredAccount)
            XCTAssertNil(store.firstAccountRegisteredAt)
            let restored = PreferencesStore(userDefaults: defaults, homeDirectory: root, quotaDatabaseURL: database)
            XCTAssertEqual(restored.accountPaths, expectedPaths)
            XCTAssertEqual(restored.enabledAccountIDs, ["C3"])
            XCTAssertEqual(restored.accountDisplayOrder, ["C2", "C1", "C3", "C4"])
            XCTAssertEqual(restored.accountDisplayNames, store.accountDisplayNames)
            XCTAssertEqual(restored.activityNotificationDurationSeconds, 10)
            for key in legacySettingKeys {
                XCTAssertNil(defaults.object(forKey: key), key)
            }
        }
    }

    /// 잘못된 이전 슬롯 수의 기본값 복원과 명시적 빈 슬롯 보존 검증
    func testPathNormalizationUsesDefaultsOnlyForMissingOrWrongSizedCollection() {
        let home = URL(fileURLWithPath: "/tmp/injected-home", isDirectory: true)
        let fallback = ["~/default", "", "", ""]
        let expectedFallback = [home.appendingPathComponent("default").path, "", "", ""]
        XCTAssertEqual(PreferencesStore.normalizedPaths(nil, defaults: fallback, homeDirectory: home), expectedFallback)
        XCTAssertEqual(PreferencesStore.normalizedPaths(["/only-one"], defaults: fallback, homeDirectory: home), expectedFallback)
        XCTAssertEqual(PreferencesStore.normalizedPaths(["~", " ~/one/../two ", "", "/tmp/four"], defaults: fallback, homeDirectory: home), [home.path, home.appendingPathComponent("two").path, "", "/tmp/four"])
        XCTAssertEqual(PreferencesStore.normalizedPaths(nil, defaults: ["/only-one"], homeDirectory: home), ["", "", "", ""])
    }

    /// 이전 저장값의 잘못된 슬롯 수와 자료형의 기본값 이관 검증
    func testInvalidLegacyTypesAndPathCountRestoreCanonicalDefaults() throws {
        try withFixture { defaults, _, database in
            defaults.set(["/only-one"], forKey: PreferencesStore.Keys.accountPaths)
            defaults.set("invalid", forKey: PreferencesStore.Keys.refreshIntervalMinutes)
            defaults.set("invalid", forKey: PreferencesStore.Keys.enabledAccountIDs)
            defaults.set("invalid", forKey: PreferencesStore.Keys.accountDisplayOrder)
            defaults.set("invalid", forKey: PreferencesStore.Keys.activityNotificationDurationSeconds)
            let store = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            let restored = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            XCTAssertEqual(store.accountPaths, ["", "", "", ""])
            XCTAssertEqual(restored.accountPaths, store.accountPaths)
            XCTAssertEqual(restored.refreshIntervalMinutes, 5)
            XCTAssertEqual(restored.enabledAccountIDs, PreferencesStore.defaultEnabledAccountIDs)
            XCTAssertEqual(restored.accountDisplayOrder, PreferencesStore.defaultAccountDisplayOrder)
            XCTAssertEqual(restored.activityNotificationDurationSeconds, 3)
            XCTAssertFalse(restored.hasRegisteredAccount)
        }
    }

    /// 경로 검증 결과별 안내 구분과 잘못된 슬롯 포함 시 전체 변경 거부 검증
    func testInvalidPathRejectsWholeUpdateWithoutChangingBundle() throws {
        try withFixture { defaults, root, database in
            let original = try makeDirectory(at: root.appendingPathComponent("original")).path
            let replacement = try makeDirectory(at: root.appendingPathComponent("replacement")).path
            let regularFile = root.appendingPathComponent("regular.txt")
            try Data().write(to: regularFile)
            let unreadable = root.appendingPathComponent("unreadable").path
            let missing = root.appendingPathComponent("missing").path
            let fileSystem = AccountPathFileSystem { path in
                if path == unreadable {
                    return AccountPathFileMetadata(exists: true, isDirectory: true, isReadable: false)
                }
                return AccountPathFileSystem.live.metadata(path)
            }
            let store = PreferencesStore(userDefaults: defaults, fileSystem: fileSystem, quotaDatabaseURL: database)
            XCTAssertTrue(store.registerAccountPaths([original, "", "", ""], enabledIDs: ["C1"]))
            let committed = try XCTUnwrap(defaults.data(forKey: PreferencesStore.Keys.settingsBundle))
            XCTAssertEqual(store.validateAccountPath(""), .empty)
            XCTAssertEqual(store.validateAccountPath(replacement), .valid)
            for (path, validation) in [(missing, AccountPathValidation.missing), (regularFile.path, .notDirectory), (unreadable, .unreadable)] {
                XCTAssertEqual(store.validateAccountPath(path), validation)
                XCTAssertFalse(store.updateAccountPaths([replacement, path, "", ""]))
                XCTAssertEqual(store.accountPaths, [original, "", "", ""])
                XCTAssertEqual(store.enabledAccountIDs, ["C1"])
                XCTAssertEqual(defaults.data(forKey: PreferencesStore.Keys.settingsBundle), committed)
                XCTAssertNotNil(store.persistenceError)
            }
            XCTAssertFalse(store.updateAccountPaths([replacement]))
            XCTAssertEqual(defaults.data(forKey: PreferencesStore.Keys.settingsBundle), committed)
            XCTAssertTrue(store.updateAccountPaths([replacement, "", "", ""]))
            XCTAssertNil(store.persistenceError)
            XCTAssertEqual(PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database).accountPaths, [replacement, "", "", ""])
        }
    }

    /// 접근 불가로 바뀐 저장 경로의 보존과 다른 슬롯·설정 편집 허용 검증
    func testInaccessiblePersistedPathsSurviveRestoreAndUnrelatedUpdates() throws {
        try withFixture { defaults, root, database in
            let paths = try (1...3).map { try makeDirectory(at: root.appendingPathComponent("account-\($0)")).path } + [""]
            let initial = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            XCTAssertTrue(initial.updateAccountPaths(paths))
            let date = initial.firstAccountRegisteredAt
            let missing = paths[0]
            let regular = paths[1]
            let unreadable = paths[2]
            let unavailable = AccountPathFileSystem { path in
                if path == missing { return AccountPathFileMetadata(exists: false, isDirectory: false, isReadable: false) }
                if path == regular { return AccountPathFileMetadata(exists: true, isDirectory: false, isReadable: true) }
                if path == unreadable { return AccountPathFileMetadata(exists: true, isDirectory: true, isReadable: false) }
                return AccountPathFileSystem.live.metadata(path)
            }
            let restored = PreferencesStore(userDefaults: defaults, fileSystem: unavailable, quotaDatabaseURL: database)
            XCTAssertEqual(restored.accountPaths, paths)
            XCTAssertNil(restored.persistenceError)
            restored.updateRefreshInterval(minutes: 13)
            let fourth = try makeDirectory(at: root.appendingPathComponent("fourth")).path
            XCTAssertTrue(restored.updateAccountPaths(Array(paths.prefix(3)) + [fourth]))
            let next = PreferencesStore(userDefaults: defaults, fileSystem: unavailable, quotaDatabaseURL: database)
            XCTAssertEqual(next.accountPaths, Array(paths.prefix(3)) + [fourth])
            XCTAssertEqual(next.refreshIntervalMinutes, 13)
            XCTAssertEqual(next.firstAccountRegisteredAt, date)
        }
    }

    /// 편집 취소·빈 슬롯·잘못된 경로의 일괄 검증 동작 보존 검증
    func testAccountPathDraftCommitsOnlyValidatedChanges() throws {
        try withFixture { _, root, _ in
            let original = try makeDirectory(at: root.appendingPathComponent("account")).path
            let configured = [original, "", "", ""]
            var draft = SettingsView.AccountPathsDraft(paths: configured)
            draft.replace(at: 0, text: "")
            XCTAssertEqual(configured[0], original)
            draft = SettingsView.AccountPathsDraft(paths: configured)
            XCTAssertEqual(draft.paths, configured)
            draft.replace(at: 0, text: root.path)
            draft.replace(at: 1, text: root.appendingPathComponent("missing").path)
            XCTAssertNil(draft.commit(validator: AccountPathValidator()))
            XCTAssertEqual(draft.validationErrors[1], .missing)
            draft.replace(at: 1, text: "")
            XCTAssertEqual(draft.commit(validator: AccountPathValidator()), [root.path, "", "", ""])
            draft.replace(at: 0, text: "")
            XCTAssertEqual(draft.commit(validator: AccountPathValidator()), ["", "", "", ""])
        }
    }

    /// 접근 불가인 기존 C1 경로를 유지한 C2 편집과 변경 경로의 검증 유지
    func testAccountPathDraftAllowsEditingAnotherSlotWhileOriginalPathIsInaccessible() throws {
        try withFixture { _, root, _ in
            let offline = root.appendingPathComponent("offline").path
            let replacement = root.appendingPathComponent("replacement").path
            let missing = root.appendingPathComponent("missing").path
            let fileSystem = AccountPathFileSystem { path in
                if path == offline {
                    return AccountPathFileMetadata(exists: true, isDirectory: true, isReadable: false)
                }
                return AccountPathFileMetadata(exists: path == replacement, isDirectory: true, isReadable: true)
            }
            let validator = AccountPathValidator(homeDirectory: root, fileSystem: fileSystem)
            XCTAssertEqual(validator.validate(offline), .unreadable)
            var draft = SettingsView.AccountPathsDraft(paths: [offline, "", "", ""])
            draft.replace(at: 0, text: " ~/offline ")
            draft.replace(at: 1, text: replacement)
            XCTAssertEqual(draft.commit(validator: validator), [offline, replacement, "", ""])
            XCTAssertTrue(draft.validationErrors.isEmpty)
            draft.replace(at: 0, text: missing)
            XCTAssertNil(draft.commit(validator: validator))
            XCTAssertEqual(draft.validationErrors[0], .missing)
        }
    }

    /// 손상·미지원·불일치 묶음의 이전 키 우회 및 덮어쓰기 차단 검증
    func testCorruptBundlePreservesOriginalAndRejectsAllSettingsChanges() throws {
        let cases: [Any] = [
            "wrong type",
            Data("broken json".utf8),
            try bundleData(schemaVersion: 999),
            try bundleData(paths: ["/only-one"]),
            try bundleData(paths: ["/registered", "", "", ""], registered: false),
            try bundleData(registered: false, date: Date()),
        ]
        for raw in cases {
            try withFixture { defaults, root, database in
                defaults.set(raw, forKey: PreferencesStore.Keys.settingsBundle)
                defaults.set([root.path, "", "", ""], forKey: PreferencesStore.Keys.accountPaths)
                defaults.set(17, forKey: PreferencesStore.Keys.refreshIntervalMinutes)
                let store = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
                XCTAssertEqual(store.accountPaths, ["", "", "", ""])
                XCTAssertEqual(store.refreshIntervalMinutes, 5)
                XCTAssertFalse(store.hasRegisteredAccount)
                XCTAssertNotNil(store.persistenceError)
                let mutations = defaults.mutationKeys
                XCTAssertFalse(store.registerAccountPaths([root.path, "", "", ""], enabledIDs: ["C2"]))
                XCTAssertFalse(store.updateAccountPaths([root.path, "", "", ""]))
                store.updateRefreshInterval(minutes: 9)
                store.updateResetReminder(minutes: 0)
                store.updateEnabledAccountIDs([])
                store.updateAccountDisplayOrder(["C4"])
                store.updateAccountDisplayNames(["C1": "차단"])
                store.updateLaunchAtLogin(true)
                store.updateShowAccountLabels(true)
                store.updateActivityNotificationDuration(seconds: 9)
                XCTAssertFalse(store.persist())
                XCTAssertEqual(store.accountPaths, ["", "", "", ""])
                XCTAssertEqual(store.refreshIntervalMinutes, 5)
                XCTAssertEqual(store.resetReminderMinutes, 5)
                XCTAssertEqual(store.enabledAccountIDs, PreferencesStore.defaultEnabledAccountIDs)
                XCTAssertEqual(store.accountDisplayOrder, PreferencesStore.defaultAccountDisplayOrder)
                XCTAssertEqual(store.accountDisplayNames, [:])
                XCTAssertFalse(store.launchAtLogin)
                XCTAssertFalse(store.showAccountLabels)
                XCTAssertEqual(store.activityNotificationDurationSeconds, 3)
                XCTAssertEqual(defaults.mutationKeys, mutations)
                if let bytes = raw as? Data {
                    XCTAssertEqual(defaults.data(forKey: PreferencesStore.Keys.settingsBundle), bytes)
                } else {
                    XCTAssertEqual(defaults.string(forKey: PreferencesStore.Keys.settingsBundle), raw as? String)
                }
                XCTAssertEqual(defaults.integer(forKey: PreferencesStore.Keys.refreshIntervalMinutes), 17)
            }
        }
    }

    /// 등록된 정규 경로의 최근 할당량·보조 창·리셋권 SQLite 복원 검증
    func testQuotaSnapshotRoundTripsThroughSQLiteByNormalizedRegisteredPath() throws {
        try withFixture { defaults, root, database in
            let account = try makeDirectory(at: root.appendingPathComponent("account-one"))
            let now = Date()
            let snapshot = PreferencesStore.QuotaSnapshot(
                usedPercent: 23, remainingPercent: 77, resetAt: now.addingTimeInterval(300),
                secondaryUsedPercent: 61, secondaryRemainingPercent: 39,
                secondaryResetAt: now.addingTimeInterval(3_600),
                resetCredits: RateLimitResetCredits(availableCount: 1, credits: [
                    .init(id: "credit-one", expiresAt: now.addingTimeInterval(7_200)),
                ]), lastUpdated: now
            )
            let store = PreferencesStore(userDefaults: defaults, homeDirectory: root, quotaDatabaseURL: database)
            XCTAssertTrue(store.updateAccountPaths([account.path, "", "", ""]))
            store.updateQuotaSnapshot(for: " ~/account-one/../account-one ", snapshot: snapshot)
            XCTAssertNil(store.cacheError)
            XCTAssertEqual(try SQLiteQuotaSnapshotStore(databaseURL: database).load()[account.path], snapshot)
            let restored = PreferencesStore(userDefaults: defaults, homeDirectory: root, quotaDatabaseURL: database)
            XCTAssertEqual(restored.quotaSnapshot(for: account), snapshot)
            XCTAssertNil(restored.quotaSnapshot(for: root.appendingPathComponent("account-two")))
            XCTAssertNil(defaults.object(forKey: PreferencesStore.Keys.lastSuccessfulQuotaSnapshots))
            let settingsText = String(decoding: try XCTUnwrap(defaults.data(forKey: PreferencesStore.Keys.settingsBundle)), as: UTF8.self)
            XCTAssertFalse(settingsText.contains("usedPercent"))
            XCTAssertFalse(settingsText.contains("credit-one"))
        }
    }

    /// 캐시 갱신·조회·정리·삭제의 설정 묶음 쓰기 방지 검증
    func testQuotaCacheOperationsDoNotWriteSettings() throws {
        try withFixture { defaults, root, database in
            let store = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            XCTAssertTrue(store.updateAccountPaths([root.path, "", "", ""]))
            let bundle = try XCTUnwrap(defaults.data(forKey: PreferencesStore.Keys.settingsBundle))
            let mutations = defaults.mutationKeys
            let snapshot = PreferencesStore.QuotaSnapshot(usedPercent: 130, remainingPercent: -10, secondaryUsedPercent: -5, secondaryRemainingPercent: 200, lastUpdated: Date())
            store.updateQuotaSnapshot(for: root, snapshot: snapshot)
            XCTAssertEqual(store.quotaSnapshot(for: root)?.usedPercent, 100)
            XCTAssertEqual(store.quotaSnapshot(for: root)?.remainingPercent, 0)
            XCTAssertEqual(store.quotaSnapshot(for: root)?.secondaryUsedPercent, 0)
            XCTAssertEqual(store.quotaSnapshot(for: root)?.secondaryRemainingPercent, 100)
            store.updateQuotaSnapshot(for: "  ", snapshot: snapshot)
            store.cleanupQuotaSnapshots()
            store.removeQuotaSnapshot(for: root)
            XCTAssertNil(store.quotaSnapshot(for: root))
            XCTAssertTrue(try SQLiteQuotaSnapshotStore(databaseURL: database).load().isEmpty)
            XCTAssertEqual(defaults.data(forKey: PreferencesStore.Keys.settingsBundle), bundle)
            XCTAssertEqual(defaults.mutationKeys, mutations)
            XCTAssertNil(store.persistenceError)
            XCTAssertNil(store.cacheError)
        }
    }

    /// 기존 캐시의 정규 경로 이관·SQLite 최신값 우선·재실행 후 원본 키 제거 검증
    func testLegacyQuotaMigrationPreservesExistingSQLiteSnapshots() throws {
        try withFixture { defaults, root, database in
            let first = try makeDirectory(at: root.appendingPathComponent("one"))
            let second = try makeDirectory(at: root.appendingPathComponent("two"))
            let now = Date()
            let old = PreferencesStore.QuotaSnapshot(usedPercent: 10, lastUpdated: now.addingTimeInterval(-60))
            let current = PreferencesStore.QuotaSnapshot(usedPercent: 30, lastUpdated: now)
            let migrated = PreferencesStore.QuotaSnapshot(remainingPercent: 45, lastUpdated: now)
            defaults.set([first.path, second.path, "", ""], forKey: PreferencesStore.Keys.accountPaths)
            defaults.set(try JSONEncoder().encode(["~/one": old, "~/two": migrated]), forKey: PreferencesStore.Keys.lastSuccessfulQuotaSnapshots)
            try SQLiteQuotaSnapshotStore(databaseURL: database).save([first.path: current])
            let store = PreferencesStore(userDefaults: defaults, homeDirectory: root, quotaDatabaseURL: database)
            XCTAssertEqual(store.quotaSnapshot(for: first), current)
            XCTAssertEqual(store.quotaSnapshot(for: second), migrated)
            let restored = PreferencesStore(userDefaults: defaults, homeDirectory: root, quotaDatabaseURL: database)
            XCTAssertEqual(restored.quotaSnapshot(for: first), current)
            XCTAssertEqual(restored.quotaSnapshot(for: second), migrated)
            XCTAssertNil(defaults.object(forKey: PreferencesStore.Keys.lastSuccessfulQuotaSnapshots))
            XCTAssertNil(restored.cacheError)
        }
    }

    /// 이관 DB 접근 실패 시 기존 캐시 원본 유지와 일반 설정 변경 허용 검증
    func testFailedQuotaMigrationRetainsLegacyBytesWithoutBlockingSettings() throws {
        try withFixture { defaults, root, _ in
            let blocked = root.appendingPathComponent("blocked")
            try Data("parent is a file".utf8).write(to: blocked)
            let database = blocked.appendingPathComponent("quota.sqlite")
            let bytes = try JSONEncoder().encode([root.path: PreferencesStore.QuotaSnapshot(usedPercent: 20, lastUpdated: Date())])
            defaults.set([root.path, "", "", ""], forKey: PreferencesStore.Keys.accountPaths)
            defaults.set(bytes, forKey: PreferencesStore.Keys.lastSuccessfulQuotaSnapshots)
            let store = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            XCTAssertNotNil(store.cacheError)
            XCTAssertNil(store.persistenceError)
            store.updateRefreshInterval(minutes: 11)
            let restored = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            XCTAssertEqual(restored.refreshIntervalMinutes, 11)
            XCTAssertEqual(defaults.data(forKey: PreferencesStore.Keys.lastSuccessfulQuotaSnapshots), bytes)
            XCTAssertNotNil(restored.cacheError)
            XCTAssertNil(restored.persistenceError)
        }
    }

    /// 손상 DB 원본 보존과 캐시 저장 재시도 시 설정 쓰기 방지 검증
    func testCorruptSQLiteReportsCacheErrorAndRecoversWithoutSettingsWrites() throws {
        try withFixture { defaults, root, database in
            let store = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            XCTAssertTrue(store.updateAccountPaths([root.path, "", "", ""]))
            try FileManager.default.removeItem(at: database)
            let corrupt = Data("not a sqlite database".utf8)
            try corrupt.write(to: database)
            let snapshot = PreferencesStore.QuotaSnapshot(usedPercent: 42, lastUpdated: Date())
            let mutations = defaults.mutationKeys
            store.updateQuotaSnapshot(for: root, snapshot: snapshot)
            XCTAssertNotNil(store.cacheError)
            XCTAssertNil(store.persistenceError)
            XCTAssertEqual(try Data(contentsOf: database), corrupt)
            XCTAssertEqual(defaults.mutationKeys, mutations)
            try FileManager.default.removeItem(at: database)
            store.updateQuotaSnapshot(for: root, snapshot: snapshot)
            XCTAssertNil(store.cacheError)
            XCTAssertEqual(defaults.mutationKeys, mutations)
            XCTAssertEqual(PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database).quotaSnapshot(for: root), snapshot)
        }
    }

    /// 만료·미등록 캐시 삭제와 최신 64행 유지 검증
    func testSQLiteCleanupRemovesExpiredAndUnregisteredRowsAndCapsHistory() throws {
        try withFixture { _, root, database in
            let now = Date()
            let paths = (0..<66).map { root.appendingPathComponent("account-\($0)").path }
            let snapshots = Dictionary(uniqueKeysWithValues: paths.enumerated().map { index, path in
                (path, PreferencesStore.QuotaSnapshot(usedPercent: Double(index), lastUpdated: now.addingTimeInterval(-Double(index))))
            })
            let expiredPath = root.appendingPathComponent("expired").path
            let orphanPath = root.appendingPathComponent("orphan").path
            let sqlite = SQLiteQuotaSnapshotStore(databaseURL: database)
            try sqlite.save(snapshots, now: now)
            try sqlite.save([
                expiredPath: .init(lastUpdated: now.addingTimeInterval(-SQLiteQuotaSnapshotStore.lifetime)),
                orphanPath: .init(lastUpdated: now),
            ], now: now)
            try sqlite.cleanup(registeredPaths: Set(paths + [expiredPath]), now: now)
            let retained = try sqlite.load(now: now)
            XCTAssertEqual(Set(retained.keys), Set(paths.prefix(64)))
            XCTAssertNil(retained[expiredPath])
            XCTAssertNil(retained[orphanPath])
            try sqlite.remove(path: paths[0])
            XCTAssertNil(try sqlite.load(now: now)[paths[0]])
        }
    }

    /// 묶음 복원 이후 제거 대상인 기존 개별 설정 키 목록
    private var legacySettingKeys: [String] {
        [PreferencesStore.Keys.accountPaths, PreferencesStore.Keys.enabledAccountIDs,
         PreferencesStore.Keys.accountDisplayOrder, PreferencesStore.Keys.accountDisplayNames, PreferencesStore.Keys.refreshIntervalMinutes,
         PreferencesStore.Keys.resetReminderMinutes, PreferencesStore.Keys.automaticResetPingEnabled, PreferencesStore.Keys.launchAtLogin,
         PreferencesStore.Keys.showAccountLabels, PreferencesStore.Keys.activityNotificationDurationSeconds]
    }

    /// 손상 조건만 바꿀 수 있는 외부 저장 형식의 테스트 자료 생성
    private func bundleData(schemaVersion: Int = 1, paths: [String] = ["", "", "", ""], registered: Bool = false, date: Date? = nil) throws -> Data {
        var object: [String: Any] = [
            "schemaVersion": schemaVersion,
            "hasRegisteredAccount": registered,
            "settings": [
                "accountPaths": paths, "enabledAccountIDs": ["C1", "C2", "C3", "C4"],
                "accountDisplayOrder": ["C1", "C2", "C3", "C4"], "refreshIntervalMinutes": 5,
                "resetReminderMinutes": 5, "activityNotificationDurationSeconds": 3,
                "showAccountLabels": false, "launchAtLogin": false,
            ],
        ]
        if let date { object["firstAccountRegisteredAt"] = date.timeIntervalSinceReferenceDate }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// 사용자 설정과 실제 계정에서 분리된 임시 도메인·폴더·DB 제공 및 정리
    private func withFixture(_ body: (RecordingUserDefaults, URL, URL) throws -> Void) throws {
        let suite = "PreferencesStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(RecordingUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = try makeDirectory(at: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
        defer { try? FileManager.default.removeItem(at: root) }
        try body(defaults, root, root.appendingPathComponent("quota.sqlite"))
    }

    /// 검증용 계정 폴더 생성과 실패 전파
    private func makeDirectory(at directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// 캐시 처리 중 UserDefaults 쓰기 호출 감지용 격리 저장소
private final class RecordingUserDefaults: UserDefaults, @unchecked Sendable {
    private let mutationLock = NSLock()
    private var recordedKeys: [String] = []

    /// 동일 데이터 재저장까지 포함하는 쓰기·삭제 호출 목록의 안전한 복사
    var mutationKeys: [String] {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        return recordedKeys
    }

    /// 설정값 쓰기 호출 기록 후 실제 테스트 도메인 반영
    override func set(_ value: Any?, forKey defaultName: String) {
        mutationLock.lock()
        recordedKeys.append(defaultName)
        mutationLock.unlock()
        super.set(value, forKey: defaultName)
    }

    /// 이전 설정 키 삭제 호출 기록 후 실제 테스트 도메인 반영
    override func removeObject(forKey defaultName: String) {
        mutationLock.lock()
        recordedKeys.append(defaultName)
        mutationLock.unlock()
        super.removeObject(forKey: defaultName)
    }
}
