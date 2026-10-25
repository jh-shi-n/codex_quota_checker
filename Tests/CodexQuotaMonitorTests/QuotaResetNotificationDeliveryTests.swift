// 목적: 조기 리셋 시스템 알림 권한·전달·대체 표시 검증
// 이용처: CodexQuotaMonitorKit 알림 전달 회귀 테스트
// 사용방법: swift test --filter QuotaResetNotificationDeliveryTests
import XCTest
@testable import CodexQuotaMonitorKit

@MainActor
final class QuotaResetNotificationDeliveryTests: XCTestCase {
    /// 자동 Ping 실패의 시스템 전달과 거부·전달 오류 시 오류 노치 대체 검증
    func testAutomaticPingFailureUsesSystemOrOneErrorFallback() async {
        let backend = StubNotificationBackend(status: .authorized)
        var fallbacks: [QuotaResetNotificationFallback] = []
        let delivery = QuotaResetNotificationDelivery(backend: backend, onFallback: { fallbacks.append($0) })
        let alert = QuotaResetAlert(accountID: "C1", title: "할당량 자동 Ping 실패", body: "C1: 전송 실패")
        await delivery.notifyAutomaticPingFailure(alert)
        XCTAssertEqual(backend.delivered.count, 1)
        XCTAssertTrue(fallbacks.isEmpty)
        backend.status = .denied
        await delivery.notifyAutomaticPingFailure(alert)
        XCTAssertEqual(fallbacks.count, 1)
        XCTAssertTrue(fallbacks[0].isFailure)
        backend.status = .authorized
        backend.deliveryError = StubNotificationError.delivery
        await delivery.notifyAutomaticPingFailure(alert)
        XCTAssertEqual(fallbacks.count, 2)
        XCTAssertTrue(fallbacks[1].isFailure)
    }

    /// 사전·도달 알림의 실제 어댑터 입력과 권한 거부·전달 실패 상태 검증
    func testScheduledAlertsUseSystemBackendAndReportUnavailableDelivery() async {
        let backend = StubNotificationBackend(status: .authorized)
        let delivery = QuotaResetNotificationDelivery(backend: backend)
        let alert = QuotaResetAlert(accountID: "C1", title: "할당량 초기화 예정", body: "5분 뒤 초기화 예정")
        await delivery.notifyScheduled(alert)
        XCTAssertEqual(backend.delivered.count, 1)
        XCTAssertEqual(backend.delivered.first?.title, alert.title)
        XCTAssertEqual(backend.delivered.first?.body, alert.body)
        XCTAssertEqual(delivery.status.outcome, .delivered)
        backend.status = .denied
        await delivery.notifyScheduled(alert)
        XCTAssertEqual(delivery.status.outcome, .failed)
        XCTAssertEqual(backend.delivered.count, 1)
        backend.status = .authorized
        backend.deliveryError = StubNotificationError.delivery
        await delivery.notifyScheduled(alert)
        XCTAssertEqual(delivery.status.outcome, .failed)
        XCTAssertEqual(delivery.status.deliveryError, "모의 알림 전달 오류")
    }

    /// 표시 이름 변경 시 알림 문구만 교체하고 내부 계정 ID 유지 검증
    func testScheduledNotificationUsesCustomNameWithoutChangingIdentity() async {
        let backend = StubNotificationBackend(status: .authorized)
        let delivery = QuotaResetNotificationDelivery(backend: backend)
        let alert = QuotaResetAlert(accountID: "C1", title: "초기화 예정", body: "C1: 5분 뒤 초기화 예정")
        await delivery.notifyScheduled(alert, displayName: "업무 계정")
        XCTAssertEqual(backend.delivered.first?.body, "업무 계정: 5분 뒤 초기화 예정")
        XCTAssertEqual(alert.accountID, "C1")
    }

