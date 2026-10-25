// 목적: 등록 이력 불일치 복구·명시적 삭제·계정 추가의 설정 보존 검증
// 이용처: 최초 연결 및 재연결 흐름의 회귀 테스트
// 사용방법: swift test --filter AccountRegistrationTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 실제 파일과 격리된 설정 도메인을 통한 계정 등록 상태 검증
@MainActor
final class AccountRegistrationTests: XCTestCase {
    /// 가이드 연결 확인·등록·서비스 재구성 이후 표시 계정 생성과 재실행 유지 검증
    func testVerifiedRegistrationReconfiguresVisibleAccountAndSurvivesRelaunch() async throws {
        let suite = "AccountRegistrationFlow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = AppConfigurationFile(fileURL: root.appendingPathComponent("config.json"))
        let preferences = PreferencesStore(userDefaults: defaults, configurationFile: file)
        let accounts = AccountStore(configs: AccountConfig.accounts(for: preferences.accountPaths), preferencesStore: preferences) { config in
            AccountState(id: config.id, email: "demo@example.com", status: .normal)
        }
        let model = AccountSetupModel(checker: { config in
            AccountState(id: config.id, email: "demo@example.com", status: .normal)
        })
        XCTAssertTrue(preferences.visibleAccounts(accounts.states).isEmpty)
        model.path = root.path
        await model.checkConnection()
        let path = try XCTUnwrap(model.beginRegistration())
        XCTAssertEqual(preferences.registerAccount(path: path), "C1")
        accounts.reconfigure(pathStrings: preferences.accountPaths)
        await accounts.refreshAll()
        XCTAssertEqual(preferences.visibleAccounts(accounts.states).map(\.id), ["C1"])
        XCTAssertEqual(accounts.state(for: "C1")?.email, "demo@example.com")
        XCTAssertFalse(preferences.requiresAccountSetup)
        let restored = PreferencesStore(userDefaults: defaults, configurationFile: file)
        XCTAssertEqual(restored.accountPaths, [root.path, "", "", ""])
        XCTAssertFalse(restored.requiresAccountSetup)
    }

