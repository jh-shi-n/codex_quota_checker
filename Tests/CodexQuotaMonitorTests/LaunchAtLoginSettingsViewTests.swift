// 목적: 기존 설정 창의 자동실행 토글과 실제 서비스 상태 일치 검증
// 이용처: 시스템 설정 승인·해제 후 화면 갱신의 UI 회귀 테스트
// 사용방법: swift test --filter LaunchAtLoginSettingsViewTests
// 실행 예시: 가짜 backend 상태 변경 후 실제 접근성 체크 표시 확인
import AppKit
import SwiftUI
import XCTest
@testable import CodexQuotaMonitorKit

/// 실제 SwiftUI 화면의 외부 상태 반영과 사용자 클릭 경계 검증
@MainActor
final class LaunchAtLoginSettingsViewTests: XCTestCase {
    /// 이미 열린 화면의 승인·해제 반영 및 사용자 클릭으로만 등록하는 동작 검증
    func testOpenViewTracksExternalStatusAndOnlyClickRegisters() async throws {
        _ = NSApplication.shared
        let originalDelegate = NSApp.delegate
        let delegate = LoginSettingsTestDelegate()
        NSApp.delegate = delegate
        defer { NSApp.delegate = originalDelegate }
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()

        let baseline = makeWindow(Toggle("환경 확인", isOn: .constant(false)).toggleStyle(.checkbox))
        let baselineNode = await checkbox(in: baseline)
        baseline.close()
        try XCTSkipIf(baselineNode == nil, "기본 SwiftUI Toggle 접근성 트리 미제공 환경")

        let backend = LoginSettingsTestBackend()
        let service = LaunchAtLoginService(backend: backend)
        var requests: [Bool] = []
        let window = makeWindow(VStack {
            LaunchAtLoginSettingsView(service: service) { enabled in
                requests.append(enabled)
                service.setEnabled(enabled)
            }
        }.toggleStyle(.checkbox))
        defer { window.close() }

        try await assertCheckbox(0, in: window)
        for status in [LaunchAtLoginStatus.enabled, .requiresApproval, .enabled, .disabled] {
            backend.currentStatus = status
            service.refreshStatus()
            try await assertCheckbox(status == .enabled ? 1 : 0, in: window)
        }
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(backend.registerCount, 0)
        XCTAssertEqual(backend.unregisterCount, 0)

        let candidate = await checkbox(in: window)
        let node = try XCTUnwrap(candidate)
        let selector = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(node.responds(to: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let press = unsafeBitCast(node.method(for: selector), to: Press.self)
        XCTAssertTrue(press(node, selector))
        try await assertCheckbox(1, in: window)
        XCTAssertEqual(requests, [true])
        XCTAssertEqual(backend.registerCount, 1)
    }

    /// 동일 호스트 수명을 유지하는 독립 SwiftUI 테스트 창 구성
    private func makeWindow<Content: View>(_ content: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 550, height: 250),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content.padding())
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    /// 지연된 SwiftUI 접근성 트리에서 실제 체크박스 검색
    private func checkbox(in window: NSWindow) async -> NSObject? {
        for _ in 0..<50 {
            window.contentView?.layoutSubtreeIfNeeded()
            if let node = findCheckbox(window.contentView as Any) { return node }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    /// 접근성 자식 노드를 따라 체크박스 탐색
    private func findCheckbox(_ value: Any, depth: Int = 0) -> NSObject? {
        guard depth < 20, let node = value as? NSObject else { return nil }
        let role = NSSelectorFromString("accessibilityRole")
        if node.responds(to: role), node.perform(role)?.takeUnretainedValue() as? String == "AXCheckBox" {
            return node
        }
        let children = NSSelectorFromString("accessibilityChildren")
        guard node.responds(to: children),
              let values = node.perform(children)?.takeUnretainedValue() as? [Any] else { return nil }
        return values.lazy.compactMap { self.findCheckbox($0, depth: depth + 1) }.first
    }

    /// 게시된 상태 변경 이후 화면 체크 표시 일치 대기
    private func assertCheckbox(_ expected: Int, in window: NSWindow) async throws {
        var actual: Int?
        for _ in 0..<50 {
            let candidate = await checkbox(in: window)
            let node = try XCTUnwrap(candidate)
            actual = (node.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue() as? NSNumber)?.intValue
            if actual == expected { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(actual, expected)
    }
}

/// 시스템 로그인 항목을 변경하지 않는 상태 전이 backend
private final class LoginSettingsTestBackend: LaunchAtLoginBackend, @unchecked Sendable {
    var currentStatus = LaunchAtLoginStatus.requiresApproval
    var registerCount = 0
    var unregisterCount = 0
    var status: LaunchAtLoginStatus { currentStatus }

    /// 사용자 켜기 요청의 횟수와 가짜 활성 상태 반영
    func register() throws { registerCount += 1; currentStatus = .enabled }

    /// 사용자 끄기 요청의 횟수와 가짜 비활성 상태 반영
    func unregister() throws { unregisterCount += 1; currentStatus = .disabled }
}

/// 마지막 테스트 창 종료 후 테스트 프로세스 유지
@MainActor
private final class LoginSettingsTestDelegate: NSObject, NSApplicationDelegate {
    /// 창 수와 독립적인 테스트 수명 유지
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
