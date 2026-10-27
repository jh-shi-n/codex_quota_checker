// 목적: 이전 JSON 설정·등록 이력의 이관과 원본 보존 검증
// 이용처: UserDefaults 설정 묶음 도입과 이전 파일 호환성 회귀 테스트
// 사용방법: 최종 통합 검증 시 AppConfigurationFileTests 실행
// 실행 예시: swift test --filter AppConfigurationFileTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 인증정보를 제외한 이관 경계와 손상 원본 보존 검증
@MainActor
final class AppConfigurationFileTests: XCTestCase {
    /// 이전 개별 설정의 허용 필드 이관과 등록 이력 전용 JSON 생성 검증
    func testLegacyPreferencesMigrateToBundleAndRegistrationOnlyJSON() throws {
        try withFixture { file, defaults, root in
            defaults.set([root.path, "", "", ""], forKey: PreferencesStore.Keys.accountPaths)
            defaults.set(7, forKey: PreferencesStore.Keys.refreshIntervalMinutes)
            defaults.set("SECRET-MUST-NOT-BE-COPIED", forKey: "CodexQuotaMonitor.accessToken")
            try Data("AUTH-FILE-SECRET".utf8).write(to: root.appendingPathComponent("auth.json"))
            let store = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: root.appendingPathComponent("quota.sqlite"))
            XCTAssertEqual(store.accountPaths, [root.path, "", "", ""])
            XCTAssertEqual(store.refreshIntervalMinutes, 7)
            XCTAssertNil(store.persistenceError)
            let data = try XCTUnwrap(defaults.data(forKey: PreferencesStore.Keys.settingsBundle))
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("SECRET-MUST-NOT-BE-COPIED"))
            XCTAssertFalse(text.contains("accessToken"))
            XCTAssertFalse(text.contains("AUTH-FILE-SECRET"))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["schemaVersion", "settings", "hasRegisteredAccount"])
            let settings = try XCTUnwrap(object["settings"] as? [String: Any])
            XCTAssertEqual(Set(settings.keys), allowedSettingFields)
            let document = try XCTUnwrap(file.read())
            XCTAssertNil(document.settings)
            XCTAssertEqual(document.installation?.hasRegisteredAccount, true)
            XCTAssertNil(document.installation?.firstAccountRegisteredAt)
            XCTAssertFalse(try String(contentsOf: file.fileURL, encoding: .utf8).contains("AUTH-FILE-SECRET"))
            let restored = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: root.appendingPathComponent("quota.sqlite"))
            XCTAssertEqual(restored.accountPaths, store.accountPaths)
            XCTAssertEqual(restored.refreshIntervalMinutes, 7)
            XCTAssertNil(defaults.object(forKey: PreferencesStore.Keys.accountPaths))
            XCTAssertNil(defaults.object(forKey: PreferencesStore.Keys.refreshIntervalMinutes))
            XCTAssertEqual(defaults.string(forKey: "CodexQuotaMonitor.accessToken"), "SECRET-MUST-NOT-BE-COPIED")
        }
    }

    /// 버전 2 JSON의 설정·등록일 이관과 원본 파일 불변 검증
    func testVersionTwoConfigMigratesSettingsAndRegistrationWithoutRewritingSource() throws {
        try withFixture { file, defaults, root in
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            var settings = payload(paths: [root.path, "", "", ""])
            settings.enabledAccountIDs = []
            settings.accountDisplayOrder = ["C4", "C3", "C2", "C1"]
            settings.refreshIntervalMinutes = 13
            settings.resetReminderMinutes = 3
            settings.activityNotificationDurationSeconds = 8
            settings.showAccountLabels = true
            settings.launchAtLogin = true
            settings.accountDisplayNames = ["C1": "업무", "C4": "테스트"]
            try file.saveSettings(settings)
            try file.saveInstallation(InstallationHistory(hasRegisteredAccount: true, firstAccountRegisteredAt: date))
            let original = try Data(contentsOf: file.fileURL)
            let database = root.appendingPathComponent("quota.sqlite")
            let store = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: database)
            XCTAssertEqual(store.accountPaths, settings.accountPaths)
            XCTAssertEqual(store.enabledAccountIDs, [])
            XCTAssertEqual(store.accountDisplayOrder, settings.accountDisplayOrder)
            XCTAssertEqual(store.accountDisplayNames, settings.accountDisplayNames)
            XCTAssertEqual(store.refreshIntervalMinutes, 13)
            XCTAssertEqual(store.resetReminderMinutes, 3)
            XCTAssertEqual(store.activityNotificationDurationSeconds, 8)
            XCTAssertTrue(store.showAccountLabels)
            XCTAssertTrue(store.launchAtLogin)
            XCTAssertTrue(store.hasRegisteredAccount)
            XCTAssertEqual(store.firstAccountRegisteredAt, date)
            XCTAssertNotNil(defaults.data(forKey: PreferencesStore.Keys.settingsBundle))
            XCTAssertEqual(try Data(contentsOf: file.fileURL), original)
            store.updateRefreshInterval(minutes: 17)
            let restored = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: database)
            XCTAssertEqual(restored.refreshIntervalMinutes, 17)
            XCTAssertEqual(restored.accountDisplayNames, settings.accountDisplayNames)
            XCTAssertEqual(restored.firstAccountRegisteredAt, date)
            XCTAssertEqual(try Data(contentsOf: file.fileURL), original)
        }
    }

    /// 이관 완료 묶음의 외부 JSON·개별 키보다 높은 우선순위와 삭제 상태 보존 검증
    func testBundleRemainsAuthoritativeAfterLegacyFileChangesOrCorruption() throws {
        try withFixture { file, defaults, root in
            try file.saveSettings(payload(paths: [root.path, "", "", ""]))
            let database = root.appendingPathComponent("quota.sqlite")
            let store = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: database)
            XCTAssertTrue(store.updateAccountPaths(["", "", "", ""]))
            store.updateRefreshInterval(minutes: 11)
            var staleSettings = payload(paths: [root.path, "", "", ""])
            staleSettings.refreshIntervalMinutes = 99
            try file.saveSettings(staleSettings)
            defaults.set(99, forKey: PreferencesStore.Keys.refreshIntervalMinutes)
            defaults.set([root.path, "", "", ""], forKey: PreferencesStore.Keys.accountPaths)
            let restored = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: database)
            XCTAssertEqual(restored.accountPaths, ["", "", "", ""])
            XCTAssertEqual(restored.refreshIntervalMinutes, 11)
            XCTAssertTrue(restored.hasRegisteredAccount)
            let corrupt = Data("changed externally to invalid json".utf8)
            try corrupt.write(to: file.fileURL)
            let next = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: database)
            XCTAssertEqual(next.accountPaths, ["", "", "", ""])
            XCTAssertEqual(next.refreshIntervalMinutes, 11)
            XCTAssertNotNil(next.persistenceError)
            next.updateShowAccountLabels(true)
            XCTAssertFalse(next.showAccountLabels)
            XCTAssertNotNil(next.persistenceError)
            XCTAssertEqual(try Data(contentsOf: file.fileURL), corrupt)
        }
    }

    /// 버전 1 등록 이력의 이전 파일명 복원과 새 실행 표식 생성 검증
    func testLegacyInstallationFilenameCreatesMarkerWithoutUpdatingLegacyJSON() throws {
        try withFixture { file, defaults, root in
            let legacy = root.appendingPathComponent("installation.json")
            let original = Data(#"{"schemaVersion":1,"firstLaunchedAt":"2026-01-01T00:00:00Z","lastLaunchedAt":"2026-01-02T00:00:00Z","launchCount":4,"hasRegisteredAccount":true,"firstAccountRegisteredAt":"2026-01-01T01:00:00Z"}"#.utf8)
            try original.write(to: legacy)
            let document = try XCTUnwrap(file.read())
            XCTAssertEqual(document.schemaVersion, 2)
            XCTAssertEqual(document.installation?.hasRegisteredAccount, true)
            XCTAssertNil(document.settings)
            let database = root.appendingPathComponent("quota.sqlite")
            let migrated = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: database)
            let date = ISO8601DateFormatter().date(from: "2026-01-01T01:00:00Z")
            XCTAssertTrue(migrated.hasRegisteredAccount)
            XCTAssertEqual(migrated.firstAccountRegisteredAt, date)
            XCTAssertEqual(migrated.accountPaths, ["", "", "", ""])
            let restored = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: database)
            XCTAssertTrue(restored.hasRegisteredAccount)
            XCTAssertEqual(restored.firstAccountRegisteredAt, date)
            XCTAssertEqual(try Data(contentsOf: legacy), original)
            XCTAssertTrue(file.exists)
            XCTAssertEqual(try file.read()?.installation?.firstAccountRegisteredAt, date)
        }
    }

    /// 버전 1 config.json의 알려지지 않은 최초 등록일 유지 검증
    func testVersionOneConfigKeepsUnknownRegistrationDateDuringMigration() throws {
        try withFixture { file, defaults, root in
            let original = Data(#"{"schemaVersion":1,"firstLaunchedAt":"2026-01-01T00:00:00Z","launchCount":4,"hasRegisteredAccount":true}"#.utf8)
            try original.write(to: file.fileURL)
            let store = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: root.appendingPathComponent("quota.sqlite"))
            XCTAssertTrue(store.hasRegisteredAccount)
            XCTAssertNil(store.firstAccountRegisteredAt)
            XCTAssertTrue(store.registerAccountPaths([root.path, "", "", ""], now: Date()))
            XCTAssertNil(store.firstAccountRegisteredAt)
            XCTAssertEqual(try file.read()?.installation?.hasRegisteredAccount, true)
            XCTAssertEqual(try file.read()?.schemaVersion, 2)
        }
    }

    /// config.json 존재 시 이전 installation.json의 내용보다 우선하는 읽기 계약 검증
    func testCurrentConfigTakesPrecedenceOverLegacyInstallationFile() throws {
        try withFixture { file, _, root in
            let settings = payload(paths: [root.path, "", "", ""])
            try file.saveSettings(settings)
            let legacy = root.appendingPathComponent("installation.json")
            let bytes = Data("corrupt legacy file".utf8)
            try bytes.write(to: legacy)
            let document = try XCTUnwrap(file.read())
            XCTAssertEqual(document.settings, settings)
            XCTAssertEqual(document.installation?.hasRegisteredAccount, false)
            XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        }
    }

    /// 손상·미지원·불일치 이력의 개별 키·이전 파일 우회 및 덮어쓰기 차단 검증
    func testCorruptConfigBlocksMigrationAndPreservesAllOriginalSources() throws {
        let cases = [
            Data("invalid json".utf8),
            Data(#"{"schemaVersion":999}"#.utf8),
            Data(#"{"schemaVersion":1}"#.utf8),
            Data(#"{"schemaVersion":2,"installation":{"schemaVersion":999,"hasRegisteredAccount":true}}"#.utf8),
            Data(#"{"schemaVersion":2,"installation":{"schemaVersion":1,"hasRegisteredAccount":false,"firstAccountRegisteredAt":"2026-01-01T00:00:00Z"}}"#.utf8),
        ]
        for bytes in cases {
            try withFixture { file, defaults, root in
                let legacy = root.appendingPathComponent("installation.json")
                let legacyBytes = Data(#"{"schemaVersion":1,"hasRegisteredAccount":true}"#.utf8)
                try legacyBytes.write(to: legacy)
                try bytes.write(to: file.fileURL)
                defaults.set([root.path, "", "", ""], forKey: PreferencesStore.Keys.accountPaths)
                defaults.set(17, forKey: PreferencesStore.Keys.refreshIntervalMinutes)
                XCTAssertThrowsError(try file.read())
                let store = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: root.appendingPathComponent("quota.sqlite"))
                XCTAssertFalse(store.hasRegisteredAccounts)
                XCTAssertFalse(store.hasRegisteredAccount)
                XCTAssertNil(store.firstAccountRegisteredAt)
                XCTAssertEqual(store.refreshIntervalMinutes, 5)
                XCTAssertNotNil(store.persistenceError)
                store.updateRefreshInterval(minutes: 9)
                XCTAssertFalse(store.registerAccountPaths([root.path, "", "", ""]))
                XCTAssertFalse(store.persist())
                XCTAssertEqual(store.refreshIntervalMinutes, 5)
                XCTAssertNil(defaults.object(forKey: PreferencesStore.Keys.settingsBundle))
                XCTAssertEqual(defaults.integer(forKey: PreferencesStore.Keys.refreshIntervalMinutes), 17)
                XCTAssertThrowsError(try file.saveSettings(payload(paths: [root.path, "", "", ""])))
                XCTAssertThrowsError(try file.saveInstallation(InstallationHistory(hasRegisteredAccount: true)))
                XCTAssertEqual(try Data(contentsOf: file.fileURL), bytes)
                XCTAssertEqual(try Data(contentsOf: legacy), legacyBytes)
            }
        }
    }

    /// 이관 어댑터의 섹션 보존·허용 필드·파일 권한 검증
    func testLegacyFileAdapterPreservesOtherSectionAndRestrictsSavedFields() throws {
        try withFixture { file, _, root in
            XCTAssertEqual(AppConfigurationFile.defaultFileURL.lastPathComponent, "config.json")
            XCTAssertNil(try file.read())
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            let history = InstallationHistory(hasRegisteredAccount: true, firstAccountRegisteredAt: date)
            var settings = payload(paths: [root.path, "", "", ""])
            settings.accountDisplayNames = ["C1": "업무", "C3": "Café"]
            settings.automaticResetPingEnabled = true
            settings.automaticRefreshEnabled = false
            settings.notchDisplayStyle = NotchDisplayStyle.verticalBars.rawValue
            try file.saveSettings(settings)
            try file.saveInstallation(history)
            XCTAssertEqual(try file.read()?.settings, settings)
            settings.refreshIntervalMinutes = 17
            try file.saveSettings(settings)
            XCTAssertEqual(try file.read()?.installation, history)
            try file.saveInstallation(history)
            XCTAssertEqual(try file.read()?.settings, settings)
            let data = try Data(contentsOf: file.fileURL)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["settings", "hasRegisteredAccount", "firstAccountRegisteredAt"])
            let savedSettings = try XCTUnwrap(object["settings"] as? [String: Any])
            XCTAssertEqual(Set(savedSettings.keys), allowedSettingFields.subtracting(["tokenUsageOptions"]))
            XCTAssertEqual(savedSettings["accountDisplayNames"] as? [String: String], settings.accountDisplayNames)
            XCTAssertEqual(object["hasRegisteredAccount"] as? Bool, true)
            XCTAssertNotNil(object["firstAccountRegisteredAt"] as? String)
            XCTAssertNil(object["schemaVersion"])
            XCTAssertNil(object["installation"])
            let attributes = try FileManager.default.attributesOfItem(atPath: file.fileURL.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            try file.saveSettings(settings)
            XCTAssertEqual(try Data(contentsOf: file.fileURL), data)
        }
    }

    /// 이전 JSON의 이름 필드 누락과 기존 멤버별 초기화 호출 호환 검증
    func testLegacySettingsWithoutDisplayNamesLoadAndMigrate() throws {
        try withFixture { file, defaults, root in
            let original = payload(paths: [root.path, "", "", ""])
            XCTAssertNil(original.accountDisplayNames)
            let old = Data(#"{"schemaVersion":2,"installation":{"schemaVersion":1,"hasRegisteredAccount":false},"settings":{"accountPaths":["","","",""],"enabledAccountIDs":["C1","C2","C3","C4"],"accountDisplayOrder":["C1","C2","C3","C4"],"refreshIntervalMinutes":7,"resetReminderMinutes":3,"activityNotificationDurationSeconds":8,"showAccountLabels":true,"launchAtLogin":false}}"#.utf8)
            try old.write(to: file.fileURL)
            XCTAssertNil(try file.read()?.settings?.accountDisplayNames)
            let store = PreferencesStore(userDefaults: defaults, configurationFile: file)
            XCTAssertNil(store.persistenceError)
            XCTAssertEqual(store.accountDisplayNames, [:])
            XCTAssertEqual(store.refreshIntervalMinutes, 7)
            XCTAssertEqual(store.resetReminderMinutes, 3)
            XCTAssertTrue(store.showAccountLabels)
            XCTAssertEqual(store.displayName(for: "C4"), "C4")
        }
    }

    /// 이름의 파일 이관·정규화와 이후 설정·등록 이력 저장 시 보존 검증
    func testDisplayNamesNormalizeDuringConfigMigrationAndSurviveBundleReload() throws {
        try withFixture { file, defaults, root in
            var settings = payload(paths: ["", "", "", ""])
            settings.accountDisplayNames = ["C1": " Cafe\u{301}😀 ", "C2": "!", "C3": String(repeating: "가", count: 15), "C5": "제외"]
            try file.saveSettings(settings)
            let store = PreferencesStore(userDefaults: defaults, configurationFile: file)
            let expected = ["C1": "Café", "C3": String(repeating: "가", count: 14)]
            XCTAssertNil(store.persistenceError)
            XCTAssertEqual(store.accountDisplayNames, expected)
            XCTAssertEqual(try file.read()?.settings?.accountDisplayNames, settings.accountDisplayNames)
            store.updateShowAccountLabels(true)
            XCTAssertTrue(store.registerAccountPaths([root.path, "", "", ""]))
            let restored = PreferencesStore(userDefaults: defaults, configurationFile: file)
            XCTAssertEqual(restored.accountDisplayNames, expected)
            XCTAssertEqual(restored.displayName(for: "C2"), "C2")
            XCTAssertTrue(restored.showAccountLabels)
            XCTAssertEqual(try file.read()?.settings?.accountDisplayNames, settings.accountDisplayNames)
        }
    }

    /// 파일 저장 실패 시 이름·묶음의 직전 값 복원과 재시도 검증
    func testDisplayNameWriteFailureRollsBackAndCanRetry() throws {
        try withFixture { file, defaults, _ in
            let store = PreferencesStore(userDefaults: defaults, configurationFile: file)
            store.updateAccountDisplayNames(["C1": "기존"])
            let committed = try XCTUnwrap(defaults.data(forKey: PreferencesStore.Keys.settingsBundle))
            let marker = try Data(contentsOf: file.fileURL)
            let corrupt = Data("invalid marker".utf8)
            try corrupt.write(to: file.fileURL)
            store.updateAccountDisplayNames(["C1": "변경", "C2": "새 이름"])
            XCTAssertNotNil(store.persistenceError)
            XCTAssertEqual(store.accountDisplayNames, ["C1": "기존"])
            XCTAssertEqual(store.displayName(for: "C2"), "C2")
            XCTAssertEqual(defaults.data(forKey: PreferencesStore.Keys.settingsBundle), committed)
            XCTAssertEqual(try Data(contentsOf: file.fileURL), corrupt)
            try marker.write(to: file.fileURL)
            store.updateAccountDisplayNames(["C1": "변경"])
            XCTAssertNil(store.persistenceError)
            XCTAssertEqual(PreferencesStore(userDefaults: defaults, configurationFile: file).accountDisplayNames, ["C1": "변경"])
        }
    }

    /// 최초 실행 표식 저장 실패 시 등록·UserDefaults 갱신 차단과 재시도 검증
    func testMarkerWriteFailureBlocksRegistrationAndCanRetry() throws {
        try withFixture { _, defaults, root in
            let parent = root.appendingPathComponent("blocked")
            let bytes = Data("parent is a file".utf8)
            try bytes.write(to: parent)
            let file = AppConfigurationFile(fileURL: parent.appendingPathComponent("config.json"))
            let store = PreferencesStore(userDefaults: defaults, configurationFile: file)
            XCTAssertNotNil(store.persistenceError)
            XCTAssertFalse(store.registerAccountPaths([root.path, "", "", ""]))
            XCTAssertFalse(store.hasRegisteredAccount)
            XCTAssertNil(store.firstAccountRegisteredAt)
            XCTAssertNil(defaults.data(forKey: PreferencesStore.Keys.settingsBundle))
            XCTAssertEqual(try Data(contentsOf: parent), bytes)
            try FileManager.default.removeItem(at: parent)
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            XCTAssertTrue(store.registerAccountPaths([root.path, "", "", ""], now: date))
            XCTAssertNil(store.persistenceError)
            XCTAssertEqual(try file.read()?.installation?.hasRegisteredAccount, true)
            XCTAssertEqual(try file.read()?.installation?.firstAccountRegisteredAt, date)
            XCTAssertTrue(PreferencesStore(userDefaults: defaults, configurationFile: file).hasRegisteredAccount)
        }
    }

    /// 파일 부재에서 시작 시 미등록 표식 생성과 다음 실행의 미완료 가이드 유지 검증
    func testFirstLaunchCreatesUnregisteredMarkerAndRelaunchUsesExistence() throws {
        try withFixture { file, defaults, _ in
            XCTAssertFalse(file.exists)
            let first = PreferencesStore(userDefaults: defaults, configurationFile: file)
            XCTAssertTrue(first.isFirstLaunch)
            XCTAssertFalse(first.configurationFileWasPresentAtLaunch)
            XCTAssertTrue(first.requiresAccountSetup)
            XCTAssertTrue(file.exists)
            XCTAssertFalse(try XCTUnwrap(file.read()?.installation).hasRegisteredAccount)
            XCTAssertNil(try file.read()?.installation?.firstAccountRegisteredAt)
            let original = try Data(contentsOf: file.fileURL)
            let next = PreferencesStore(userDefaults: defaults, configurationFile: file)
            XCTAssertFalse(next.isFirstLaunch)
            XCTAssertTrue(next.configurationFileWasPresentAtLaunch)
            XCTAssertTrue(next.requiresAccountSetup)
            XCTAssertEqual(try Data(contentsOf: file.fileURL), original)
        }
    }

    /// 등록 완료 값의 동일 저장·전체 삭제 후 유지·파일 유실 시 복원 검증
    func testRegistrationMirrorAndDeletedMarkerPreserveExistingHistory() throws {
        try withFixture { file, defaults, root in
            let store = PreferencesStore(userDefaults: defaults, configurationFile: file)
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            XCTAssertTrue(store.registerAccountPaths([root.path, "", "", ""], now: date))
            XCTAssertEqual(try file.read()?.installation?.firstAccountRegisteredAt, date)
            XCTAssertTrue(store.updateAccountPaths(["", "", "", ""]))
            let original = try Data(contentsOf: file.fileURL)
            store.updateRefreshInterval(minutes: 17)
            store.updateQuotaSnapshot(for: root, snapshot: .init(usedPercent: 12, lastUpdated: Date()))
            XCTAssertEqual(try Data(contentsOf: file.fileURL), original)
            try FileManager.default.removeItem(at: file.fileURL)
            let next = PreferencesStore(userDefaults: defaults, configurationFile: file)
            XCTAssertFalse(next.configurationFileWasPresentAtLaunch)
            XCTAssertFalse(next.isFirstLaunch)
            XCTAssertFalse(next.requiresAccountSetup)
            XCTAssertTrue(next.hasRegisteredAccount)
            XCTAssertEqual(next.firstAccountRegisteredAt, date)
            XCTAssertEqual(try file.read()?.installation?.firstAccountRegisteredAt, date)
        }
    }

    /// 소수 초를 포함한 최초 등록 날짜의 UserDefaults·JSON 간 정밀도 보존 검증
    func testRegistrationDatePrecisionMatchesDefaultsAndJSON() throws {
        try withFixture { file, defaults, root in
            let store = PreferencesStore(userDefaults: defaults, configurationFile: file)
            let date = Date(timeIntervalSinceReferenceDate: 814_000_000.1234567)
            XCTAssertTrue(store.registerAccountPaths([root.path, "", "", ""], now: date))
            XCTAssertEqual(try file.read()?.installation?.firstAccountRegisteredAt, date)
            XCTAssertEqual(PreferencesStore(userDefaults: defaults, configurationFile: file).firstAccountRegisteredAt, date)
            let original = try Data(contentsOf: file.fileURL)
            XCTAssertTrue(store.registerAccountPaths([root.path, "", "", ""], now: date.addingTimeInterval(100)))
            XCTAssertEqual(try Data(contentsOf: file.fileURL), original)
        }
    }

    /// JSON 선행 저장 직후 중단되어도 완료 이력을 미등록 값으로 덮어쓰지 않는지 검증
    func testCompletedMarkerRecoversHistoryAfterInterruptedDefaultsUpdate() throws {
        try withFixture { file, defaults, _ in
            _ = PreferencesStore(userDefaults: defaults, configurationFile: file)
            let date = Date(timeIntervalSinceReferenceDate: 814_000_000.1234567)
            try file.saveInstallation(InstallationHistory(hasRegisteredAccount: true, firstAccountRegisteredAt: date))
            let recovered = PreferencesStore(userDefaults: defaults, configurationFile: file)
            XCTAssertTrue(recovered.hasRegisteredAccount)
            XCTAssertEqual(recovered.firstAccountRegisteredAt, date)
            XCTAssertTrue(recovered.requiresAccountSetup)
            XCTAssertTrue(recovered.needsAccountRecovery)
            XCTAssertEqual(try file.read()?.installation?.firstAccountRegisteredAt, date)
            let restored = PreferencesStore(userDefaults: defaults)
            XCTAssertTrue(restored.hasRegisteredAccount)
            XCTAssertEqual(restored.firstAccountRegisteredAt, date)
        }
    }

    /// 실제 등록일의 최상위 저장·날짜 미상의 명시적 null·이전 버전 제거 검증
    func testRegistrationJSONContainsDateInsteadOfSchemaVersion() throws {
        try withFixture { file, defaults, root in
            let store = PreferencesStore(userDefaults: defaults, configurationFile: file)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file.fileURL)) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["hasRegisteredAccount", "firstAccountRegisteredAt"])
            XCTAssertTrue(object["firstAccountRegisteredAt"] is NSNull)
            let date = Date(timeIntervalSinceReferenceDate: 814_000_000.1234567)
            XCTAssertTrue(store.registerAccountPaths([root.path, "", "", ""], now: date))
            object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file.fileURL)) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["hasRegisteredAccount", "firstAccountRegisteredAt"])
            XCTAssertEqual(object["hasRegisteredAccount"] as? Bool, true)
            XCTAssertTrue((object["firstAccountRegisteredAt"] as? String)?.hasSuffix("Z") == true)
            XCTAssertEqual(try file.read()?.installation?.firstAccountRegisteredAt, date)
        }
    }

    /// 과거 버전 포함 파일을 등록일자 형식으로 이관하고 기존 완료 이력 유지 검증
    func testLegacyVersionedMarkerRewritesAsRegistrationDateRecord() throws {
        try withFixture { file, defaults, _ in
            let old = Data(#"{"schemaVersion":2,"installation":{"schemaVersion":1,"hasRegisteredAccount":true,"firstAccountRegisteredAt":"2026-01-01T01:00:00Z"}}"#.utf8)
            try old.write(to: file.fileURL)
            let store = PreferencesStore(userDefaults: defaults, configurationFile: file)
            XCTAssertTrue(store.hasRegisteredAccount)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file.fileURL)) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["hasRegisteredAccount", "firstAccountRegisteredAt"])
            XCTAssertEqual(object["firstAccountRegisteredAt"] as? String, "2026-01-01T01:00:00.000000000Z")
            XCTAssertTrue(store.requiresAccountSetup)
            XCTAssertTrue(store.needsAccountRecovery)
        }
    }

    /// 저장 허용 목록의 명시적 외부 계약
    private var allowedSettingFields: Set<String> {
        ["accountPaths", "enabledAccountIDs", "accountDisplayOrder", "refreshIntervalMinutes",
         "resetReminderMinutes", "activityNotificationDurationSeconds", "showAccountLabels", "notchDisplayStyle", "launchAtLogin", "accountDisplayNames", "tokenUsageOptions", "automaticResetPingEnabled", "automaticRefreshEnabled"]
    }

    /// 인증정보 없는 이전 설정 파일의 기본 테스트 자료 생성
    private func payload(paths: [String]) -> AppPreferencesPayload {
        AppPreferencesPayload(accountPaths: paths, enabledAccountIDs: ["C1", "C2", "C3", "C4"],
            accountDisplayOrder: ["C1", "C2", "C3", "C4"], refreshIntervalMinutes: 5,
            resetReminderMinutes: 5, activityNotificationDurationSeconds: 3,
            showAccountLabels: false, launchAtLogin: false)
    }

    /// 사용자 설정과 분리된 이전 파일·도메인·폴더 제공 및 정리
    private func withFixture(_ body: (AppConfigurationFile, UserDefaults, URL) throws -> Void) throws {
        let suite = "AppConfigurationFileTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(AppConfigurationFile(fileURL: root.appendingPathComponent("config.json")), defaults, root)
    }
}
