// 목적: 계정 토큰 사용량 안내 버튼의 실제 접근성 입력과 팝오버 수명 검증
// 이용처: 계정 상세 토큰 사용량 영역의 UI 회귀 테스트
// 사용방법: swift test --filter TokenUsageInformationButtonTests
// 실행 예시: 접근성 버튼 입력 후 안내 팝오버 표시·닫기 확인
import AppKit
import SwiftUI
import XCTest
@testable import CodexQuotaMonitorKit

/// 실제 SwiftUI 호스트와 접근성 트리를 이용한 안내 버튼 동작 검증
@MainActor
final class TokenUsageInformationButtonTests: XCTestCase {
    /// 접근성 버튼으로 안내를 열고 닫아 부모 상세 호스트 유지 및 조회 부작용 부재 확인
    func testInformationButtonPresentsAndDismissesHelpWithoutRefreshingAccount() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let accessibilityAvailable = await hasSwiftUIButtonAccessibility()
        try XCTSkipUnless(accessibilityAvailable, "기본 SwiftUI Button 접근성 press 미제공 환경; GUI 환경에서 실제 클릭 검사")

        let store = AccountTokenUsageStore(databaseURL: nil)
        var serverLoads = 0
        var localLoads = 0
        store.loader = { _ in serverLoads += 1; return .failure(.notConfigured) }
        store.localTodayLoader = { _ in localLoads += 1; return nil }
        let account = AccountState(id: "C1", status: .notConfigured)
        let host = makeWindow(content: AccountTokenUsageView(account: account, store: store).padding(16))
        defer { host.close() }

        let button = await node(in: host) {
            self.string($0, "accessibilityIdentifier") == "account-token-usage-info-button"
        }
        let infoButton = try XCTUnwrap(button)
        XCTAssertEqual(string(infoButton, "accessibilityRole"), "AXButton")
        try press(infoButton)
        try await assertPopoverText("토큰 사용량 안내", excluding: host)
        try await assertPopoverText("오늘 사용량: 서버 값을 우선하고", excluding: host)
        XCTAssertTrue(host.isVisible)

        try press(infoButton)
        try await assertPopoverText("토큰 사용량 안내", excluding: host, present: false)
        XCTAssertTrue(host.isVisible)

        try press(infoButton)
        try await assertPopoverText("토큰 사용량 안내", excluding: host)
        XCTAssertEqual(serverLoads, 0)
        XCTAssertEqual(localLoads, 0)
        XCTAssertTrue(host.isVisible)
    }

    /// 독립 SwiftUI 창 생성
    private func makeWindow<Content: View>(content: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    /// 기본 SwiftUI Button에서 접근성 노드와 press 동작 제공 여부 확인
    private func hasSwiftUIButtonAccessibility() async -> Bool {
        let window = makeWindow(content: Button("환경 확인") {}.accessibilityIdentifier("swiftui-button-probe"))
        defer { window.close() }
        guard let button = await node(in: window, matching: {
            self.string($0, "accessibilityIdentifier") == "swiftui-button-probe"
        }) else { return false }
        return string(button, "accessibilityRole") == "AXButton"
            && button.responds(to: NSSelectorFromString("accessibilityPerformPress"))
    }

    /// 지연 생성되는 접근성 노드를 조건에 따라 검색
    private func node(in window: NSWindow, matching predicate: (NSObject) -> Bool) async -> NSObject? {
        for _ in 0..<50 {
            window.contentView?.layoutSubtreeIfNeeded()
            if let found = find(window.contentView as Any, matching: predicate) { return found }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    /// 부모 창과 별도 팝오버 창의 접근성 트리에서 문구 표시·닫기 대기
    private func assertPopoverText(_ expected: String, excluding parent: NSWindow, present: Bool = true) async throws {
        for _ in 0..<50 {
            let found = NSApp.windows.contains { window in
                guard window !== parent, window.isVisible, let contentView = window.contentView else { return false }
                return find(contentView as Any) { object in
                    ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"]
                        .compactMap { string(object, $0) }
                        .contains { $0.contains(expected) }
                } != nil
            }
            if found == present { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(present ? "팝오버 문구 미표시: \(expected)" : "팝오버 닫기 실패: \(expected)")
    }

    /// 순환과 과도한 깊이를 제한한 접근성 자식 순회
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

    /// 접근성 문자열 속성 조회
    private func string(_ object: NSObject, _ name: String) -> String? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() else { return nil }
        return String(describing: value)
    }

    /// SwiftUI 접근성 버튼의 실제 press 동작 수행
    private func press(_ object: NSObject) throws {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else {
            XCTFail("정보 버튼의 press 동작 부재")
            return
        }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(object.method(for: selector), to: Press.self)
        XCTAssertTrue(action(object, selector))
    }
}
