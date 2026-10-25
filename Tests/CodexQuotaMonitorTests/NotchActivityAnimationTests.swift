// 목적: 좌우 활동 알림의 배경 확장·축소 및 노치 쪽 고정 위치 검증
// 이용처: 실제 NSHostingView 렌더링을 사용하는 애니메이션 회귀 테스트
// 사용방법: swift test --filter NotchActivityAnimationTests
import AppKit
import SwiftUI
import XCTest
@testable import CodexQuotaMonitorKit

/// 배경과 글자가 함께 펼쳐지는 좌우 패널의 실제 렌더링 검증
@MainActor
final class NotchActivityAnimationTests: XCTestCase {
    /// 좌우 확장 후 노치 쪽 끝 고정 및 퇴장 후 배경 복원 검증
    func testBothSidesRevealAndCollapseWithoutMovingInnerEdge() async throws {
        for side: NotchSide in [.left, .right] {
            let model = NotchActivityPresentationModel()
            let root = QuotaClusterView(
                accounts: [],
                side: side,
                activityPresentation: model
            )
            let host = NSHostingView(rootView: root)
            let panel = NotchQuotaPanel(
                contentRect: NSRect(x: -10000, y: 0, width: 420, height: 32),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.contentView = host
            panel.orderFrontRegardless()
            defer { panel.close() }
            try await Task.sleep(for: .milliseconds(80))
            let idle = try blackBounds(host)

            model.setToast(SessionActivityToast(
                content: .transition(SessionActivityTransition(
                    accountID: "C1", side: side == .left ? .left : .right,
                    sessionID: "render-test", agentLabel: nil, taskName: nil,
                    status: .working, sessionTitle: "Animation preview"
                )),
                durationSeconds: 3
            ), width: 210)
            try await Task.sleep(for: .milliseconds(500))
            let expanded = try blackBounds(host)
            XCTAssertGreaterThan(expanded.width, idle.width + 100)
            assertInnerEdge(expanded, matches: idle, side: side)

            model.setToast(nil)
            let collapsed = try await waitForBlackBounds(host, matching: idle)
            XCTAssertEqual(collapsed, idle)
        }
    }

    /// CI 렌더링 지연을 허용하되 3초 이내 배경 복원 검증
    private func waitForBlackBounds(_ host: NSView, matching expected: CGRect) async throws -> CGRect {
        for _ in 0..<60 {
            let bounds = try blackBounds(host)
            if bounds == expected { return bounds }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try blackBounds(host)
    }

    /// 배경 중앙 행의 불투명 검은 픽셀 범위 측정
    private func blackBounds(_ host: NSView) throws -> CGRect {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let row = bitmap.pixelsHigh / 2
        let columns = (0..<bitmap.pixelsWide).filter { x in
            guard let color = bitmap.colorAt(x: x, y: row)?.usingColorSpace(.deviceRGB) else { return false }
            return color.alphaComponent > 0.95
                && max(color.redComponent, color.greenComponent, color.blueComponent) < 0.1
        }
        let first = try XCTUnwrap(columns.first)
        let last = try XCTUnwrap(columns.last)
        return CGRect(x: first, y: row, width: last - first + 1, height: 1)
    }

    /// 표시 배율과 무관한 노치 쪽 끝 위치 일치 검증
    private func assertInnerEdge(_ bounds: CGRect, matches idle: CGRect, side: NotchSide,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(side == .left ? bounds.maxX : bounds.minX,
                       side == .left ? idle.maxX : idle.minX,
                       accuracy: 2, file: file, line: line)
    }
}
