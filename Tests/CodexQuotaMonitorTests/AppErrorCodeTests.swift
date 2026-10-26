// 목적: 오류코드 호환성·Cocoa 브리지·시스템 원인 분리 및 원문 노출 방지 검증
// 이용처: 앱 시작과 전체 기능 오류의 공통 계약 회귀 테스트
// 사용방법: swift test --filter AppErrorCodeTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 사용자 지원 코드와 기계 처리용 오류의 일관성 검증
final class AppErrorCodeTests: XCTestCase {
    /// 지원 코드·Cocoa 숫자의 전역 유일성 및 공개 코드 형식 검증
    func testCatalogIdentifiersAndNSErrorCodesRemainUnambiguous() {
        let codes = AppErrorCode.allCases
        XCTAssertEqual(Set(codes.map(\.rawValue)).count, codes.count)
        XCTAssertEqual(Set(codes.map(\.numericCode)).count, codes.count)
        for code in codes {
            XCTAssertNotNil(code.rawValue.range(of: "^[A-Z]{2,3}-[0-9]{3}$", options: .regularExpression))
            XCTAssertFalse(code.recoverySuggestion.isEmpty)
        }
        XCTAssertEqual(AppErrorCode.instanceLock.rawValue, "APP-001")
        XCTAssertEqual(AppErrorCode.updateLaunch.rawValue, "UPD-004")
        XCTAssertEqual(AppErrorCode.updateRestoreLaunch.rawValue, "UPD-012")
    }

    /// Cocoa 도메인·코드·하위 원인·복구 안내와 사용자 지원 코드의 분리 검증
    func testNSErrorBridgePreservesStructuredCauseWithoutRawUserInfo() {
        let secret = "/Users/private/auth-secret-token"
        let underlying = NSError(domain: NSOSStatusErrorDomain, code: -600,
                                 userInfo: [NSLocalizedDescriptionKey: secret, NSFilePathErrorKey: secret])
        let id = UUID()
        let failure = AppOperationFailure(.updateLaunch, "앱을 실행하지 못했습니다.", underlying: underlying, occurrenceID: id)
        let bridged = failure as NSError
        XCTAssertEqual(bridged.domain, AppOperationFailure.errorDomain)
        XCTAssertEqual(bridged.code, AppErrorCode.updateLaunch.numericCode)
        XCTAssertEqual(bridged.userInfo["appErrorCode"] as? String, "UPD-004")
        XCTAssertEqual(bridged.userInfo["occurrenceID"] as? String, id.uuidString)
        let cause = bridged.userInfo[NSUnderlyingErrorKey] as? NSError
        XCTAssertEqual(cause?.domain, NSOSStatusErrorDomain)
        XCTAssertEqual(cause?.code, -600)
        XCTAssertNil(cause?.userInfo[NSFilePathErrorKey])
        XCTAssertFalse(failure.userMessage.contains(secret))
        XCTAssertFalse(String(describing: bridged.userInfo).contains(secret))
        XCTAssertNotNil(bridged.localizedRecoverySuggestion)
    }

    /// 외부 원문을 포함한 예외의 코드와 안내를 안전한 고정값으로 변환
    func testFeatureFailuresExposeCodesWithoutProtocolOrAuthenticationContents() {
        let secret = "credential-and-response-secret"
        for failure in [CodexQuotaServiceError.protocolError(secret), .malformedResponse(secret), .transport(secret)] {
            XCTAssertTrue(failure.localizedDescription.contains(failure.appErrorCode.rawValue))
            XCTAssertFalse(failure.localizedDescription.contains(secret))
        }
        XCTAssertTrue(UsageWindowProbeFailureCategory.authenticationFailure.userMessage.contains("PNG-011"))
        XCTAssertTrue(TokenUsageSnapshotError.storageUnavailable.userMessage.contains("TOK-003"))
        XCTAssertTrue(LaunchAtLoginError.operationFailed(secret).localizedDescription.contains("LGN-001"))
        XCTAssertFalse(LaunchAtLoginError.operationFailed(secret).localizedDescription.contains(secret))
    }

    /// 메시지 문구와 무관한 업데이트 검증·통신·미분류 오류 코드 판정
    func testUpdateClassificationDoesNotParseLocalizedMessages() {
        XCTAssertEqual(AppOperationFailure.update(AppUpdateInstallError.invalidSignature).code, .updateSignature)
        let network = AppOperationFailure.update(URLError(.notConnectedToInternet))
        XCTAssertEqual(network.code, .updateNetwork)
        XCTAssertEqual(network.systemDomain, NSURLErrorDomain)
        XCTAssertEqual(network.systemCode, URLError.notConnectedToInternet.rawValue)
        let unknown = AppOperationFailure.update(NSError(domain: "private-domain-secret", code: 42))
        XCTAssertEqual(unknown.code, .updateUnexpected)
        XCTAssertEqual(unknown.systemDomain, "OtherErrorDomain")
    }
}