    /// 요청 오류 직후 허용 권한을 재조회한 경우 오래된 오류 제거 검증
    func testFailedRequestClearsErrorWhenImmediateStatusIsAuthorized() async {
        for authorization in [QuotaResetNotificationAuthorization.authorized, .provisional, .ephemeral] {
            let backend = StubNotificationBackend(status: authorization)
            backend.requestError = StubNotificationError.authorization
            let delivery = QuotaResetNotificationDelivery(backend: backend)

            await delivery.requestAuthorization()

            XCTAssertEqual(delivery.status.authorization, authorization)
            XCTAssertNil(delivery.status.authorizationError)
        }
    }

    /// 시작 상태 확인과 명시적 권한 요청의 최신 결과 반영 검증
    func testStartReadsStatusWithoutRequestingPermissionAndRetryReadsFreshStatus() async {
        let backend = StubNotificationBackend(status: .notRequested)
        let delivery = QuotaResetNotificationDelivery(backend: backend)

        await delivery.start()

        XCTAssertEqual(delivery.status.authorization, .notRequested)
        XCTAssertEqual(backend.requestCount, 0)

        backend.statusAfterRequest = .authorized
        await delivery.requestAuthorization()

        XCTAssertEqual(backend.requestCount, 1)
        XCTAssertEqual(delivery.status.authorization, .authorized)
    }

    /// 권한 거부 시 한 번만 노치 대체 이벤트 생성 검증
    func testDeniedResetFallsBackExactlyOnce() async {
        let backend = StubNotificationBackend(status: .denied)
        var fallbacks: [QuotaResetNotificationFallback] = []
        let delivery = QuotaResetNotificationDelivery(
            backend: backend,
            onFallback: { fallbacks.append($0) }
        )

        await delivery.notifyReset(makeReset())

        XCTAssertEqual(delivery.status.authorization, .denied)
        XCTAssertEqual(delivery.status.outcome, .fallback)
        XCTAssertEqual(fallbacks.count, 1)
        XCTAssertEqual(fallbacks.first?.accountID, "C3")
        XCTAssertEqual(fallbacks.first?.windowTitles, ["5시간 한도", "전체 한도"])
        XCTAssertEqual(backend.delivered.count, 0)
    }

    /// 시스템 알림 성공 시 대체 이벤트 미생성 검증
    func testSuccessfulResetDeliveryDoesNotFallBack() async {
        let backend = StubNotificationBackend(status: .authorized)
        var fallbacks: [QuotaResetNotificationFallback] = []
        let delivery = QuotaResetNotificationDelivery(
            backend: backend,
            onFallback: { fallbacks.append($0) }
        )

        await delivery.notifyReset(makeReset())

        XCTAssertEqual(delivery.status.outcome, .delivered)
        XCTAssertNil(delivery.status.deliveryError)
        XCTAssertTrue(fallbacks.isEmpty)
        XCTAssertEqual(backend.delivered.count, 1)
        XCTAssertEqual(backend.delivered.first?.title, "할당량 조기 리셋")
        XCTAssertTrue(backend.delivered.first?.body.contains("5시간 한도, 전체 한도") == true)
    }

    /// 시스템 알림 전달 오류의 사용자 노출과 단일 대체 표시 검증
    func testDeliveryFailureSurfacesErrorAndFallsBackExactlyOnce() async {
        let backend = StubNotificationBackend(status: .authorized)
        backend.deliveryError = StubNotificationError.delivery
        var fallbacks: [QuotaResetNotificationFallback] = []
        let delivery = QuotaResetNotificationDelivery(
            backend: backend,
            onFallback: { fallbacks.append($0) }
        )

        await delivery.notifyReset(makeReset())

        XCTAssertEqual(delivery.status.outcome, .fallback)
        XCTAssertEqual(delivery.status.deliveryError, "모의 알림 전달 오류")
        XCTAssertEqual(fallbacks.count, 1)
    }

