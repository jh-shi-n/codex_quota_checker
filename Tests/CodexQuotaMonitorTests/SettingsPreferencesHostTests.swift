// 목적: 기존 설정 창의 실제 선택 표시와 저장소 변경 동기화 검증
// 이용처: 관찰 호스트·통합 차트·계정 표시의 UI 회귀 검사
// 사용방법: swift test --filter SettingsPreferencesHostTests
// 실행 예시: 열린 설정 창에서 외부 차트 변경과 계정 체크 클릭 후 상태 확인
import AppKit
import SwiftUI
import XCTest
@testable import CodexQuotaMonitorKit

/// 테스트 전용 저장소와 실제 SwiftUI 접근성 컨트롤을 이용한 반영 검증
@MainActor
final class SettingsPreferencesHostTests: XCTestCase {
    /// 외부 변경을 동일 창에 반영하고 사용자 체크로 실제 저장하는 경계 검증
    func testExistingSettingsWindowTracksChartAndAccountVisibility() async throws {
        _ = NSApplication.shared
        let originalDelegate = NSApp.delegate
        let delegate = SettingsHostTestDelegate()
        NSApp.delegate = delegate
        defer { NSApp.delegate = originalDelegate }
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let baseline = window(Toggle("환경 확인", isOn: .constant(false)).toggleStyle(.checkbox))
        let available = await node(in: baseline, matching: { self.string($0, "accessibilityRole") == "AXCheckBox" })
        baseline.close()
        try XCTSkipIf(available == nil, "기본 SwiftUI Toggle 접근성 트리 미제공 환경")

        let suite = "SettingsPreferencesHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = AppConfigurationFile(fileURL: root.appendingPathComponent("config.json"))
        let preferences = PreferencesStore(userDefaults: defaults, configurationFile: file)
        let content = SettingsPreferencesHost(preferences: preferences) { store in
            SettingsView(
                refreshIntervalMinutes: Binding(get: { store.refreshIntervalMinutes }, set: { store.updateRefreshInterval(minutes: $0) }),
                accountPaths: Binding(get: { store.accountPaths }, set: { _ in }),
                launchAtLogin: .constant(false),
                showAccountLabels: Binding(get: { store.showAccountLabels }, set: { store.updateShowAccountLabels($0) }),
                enabledAccountIDs: Binding(get: { store.enabledAccountIDs }, set: { store.updateEnabledAccountIDs($0) }),
                accountDisplayOrder: Binding(get: { store.accountDisplayOrder }, set: { store.updateAccountDisplayOrder($0) }),
                accountDisplayNames: Binding(get: { store.accountDisplayNames }, set: { store.updateAccountDisplayNames($0) }),
                tokenUsageOptions: Binding(get: { store.tokenUsageOptions }, set: { store.updateTokenUsageOptions($0) })
            )
        }
        let host = window(content)
        defer { host.close() }
        try await selectTab("표시", in: host)
        try await assertValue("잔디", identifier: "token-usage-display-mode", in: host)
        try await selectTab("계정", in: host)
        let nameCandidate = await node(in: host, matching: { self.string($0, "accessibilityIdentifier") == "account-name-C1" })
        let nameField = try XCTUnwrap(nameCandidate)
        let focusSelector = NSSelectorFromString("setAccessibilityFocused:")
        XCTAssertTrue(nameField.responds(to: focusSelector))
        typealias Focus = @convention(c) (AnyObject, Selector, Bool) -> Void
        let focus = unsafeBitCast(nameField.method(for: focusSelector), to: Focus.self)
        focus(nameField, focusSelector, true)
        let editor = try XCTUnwrap(host.firstResponder as? NSTextView)
        editor.insertText("작성 중 이름", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await assertValue("작성 중 이름", identifier: "account-name-C1", in: host)
        try await selectTab("표시", in: host)
        for mode in [TokenUsageDisplayMode.weeklyLine, .weeklyBar, .heatmap] {
            var options = preferences.tokenUsageOptions
            options.displayMode = mode
            preferences.updateTokenUsageOptions(options)
            try await assertValue(mode.title, identifier: "token-usage-display-mode", in: host)
        }
        try await selectTab("계정", in: host)
        try await assertValue("작성 중 이름", identifier: "account-name-C1", in: host)
        XCTAssertTrue(preferences.accountDisplayNames.isEmpty)
        try await press("apply-account-names", in: host)
        XCTAssertEqual(preferences.accountDisplayNames["C1"], "작성 중 이름")
        preferences.updateEnabledAccountIDs([])
        try await assertValue("0", identifier: "account-visible-C1", in: host)
        let original = try Data(contentsOf: file.fileURL)
        try Data("invalid json".utf8).write(to: file.fileURL)
        try await press("account-visible-C1", in: host)
        try await assertValue("0", identifier: "account-visible-C1", in: host)
        XCTAssertTrue(preferences.enabledAccountIDs.isEmpty)
        XCTAssertNotNil(preferences.persistenceError)
        try original.write(to: file.fileURL)
        try await press("account-visible-C1", in: host)
        try await assertValue("1", identifier: "account-visible-C1", in: host)
        XCTAssertEqual(preferences.enabledAccountIDs, ["C1"])
        XCTAssertEqual(PreferencesStore(userDefaults: defaults).enabledAccountIDs, ["C1"])
    }

    /// 기본 탭 버튼을 눌러 실제 탭 이동과 초안 수명 검증
    private func selectTab(_ title: String, in window: NSWindow) async throws {
        let candidate = await node(in: window, matching: {
            self.string($0, "accessibilityRole") == "AXRadioButton"
                && (self.string($0, "accessibilityTitle") == title || self.string($0, "accessibilityLabel") == title)
        })
        let object = try XCTUnwrap(candidate, title)
        let selector = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(object.responds(to: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(object.method(for: selector), to: Press.self)
        _ = action(object, selector)
        for _ in 0..<50 {
            window.contentView?.layoutSubtreeIfNeeded()
            if string(object, "accessibilityValue") == "1" { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(string(object, "accessibilityValue"), "1", title)
    }

    /// 접근성 컨트롤의 사용자 클릭 동작 수행
    private func press(_ identifier: String, in window: NSWindow) async throws {
        let candidate = await node(in: window, matching: { self.string($0, "accessibilityIdentifier") == identifier })
        let object = try XCTUnwrap(candidate, identifier)
        let selector = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(object.responds(to: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(object.method(for: selector), to: Press.self)
        XCTAssertTrue(action(object, selector), identifier)
    }

    /// 독립 설정 창의 동일 호스트 수명 유지
    private func window<Content: View>(_ content: Content) -> NSWindow {
        let result = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 600, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false)
        result.isReleasedWhenClosed = false
        result.contentView = NSHostingView(rootView: content)
        result.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return result
    }

    /// 지연 생성되는 접근성 노드의 조건 기반 검색
    private func node(in window: NSWindow, matching predicate: (NSObject) -> Bool) async -> NSObject? {
        for _ in 0..<50 {
            window.contentView?.layoutSubtreeIfNeeded()
            if let found = find(window, matching: predicate) { return found }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    /// 순환·과도한 깊이를 제한한 접근성 자식 순회
    private func find(_ value: Any, depth: Int = 0, matching predicate: (NSObject) -> Bool) -> NSObject? {
        guard depth < 40, let object = value as? NSObject else { return nil }
        if predicate(object) { return object }
        let selector = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: selector),
              let children = object.perform(selector)?.takeUnretainedValue() as? [Any] else { return nil }
        for child in children {
            if let found = find(child, depth: depth + 1, matching: predicate) { return found }
        }
        return nil
    }

    /// 접근성의 문자열·숫자 속성을 공통 문자열로 변환
    private func string(_ object: NSObject, _ name: String) -> String? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() else { return nil }
        return String(describing: value)
    }

    /// 저장소 변경 이후 실제 컨트롤 값의 일치 대기
    private func assertValue(_ expected: String, identifier: String, in window: NSWindow) async throws {
        var actual: String?
        for _ in 0..<50 {
            let candidate = await node(in: window, matching: { self.string($0, "accessibilityIdentifier") == identifier })
            let object = try XCTUnwrap(candidate, identifier)
            actual = string(object, "accessibilityValue")
            if actual == expected { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(actual, expected, identifier)
    }
}

/// 마지막 창 종료와 무관한 UI 테스트 프로세스 유지
@MainActor
private final class SettingsHostTestDelegate: NSObject, NSApplicationDelegate {
    /// 설정 창 수명과 독립적인 테스트 종료 정책 제공
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
