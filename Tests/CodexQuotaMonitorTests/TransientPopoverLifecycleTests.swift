// 목적: 팝오버 해제 중 SwiftUI 바인딩 재접근 방지 검증
// 이용처: macOS 버전별 뷰 수명주기 회귀 검사
// 사용방법: swift test --filter TransientPopoverLifecycleTests
import AppKit
import SwiftUI
import XCTest
@testable import CodexQuotaMonitorKit

/// 파괴 중인 뷰의 상태와 팝오버 정리 동작 분리 검증
@MainActor
final class TransientPopoverLifecycleTests: XCTestCase {
    /// 반복 해제에도 원본 바인딩의 읽기·쓰기 없이 정리되는지 검증
    func testDismantleDoesNotAccessOriginalBinding() {
        var reads = 0
        var writes: [Bool] = []
        let binding = Binding<Bool>(
            get: { reads += 1; return true },
            set: { writes.append($0) }
        )
        let anchor = TransientPopoverPresenter<EmptyView>.AnchorView()
        let coordinator = TransientPopoverPresenter<EmptyView>.Coordinator()
        coordinator.update(isPresented: binding, content: AnyView(EmptyView()), anchorView: anchor)
        let readsBeforeDismantle = reads

        TransientPopoverPresenter<EmptyView>.dismantleNSView(anchor, coordinator: coordinator)
        TransientPopoverPresenter<EmptyView>.dismantleNSView(anchor, coordinator: coordinator)

        XCTAssertEqual(reads, readsBeforeDismantle)
        XCTAssertTrue(writes.isEmpty)
    }
}