    /// 테스트 알림 문구와 대체 이벤트 미생성 검증
    func testTestNotificationIsClearlyLabeledAndNeverFallsBack() async {
        let backend = StubNotificationBackend(status: .authorized)
        var fallbacks: [QuotaResetNotificationFallback] = []
        let delivery = QuotaResetNotificationDelivery(
            backend: backend,
            onFallback: { fallbacks.append($0) }
        )

        await delivery.sendTestNotification()

        XCTAssertEqual(delivery.status.outcome, .testDelivered)
        XCTAssertEqual(backend.delivered.count, 1)
        XCTAssertEqual(backend.delivered.first?.title, "Codex Quota Checker 테스트 알림")
        XCTAssertTrue(backend.delivered.first?.body.contains("할당량 상태는 변경되지 않습니다") == true)
        XCTAssertTrue(fallbacks.isEmpty)
    }

    /// 권한 상태 조회 오류의 사용자 노출 검증
    func testAuthorizationReadErrorIsExposedInStatus() async {
        let backend = StubNotificationBackend(status: .notRequested)
        backend.authorizationError = StubNotificationError.authorization
        let delivery = QuotaResetNotificationDelivery(backend: backend)

        await delivery.start()

        XCTAssertEqual(delivery.status.authorization, .error)
        XCTAssertEqual(delivery.status.authorizationError, "모의 권한 조회 오류")
    }

    /// 조기 리셋 입력 구성
    private func makeReset() -> EarlyQuotaReset {
        EarlyQuotaReset(accountID: "C3", windows: [.primary, .secondary])
    }

    /// 실제 권한 요청 실패 문구의 유지와 시스템 권한 회복 후 제거 검증
    func testFailedPermissionRequestRemainsVisibleUntilAuthorizationRecovers() async {
        let backend = StubNotificationBackend(status: .notRequested)
        backend.requestError = StubNotificationError.authorization
        var fallbacks: [QuotaResetNotificationFallback] = []
        let delivery = QuotaResetNotificationDelivery(
            backend: backend,
            onFallback: { fallbacks.append($0) }
        )
        await delivery.requestAuthorization()
        XCTAssertEqual(delivery.status.authorizationError, "모의 권한 조회 오류")

        await delivery.notifyReset(makeReset())
        XCTAssertEqual(delivery.status.authorizationError, "모의 권한 조회 오류")
        XCTAssertEqual(fallbacks.count, 1)

        backend.status = .authorized
        await delivery.refreshAuthorization()
        XCTAssertNil(delivery.status.authorizationError)
    }
}

/// 시스템 알림 동작을 계측하는 테스트 어댑터
@MainActor
private final class StubNotificationBackend: QuotaResetNotificationBackend {
    var status: QuotaResetNotificationAuthorization
    var statusAfterRequest: QuotaResetNotificationAuthorization?
    var authorizationError: Error?
    var requestError: Error?
    var deliveryError: Error?
    var requestCount = 0
    var delivered: [(title: String, body: String)] = []

    /// 초기 권한 상태 지정
    init(status: QuotaResetNotificationAuthorization) {
        self.status = status
    }

    /// 모의 현재 권한 상태 반환
    func authorizationStatus() async throws -> QuotaResetNotificationAuthorization {
        if let authorizationError { throw authorizationError }
        return status
    }

    /// 모의 권한 요청과 요청 후 상태 변경
    func requestAuthorization() async throws {
        requestCount += 1
        if let requestError { throw requestError }
        if let statusAfterRequest { status = statusAfterRequest }
    }

    /// 모의 알림 전달과 전달 입력 기록
    func deliver(title: String, body: String) async throws {
        if let deliveryError { throw deliveryError }
        delivered.append((title, body))
    }
}

/// 권한 조회·알림 전달 실패 표현
private enum StubNotificationError: LocalizedError {
    case authorization
    case delivery

    /// 테스트 오류의 비민감 표시 문구 제공
    var errorDescription: String? {
        switch self {
        case .authorization: "모의 권한 조회 오류"
        case .delivery: "모의 알림 전달 오류"
        }
    }
}
