// 목적: 연속 수동 요청 제한과 마지막 클릭 기준 차단 시간 검증
// 이용처: 계정 새로고침·Ping의 공통 요청 제한 회귀 테스트
// 사용방법: swift test --filter ManualRequestGateTests
import XCTest
@testable import CodexQuotaMonitorKit

/// 실제 요청과 대기 없이 수행하는 연속 클릭 검증
@MainActor
final class ManualRequestGateTests: XCTestCase {
    /// 세 번까지 전송 허용, 네 번째부터 차단 및 정확히 5초 후 재개 검증
    func testFourthAttemptIsBlockedUntilFiveSecondsAfterLastAttempt() {
        let clock = RequestClock()
        let gate = ManualRequestGate(uptime: { clock.time })
        let account = AccountState(id: "C2", status: .normal)
        for time in [0.0, 1, 2] {
            clock.time = time
            XCTAssertTrue(gate.allow(account))
        }
        clock.time = 3
        XCTAssertFalse(gate.allow(account))
        XCTAssertEqual(gate.message(for: account), "5초 뒤 이용해주세요")
        clock.time = 7.999
        XCTAssertNotNil(gate.message(for: account))
        clock.time = 8
        XCTAssertNil(gate.message(for: account))
        XCTAssertTrue(gate.allow(account))
    }

    /// 차단 중 반복 클릭의 마지막 시각으로 차단 종료 시점 연장 검증
    func testBlockedAttemptsExtendCooldownFromLatestClick() {
        let clock = RequestClock()
        let gate = ManualRequestGate(uptime: { clock.time })
        let account = AccountState(id: "C2", status: .normal)
        for _ in 0..<3 { XCTAssertTrue(gate.allow(account)) }
        clock.time = 1
        XCTAssertFalse(gate.allow(account))
        clock.time = 5
        XCTAssertFalse(gate.allow(account))
        clock.time = 6
        XCTAssertNotNil(gate.message(for: account))
        clock.time = 10
        XCTAssertNil(gate.message(for: account))
        XCTAssertTrue(gate.allow(account))
    }

    /// 클릭 간격 5초 이후 연속 횟수 초기화와 다른 계정·경로 세대 분리 검증
    func testQuietPeriodAndAccountIsolation() {
        let clock = RequestClock()
        let gate = ManualRequestGate(uptime: { clock.time })
        let account = AccountState(id: "C2", status: .normal)
        for _ in 0..<4 { _ = gate.allow(account) }
        XCTAssertNotNil(gate.message(for: account))
        XCTAssertTrue(gate.allow(AccountState(id: "C1", status: .normal)))
        var changed = account
        changed.configurationGeneration += 1
        XCTAssertTrue(gate.allow(changed))
        clock.time = 5
        for _ in 0..<3 { XCTAssertTrue(gate.allow(account)) }
        XCTAssertFalse(gate.allow(account))
    }
}

/// 경과 시간을 직접 지정하는 단조 시계 fixture
@MainActor
private final class RequestClock {
    var time: TimeInterval = 0
}
