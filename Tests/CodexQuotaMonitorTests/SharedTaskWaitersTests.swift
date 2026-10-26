// 목적: 마지막 소비자 취소와 신규 소비자 가입 간 경쟁의 결정적 재현
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 실제 취소 callback이 멈춘 동안에도 닫힌 조회의 재사용 차단 검증
final class SharedTaskWaitersTests: XCTestCase {
    /// 마지막 소비자 이탈·실제 Task.cancel 사이에서 신규 가입 거부 검증
    func testNewWaiterCannotJoinWhileLastCancellationIsPending() async {
        let cancellationStarted = DispatchSemaphore(value: 0)
        let releaseCancellation = DispatchSemaphore(value: 0)
        let waiters = SharedTaskWaiters {
            cancellationStarted.signal()
            _ = releaseCancellation.wait(timeout: .now() + 2)
        }
        let first = UUID()
        XCTAssertTrue(waiters.tryAdd(first))
        let removal = Task.detached { waiters.remove(first) }
        XCTAssertEqual(cancellationStarted.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(waiters.tryAdd(UUID()))
        releaseCancellation.signal()
        await removal.value
    }

    /// 다른 소비자가 남은 상태의 독립 취소에서 공유 조회 유지 검증
    func testRemovingOneOfTwoWaitersKeepsTaskOpen() {
        let cancellation = DispatchSemaphore(value: 0)
        let waiters = SharedTaskWaiters { cancellation.signal() }
        let first = UUID(), second = UUID()
        XCTAssertTrue(waiters.tryAdd(first))
        XCTAssertTrue(waiters.tryAdd(second))
        waiters.remove(first)
        XCTAssertEqual(cancellation.wait(timeout: .now()), .timedOut)
        XCTAssertTrue(waiters.tryAdd(UUID()))
    }
}