    /// 최초 실행 이후 외부 JSON 완료 기록이 빈 경로의 복구를 막는 현상 재현 검증
    func testExternalJSONRegistrationCannotHideEmptyAccountRecovery() throws {
        try withFixture { defaults, file, root in
            let initial = PreferencesStore(userDefaults: defaults, configurationFile: file)
            initial.updateRefreshInterval(minutes: 17)
            var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file.fileURL)) as? [String: Any])
            document["hasRegisteredAccount"] = true
            let data = try XCTUnwrap(defaults.data(forKey: PreferencesStore.Keys.settingsBundle))
            let bundle = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var settings = try XCTUnwrap(bundle["settings"] as? [String: Any])
            settings["accountPaths"] = [root.path, "", "", ""]
            settings["refreshIntervalMinutes"] = 1
            document["settings"] = settings
            try JSONSerialization.data(withJSONObject: document).write(to: file.fileURL)

            let restored = PreferencesStore(userDefaults: defaults, configurationFile: file)
            XCTAssertTrue(restored.hasRegisteredAccount)
            XCTAssertFalse(restored.hasRegisteredAccounts)
            XCTAssertTrue(restored.needsAccountRecovery)
            XCTAssertTrue(restored.requiresAccountSetup)
            XCTAssertEqual(restored.refreshIntervalMinutes, 17)
            XCTAssertEqual(restored.registerAccount(path: root.path), "C1")
            XCTAssertFalse(restored.requiresAccountSetup)
            let relaunched = PreferencesStore(userDefaults: defaults, configurationFile: file)
            XCTAssertEqual(relaunched.accountPaths, [root.path, "", "", ""])
            XCTAssertFalse(relaunched.needsAccountRecovery)
        }
    }

    /// 명시적 전체 삭제 이후 재실행·재등록의 자동 가이드 분기와 최초 이력 보존 검증
    func testExplicitRemovalSurvivesRelaunchAndAllowsReconnection() throws {
        try withFixture { defaults, file, root in
            let store = PreferencesStore(userDefaults: defaults, configurationFile: file)
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            XCTAssertEqual(store.registerAccount(path: root.path, now: date), "C1")
            XCTAssertTrue(store.updateAccountPaths(["", "", "", ""]))
            let removed = PreferencesStore(userDefaults: defaults, configurationFile: file)
            XCTAssertTrue(removed.accountPathsWereRemoved)
            XCTAssertFalse(removed.requiresAccountSetup)
            XCTAssertFalse(removed.needsAccountRecovery)
            XCTAssertTrue(removed.hasRegisteredAccount)
            XCTAssertEqual(removed.firstAccountRegisteredAt, date)
            XCTAssertEqual(removed.registerAccount(path: root.path), "C1")
            let reconnected = PreferencesStore(userDefaults: defaults, configurationFile: file)
            XCTAssertFalse(reconnected.accountPathsWereRemoved)
            XCTAssertFalse(reconnected.requiresAccountSetup)
            XCTAssertEqual(reconnected.firstAccountRegisteredAt, date)
        }
    }

    /// 삭제 표식이 없는 과거 빈 완료 이력의 복구 분류와 날짜 유지 검증
    func testLegacyEmptyCompletionRequiresRecoveryInsteadOfAssumingRemoval() throws {
        try withFixture { defaults, file, _ in
            _ = PreferencesStore(userDefaults: defaults, configurationFile: file)
            let data = try XCTUnwrap(defaults.data(forKey: PreferencesStore.Keys.settingsBundle))
            var bundle = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            bundle["hasRegisteredAccount"] = true
            bundle.removeValue(forKey: "accountPathsWereRemoved")
            defaults.set(try JSONSerialization.data(withJSONObject: bundle), forKey: PreferencesStore.Keys.settingsBundle)
            let restored = PreferencesStore(userDefaults: defaults, configurationFile: file)
            XCTAssertTrue(restored.needsAccountRecovery)
            XCTAssertTrue(restored.requiresAccountSetup)
            XCTAssertFalse(restored.accountPathsWereRemoved)
        }
    }

    /// 전체 삭제 저장 실패 시 기존 계정·삭제 표식·재실행 상태의 복원 검증
    func testRemovalWriteFailurePreservesRegisteredAccount() throws {
        try withFixture { defaults, file, root in
            let store = PreferencesStore(userDefaults: defaults, configurationFile: file)
            XCTAssertNotNil(store.registerAccount(path: root.path))
            let committed = defaults.data(forKey: PreferencesStore.Keys.settingsBundle)
            try Data("invalid json".utf8).write(to: file.fileURL)
            XCTAssertFalse(store.updateAccountPaths(["", "", "", ""]))
            XCTAssertEqual(store.accountPaths, [root.path, "", "", ""])
            XCTAssertFalse(store.accountPathsWereRemoved)
            XCTAssertEqual(defaults.data(forKey: PreferencesStore.Keys.settingsBundle), committed)
        }
    }

    /// 계정 추가 이후 기존 경로·표시 순서·이름·설정 보존 검증
    func testAddingAccountPreservesExistingSettingsAndUsesEmptySlot() throws {
        try withFixture { defaults, file, root in
            let second = root.appendingPathComponent("second")
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
            let store = PreferencesStore(userDefaults: defaults, configurationFile: file)
            XCTAssertNotNil(store.registerAccount(path: root.path))
            store.updateAccountDisplayNames(["C1": "기존 계정"])
            store.updateAccountDisplayOrder(["C4", "C3", "C2", "C1"])
            store.updateEnabledAccountIDs(["C1"])
            store.updateAutomaticResetPing(true)
            XCTAssertEqual(store.registerAccount(path: second.path), "C2")
            XCTAssertEqual(store.accountPaths, [root.path, second.path, "", ""])
            XCTAssertEqual(store.enabledAccountIDs, ["C1", "C2"])
            XCTAssertEqual(store.accountDisplayNames, ["C1": "기존 계정"])
            XCTAssertEqual(store.accountDisplayOrder, ["C4", "C3", "C2", "C1"])
            XCTAssertTrue(store.automaticResetPingEnabled)
        }
    }

    /// 동일 계정의 심볼릭 링크 재연결에서 슬롯 중복 생성 방지 검증
    func testReconnectingSymlinkReusesSlotAndEnablesVisibility() throws {
        try withFixture { defaults, file, root in
            let account = root.appendingPathComponent("account")
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: account)
            let store = PreferencesStore(userDefaults: defaults, configurationFile: file)
            XCTAssertEqual(store.registerAccount(path: account.path), "C1")
            store.updateEnabledAccountIDs([])
            XCTAssertEqual(store.registerAccount(path: alias.path), "C1")
            XCTAssertEqual(store.accountPaths, [account.path, "", "", ""])
            XCTAssertEqual(store.enabledAccountIDs, ["C1"])
        }
    }

    /// 슬롯 부족 시 저장값 보존 및 기존 계정 재연결 허용 검증
    func testFullSlotsRejectNewAccountWithoutOverwritingExistingAccounts() throws {
        try withFixture { defaults, file, root in
            let folders = try (0..<5).map { index in
                let url = root.appendingPathComponent("account-\(index)")
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return url.path
            }
            let store = PreferencesStore(userDefaults: defaults, configurationFile: file)
            XCTAssertTrue(store.registerAccountPaths(Array(folders.prefix(4))))
            let committed = defaults.data(forKey: PreferencesStore.Keys.settingsBundle)
            XCTAssertNil(store.registerAccount(path: folders[4]))
            XCTAssertEqual(store.accountPaths, Array(folders.prefix(4)))
            XCTAssertEqual(defaults.data(forKey: PreferencesStore.Keys.settingsBundle), committed)
            XCTAssertEqual(store.registerAccount(path: folders[2]), "C3")
        }
    }

    /// 사용자 설정·인증 경로와 분리된 등록 상태 테스트 자료 제공
    private func withFixture(_ body: (UserDefaults, AppConfigurationFile, URL) throws -> Void) throws {
        let suite = "AccountRegistrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(defaults, AppConfigurationFile(fileURL: root.appendingPathComponent("config.json")), root)
    }
}
