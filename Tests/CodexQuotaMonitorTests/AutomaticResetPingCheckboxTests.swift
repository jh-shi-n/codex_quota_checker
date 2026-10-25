// 목적: 상세 화면 자동 전송 체크박스의 실제 클릭·저장·관찰·롤백 검증
// 이용처: 초기화 시간 설정 제목 옆 공통 체크박스의 UI 회귀 테스트
// 사용방법: swift test --filter AutomaticResetPingCheckboxTests
import AppKit
import SwiftUI
import XCTest
@testable import CodexQuotaMonitorKit

/// 실제 SwiftUI 접근성 입력과 격리된 설정으로 체크 표시 일치 검증
@MainActor
final class AutomaticResetPingCheckboxTests: XCTestCase {
    private static var didFinishLaunching = false
    private static var accessibilityAvailable: Bool?
    /// 클릭 결과의 다른 상세 화면 전파·설정 복원·재진입 검증
    func testClicksUpdateBothViewsAndPersistAcrossReopening() async throws {
        try await withFixture { defaults, file, preferences in
            var changes: [Bool] = []
            preferences.onAutomaticResetPingChanged = { changes.append($0) }
            let first = makeWindow(preferences)
            let second = makeWindow(preferences)
            defer { first.close(); second.close() }
            try await assertValue(0, in: first)
            try press(try await checkbox(in: first))
            try await assertValue(1, in: first)
            try await assertValue(1, in: second)
            XCTAssertTrue(preferences.automaticResetPingEnabled)
            XCTAssertEqual(changes, [true])
            let restored = PreferencesStore(userDefaults: defaults, configurationFile: file)
            XCTAssertTrue(restored.automaticResetPingEnabled)
            let reopened = makeWindow(restored)
            defer { reopened.close() }
            try await assertValue(1, in: reopened)
            try press(try await checkbox(in: second))
            try await assertValue(0, in: first)
            try await assertValue(0, in: second)
            XCTAssertEqual(changes, [true, false])
            XCTAssertFalse(PreferencesStore(userDefaults: defaults, configurationFile: file).automaticResetPingEnabled)
        }
    }

    /// 저장 실패 시 표시·설정 복원 및 전송 콜백 차단 후 재시도 검증
    func testFailedSaveRestoresCheckboxAndDoesNotEnableAutomaticPing() async throws {
        try await withFixture { _, file, preferences in
            var changes: [Bool] = []
            preferences.onAutomaticResetPingChanged = { changes.append($0) }
            let window = makeWindow(preferences)
            defer { window.close() }
            let original = try Data(contentsOf: file.fileURL)
            try Data("invalid marker".utf8).write(to: file.fileURL)
            try press(try await checkbox(in: window))
            try await assertValue(0, in: window)
            XCTAssertFalse(preferences.automaticResetPingEnabled)
            XCTAssertNotNil(preferences.persistenceError)
            XCTAssertTrue(changes.isEmpty)
            try original.write(to: file.fileURL)
            try press(try await checkbox(in: window))
            try await assertValue(1, in: window)
            XCTAssertNil(preferences.persistenceError)
            XCTAssertEqual(changes, [true])
        }
    }

    /// 네트워크·실제 사용자 설정을 사용하지 않는 실제 상세 섹션 호스트 생성
    private func makeWindow(_ preferences: PreferencesStore) -> NSWindow {
        makeWindow(content: UsageWindowProbePreferencesView(
            preferences: preferences,
            section: UsageWindowProbeSection(account: AccountState(id: "C1", status: .normal))
        ).padding(16))
    }

