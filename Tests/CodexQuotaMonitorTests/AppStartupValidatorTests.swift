// 목적: 설치 메타데이터·리소스 누락을 초기화 전 오류코드로 검출
// 이용처: 배포 앱 실행 진입점의 복구 가능한 실패 검증
// 사용방법: swift test --filter AppStartupValidatorTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 개발 빌드 리소스에 의존하지 않는 앱 시작 검증
final class AppStartupValidatorTests: XCTestCase {
    /// 정상 설치 리소스의 승인 및 helper 누락 시 APP-003 구분 검증
    func testMissingInstalledResourceHasStartupCodeBeforeModuleFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("CodexQuotaChecker.app")
        let contents = app.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources/CodexQuotaMonitor_CodexQuotaMonitorKit.bundle")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let metadata = ["CFBundleIdentifier": AppUpdateInstaller.bundleIdentifier,
                        "CFBundleExecutable": "CodexQuotaMonitor", "CFBundlePackageType": "APPL",
                        "CFBundleShortVersionString": "0.1.3"]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        for name in ["app-update.sh", "token-history-schema.sql", "menu-bar-template.svg",
                     "probe-airplane.svg", "service-status-smile.svg", "service-status-sad.svg",
                        "settings-tab-general.svg", "settings-tab-accounts.svg",
                        "settings-tab-display.svg", "settings-tab-notifications.svg"] {
            try Data("fixture".utf8).write(to: resources.appendingPathComponent(name))
        }
        let bundle = try XCTUnwrap(Bundle(url: app))
        XCTAssertNoThrow(try AppStartupValidator.validate(bundle: bundle))
        for tab in SettingsTab.allCases {
            let icon = resources.appendingPathComponent(tab.resourceName + ".svg")
            try FileManager.default.removeItem(at: icon)
            XCTAssertThrowsError(try AppStartupValidator.validate(bundle: bundle)) { error in
                XCTAssertEqual((error as? AppOperationFailure)?.code, .startupResources)
            }
            try Data("fixture".utf8).write(to: icon)
        }
        try FileManager.default.removeItem(at: resources.appendingPathComponent("app-update.sh"))
        XCTAssertThrowsError(try AppStartupValidator.validate(bundle: bundle)) { error in
            XCTAssertEqual((error as? AppOperationFailure)?.code, .startupResources)
        }
    }

    /// 식별 정보가 없는 앱 번들을 APP-004로 분류하는지 검증
    func testInvalidAppMetadataHasDistinctStartupCode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let metadata = ["CFBundleIdentifier": "invalid.fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Contents/Info.plist"))
        XCTAssertThrowsError(try AppStartupValidator.validate(bundle: XCTUnwrap(Bundle(url: root)))) { error in
            XCTAssertEqual((error as? AppOperationFailure)?.code, .startupMetadata)
        }
    }
}
