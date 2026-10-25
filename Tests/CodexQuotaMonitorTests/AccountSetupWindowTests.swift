// 목적: 실제 연결 창의 표시·본문 변경·재표시 후 최소 크기 검증
// 이용처: NSWindow·NSHostingController 조합의 회귀 테스트
// 사용방법: swift test --filter AccountSetupWindowTests
import AppKit
import XCTest
@testable import CodexQuotaMonitorKit

/// 실제 앱의 창 생성 경로를 사용하는 레이아웃 통합 검증
@MainActor
final class AccountSetupWindowTests: XCTestCase {
    /// 표시·레이아웃·비동기 본문 변경 이후 최소 콘텐츠 크기 유지 검증
    func testDisplayedWindowPreservesMinimumContentSize() async throws {
        let model = makeModel()
        let window = AccountSetupWindow.make(model: model, onComplete: { _ in }, onLater: {})
        defer { window.close() }
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.contentMinSize, AccountSetupView.windowSize)
        assertMinimumSize(window)
        model.path = "/fixture/account"
        model.reportRegistrationFailure("설정을 반영하지 못했습니다. 다시 시도해 주세요.")
        await Task.yield()
        window.contentView?.layoutSubtreeIfNeeded()
        assertMinimumSize(window)
    }

    /// 동일 호스트를 닫지 않고 재표시해도 콘텐츠 크기가 축소되지 않는지 검증
    func testReopeningWindowPreservesContentSize() {
        let window = AccountSetupWindow.make(model: makeModel(), onComplete: { _ in }, onLater: {})
        defer { window.close() }
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        assertMinimumSize(window)
        window.orderOut(nil)
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.isVisible)
        assertMinimumSize(window)
    }

    /// 실제 사용자 계정의 자동 탐색·네트워크 접근 없는 창 테스트 모델 제공
    private func makeModel() -> AccountSetupModel {
        AccountSetupModel(validator: AccountPathValidator(fileSystem: .init { _ in
            AccountPathFileMetadata(exists: false, isDirectory: false, isReadable: false)
        }), checker: { config in
            XCTFail("창 크기 테스트의 실제 계정 조회 금지")
            return AccountState(id: config.id, status: .error)
        })
    }

    /// 실제 프레임·호스팅 뷰 크기의 최소 치수 확인
    private func assertMinimumSize(_ window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        let size = window.contentRect(forFrameRect: window.frame).size
        XCTAssertGreaterThanOrEqual(size.width, AccountSetupView.windowSize.width, file: file, line: line)
        XCTAssertGreaterThanOrEqual(size.height, AccountSetupView.windowSize.height, file: file, line: line)
        XCTAssertEqual(window.contentView?.bounds.size, size, file: file, line: line)
    }

}