    /// 제품 화면과 독립적인 SwiftUI 콘텐츠의 AppKit 수명·호스트 제공
    private func makeWindow<Content: View>(content: Content) -> NSWindow {
        _ = NSApplication.shared
        if !Self.didFinishLaunching {
            NSApp.setActivationPolicy(.accessory)
            NSApp.finishLaunching()
            Self.didFinishLaunching = true
        }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 270),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    /// 기본 SwiftUI Toggle조차 접근성 노드를 제공하지 않는 headless 환경만 구분
    private func requireSwiftUIAccessibility() async throws {
        if Self.accessibilityAvailable == nil {
            let window = makeWindow(content: Toggle("접근성 환경 확인", isOn: .constant(false)).toggleStyle(.checkbox).padding())
            defer { window.close() }
            let view = try XCTUnwrap(window.contentView)
            Self.accessibilityAvailable = false
            for _ in 0..<50 {
                view.layoutSubtreeIfNeeded()
                if !checkboxNodes(view).isEmpty {
                    Self.accessibilityAvailable = true
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try XCTSkipUnless(Self.accessibilityAvailable == true, "기본 SwiftUI Toggle의 접근성 트리 미제공 환경; 실제 클릭 검사는 GUI 환경에서 실행")
    }

    /// SwiftUI 접근성 트리에서 생성된 체크박스 노드 검색
    private func checkboxNodes(_ value: Any, depth: Int = 0) -> [NSObject] {
        guard depth < 20, let node = value as? NSObject else { return [] }
        let role = NSSelectorFromString("accessibilityRole")
        if node.responds(to: role), node.perform(role)?.takeUnretainedValue() as? String == "AXCheckBox" {
            return [node]
        }
        let children = NSSelectorFromString("accessibilityChildren")
        guard node.responds(to: children),
              let values = node.perform(children)?.takeUnretainedValue() as? [Any] else { return [] }
        return values.flatMap { checkboxNodes($0, depth: depth + 1) }
    }

    /// 레이아웃과 접근성 트리 반영 이후 단일 체크박스 반환
    private func checkbox(in window: NSWindow) async throws -> NSObject {
        let view = try XCTUnwrap(window.contentView)
        for _ in 0..<50 {
            view.layoutSubtreeIfNeeded()
            if let node = checkboxNodes(view).first { return node }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(checkboxNodes(view).first)
    }

    /// 실제 체크박스 접근성 press 동작 수행
    private func press(_ node: NSObject) throws {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard node.responds(to: selector) else {
            XCTFail("체크박스 press 동작 부재")
            return
        }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(node.method(for: selector), to: Press.self)
        XCTAssertTrue(action(node, selector))
    }

    /// 저장값과 독립적인 실제 체크 표시의 비동기 갱신 확인
    private func assertValue(_ expected: Int, in window: NSWindow) async throws {
        var actual: Int?
        for _ in 0..<50 {
            let node = try await checkbox(in: window)
            actual = (node.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue() as? NSNumber)?.intValue
            if actual == expected { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(actual, expected)
    }

    /// 사용자 계정·설정과 분리된 파일·도메인 제공 및 정리
    private func withFixture(_ body: @MainActor (UserDefaults, AppConfigurationFile, PreferencesStore) async throws -> Void) async throws {
        _ = NSApplication.shared
        let originalDelegate = NSApp.delegate
        let delegate = CheckboxTestApplicationDelegate()
        NSApp.delegate = delegate
        defer { NSApp.delegate = originalDelegate }
        try await requireSwiftUIAccessibility()
        let suite = "AutomaticResetPingCheckboxTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = AppConfigurationFile(fileURL: root.appendingPathComponent("config.json"))
        let preferences = PreferencesStore(userDefaults: defaults, configurationFile: file,
                                           quotaDatabaseURL: root.appendingPathComponent("quota.sqlite"))
        try await body(defaults, file, preferences)
    }
}

/// UI 회귀 테스트의 마지막 창 닫기 이후 테스트 프로세스 종료 방지
@MainActor
private final class CheckboxTestApplicationDelegate: NSObject, NSApplicationDelegate {
    /// 창 수와 독립적인 테스트 실행 수명 유지
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
