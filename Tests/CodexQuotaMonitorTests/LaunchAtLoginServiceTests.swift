import Combine
import XCTest
@testable import CodexQuotaMonitorKit

@MainActor
final class LaunchAtLoginServiceTests: XCTestCase {
    /// 등록 실패의 분류 정보 기록과 오류 설명의 민감 원문 제외 검증
    func testDiagnosticsCaptureStatusAndErrorCodeWithoutRawDescription() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = DiagnosticLogger(directory: root, osLogEnabled: false, timerEnabled: false)
        let error = NSError(domain: "SMAppServiceErrorDomain", code: 42,
            userInfo: [NSLocalizedDescriptionKey: "private-account-path-and-auth-data"])
        let service = LaunchAtLoginService(backend: FakeLaunchBackend(status: .disabled, registerError: error))
        DiagnosticLogContext.$logger.withValue(logger) {
            _ = service.setEnabled(true)
        }
        logger.flush()
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
        let lines = try files.flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n").map(String.init) }
        let rows = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        let change = try XCTUnwrap(rows.first { $0["event"] as? String == "launchAtLoginChanged" })
        let fields = try XCTUnwrap(change["fields"] as? [String: [String: Any]])
        XCTAssertEqual(fields["status"]?["value"] as? String, "disabled")
        XCTAssertEqual(fields["errorDomain"]?["value"] as? String, "SMAppServiceErrorDomain")
        XCTAssertEqual(fields["errorCode"]?["value"] as? Int, 42)
        XCTAssertFalse(lines.joined().contains("private-account-path-and-auth-data"))
    }

    /// 시작·활성화의 조회 반복으로 등록·해제·설정 열기가 발생하지 않는 경계 검증
    func testRefreshPublishesExternalApprovalAndRevocationWithoutMutations() {
        let backend = FakeLaunchBackend(status: .requiresApproval)
        let opener = FakeLaunchItemsOpener()
        let service = LaunchAtLoginService(backend: backend, settingsOpener: opener)
        var changes: [LaunchAtLoginStatus] = []
        let subscription = service.$currentStatus.sink { changes.append($0) }
        defer { subscription.cancel() }

        for status in [LaunchAtLoginStatus.requiresApproval, .enabled, .enabled, .requiresApproval, .disabled, .notFound] {
            backend.currentStatus = status
            XCTAssertEqual(service.refreshStatus(), status)
            XCTAssertEqual(service.currentStatus, status)
        }

        XCTAssertEqual(changes, [.requiresApproval, .enabled, .requiresApproval, .disabled, .notFound])
        XCTAssertEqual(backend.registerCount, 0)
        XCTAssertEqual(backend.unregisterCount, 0)
        XCTAssertEqual(opener.openCount, 0)
    }

    /// 등록 성공·승인 대기·오류 직후 화면에 실제 상태 발행 검증
    func testUserRequestSynchronizesPublishedStatusForEveryOutcome() {
        let cases: [(LaunchAtLoginStatus?, LaunchAtLoginStatus?, Error?, LaunchAtLoginStatus)] = [
            (.enabled, nil, nil, .enabled),
            (.requiresApproval, nil, nil, .requiresApproval),
            (nil, .requiresApproval, FakeLaunchError.denied, .requiresApproval),
            (nil, .notFound, FakeLaunchError.denied, .notFound),
        ]
        for (successStatus, failureStatus, error, expected) in cases {
            let backend = FakeLaunchBackend(status: .disabled, registerError: error,
                statusAfterRegisterError: failureStatus, statusAfterRegister: successStatus)
            let service = LaunchAtLoginService(backend: backend)
            _ = service.setEnabled(true)
            XCTAssertEqual(service.currentStatus, expected)
        }
    }

    /// 해제 실패 중 시스템 상태가 달라진 경우에도 화면 상태 복구 검증
    func testFailedUnregisterPublishesEffectiveStatus() {
        let backend = FakeLaunchBackend(status: .enabled, unregisterError: FakeLaunchError.denied,
            statusAfterUnregisterError: .requiresApproval)
        let service = LaunchAtLoginService(backend: backend)
        XCTAssertEqual(service.setEnabled(false), .failure(.operationFailed("denied")))
        XCTAssertEqual(service.currentStatus, .requiresApproval)
    }

    func testBackendSuccessUpdatesReadableStatus() {
        let backend = FakeLaunchBackend(status: .disabled)
        let service = LaunchAtLoginService(backend: backend)

        let result = service.setEnabled(true)

        XCTAssertEqual(result, .success(.enabled))
        XCTAssertEqual(service.status, .enabled)
        XCTAssertEqual(backend.registerCount, 1)
        XCTAssertEqual(backend.unregisterCount, 0)
    }

    func testAlreadyEnabledRegistrationIsIdempotent() {
        let backend = FakeLaunchBackend(status: .enabled)
        let service = LaunchAtLoginService(backend: backend)

        XCTAssertEqual(service.setEnabled(true), .success(.enabled))
        XCTAssertEqual(backend.registerCount, 0)
    }

    func testAlreadyDisabledUnregistrationIsIdempotent() {
        let backend = FakeLaunchBackend(status: .disabled)
        let service = LaunchAtLoginService(backend: backend)

        XCTAssertEqual(service.setEnabled(false), .success(.disabled))
        XCTAssertEqual(backend.unregisterCount, 0)
    }

    func testBackendFailureIsMappedWithoutChangingStatus() {
        let backend = FakeLaunchBackend(status: .disabled, registerError: FakeLaunchError.denied)
        let service = LaunchAtLoginService(backend: backend)

        let result = service.setEnabled(true)

        guard case let .failure(error) = result else {
            return XCTFail("Expected a mapped launch-at-login failure")
        }
        XCTAssertEqual(error, .operationFailed("denied"))
        XCTAssertEqual(service.status, .disabled)
        XCTAssertEqual(backend.registerCount, 1)
    }

    func testDisableUsesBackendAndExposesRequiresApprovalStatus() {
        let backend = FakeLaunchBackend(status: .enabled)
        let service = LaunchAtLoginService(backend: backend)

        XCTAssertEqual(service.setEnabled(false), .success(.disabled))
        XCTAssertEqual(backend.unregisterCount, 1)

        backend.currentStatus = .requiresApproval
        XCTAssertEqual(service.status, .requiresApproval)
    }

    func testRequiresApprovalCanOpenLoginItemsThroughInjectedOpener() {
        let backend = FakeLaunchBackend(status: .requiresApproval)
        let opener = FakeLaunchItemsOpener()
        let service = LaunchAtLoginService(backend: backend, settingsOpener: opener)

        XCTAssertEqual(service.setEnabled(true), .success(.requiresApproval))
        XCTAssertEqual(backend.registerCount, 0)
        service.openSystemSettingsLoginItems()
        XCTAssertEqual(opener.openCount, 1)
    }

    func testRegisterFailureRereadsUpdatedRequiresApprovalAndKeepsOpenerExplicit() {
        let backend = FakeLaunchBackend(
            status: .disabled,
            registerError: FakeLaunchError.denied,
            statusAfterRegisterError: .requiresApproval
        )
        let opener = FakeLaunchItemsOpener()
        let service = LaunchAtLoginService(backend: backend, settingsOpener: opener)

        XCTAssertEqual(service.setEnabled(true), .success(.requiresApproval))
        XCTAssertEqual(service.status, .requiresApproval)
        XCTAssertGreaterThanOrEqual(backend.statusReadCount, 2)
        XCTAssertEqual(opener.openCount, 0)

        service.openSystemSettingsLoginItems()
        XCTAssertEqual(opener.openCount, 1)
    }

    func testUnregisterFailureWithRequiresApprovalStatusRemainsGenericError() {
        let backend = FakeLaunchBackend(
            status: .enabled,
            unregisterError: FakeLaunchError.denied,
            statusAfterUnregisterError: .requiresApproval
        )
        let service = LaunchAtLoginService(backend: backend)

        XCTAssertEqual(service.setEnabled(false), .failure(.operationFailed("denied")))
        XCTAssertEqual(service.status, .requiresApproval)
    }

    func testNotFoundDisableIsDistinguishedWithoutUnregistering() {
        let backend = FakeLaunchBackend(status: .notFound)
        let service = LaunchAtLoginService(backend: backend)

        XCTAssertEqual(service.setEnabled(false), .success(.notFound))
        XCTAssertEqual(backend.unregisterCount, 0)
        XCTAssertEqual(service.status, .notFound)
    }

    func testNotFoundEnableRegistersAndReturnsEnabled() {
        let backend = FakeLaunchBackend(status: .notFound)
        let service = LaunchAtLoginService(backend: backend)

        XCTAssertEqual(service.setEnabled(true), .success(.enabled))
        XCTAssertEqual(backend.registerCount, 1)
        XCTAssertEqual(service.status, .enabled)
    }

    func testNotFoundEnableReturnsRequiresApprovalWhenRegistrationReportsIt() {
        let backend = FakeLaunchBackend(
            status: .notFound,
            statusAfterRegister: .requiresApproval
        )
        let service = LaunchAtLoginService(backend: backend)

        XCTAssertEqual(service.setEnabled(true), .success(.requiresApproval))
        XCTAssertEqual(backend.registerCount, 1)
        XCTAssertEqual(service.status, .requiresApproval)
    }
}

private enum FakeLaunchError: Error, LocalizedError {
    case denied

    var errorDescription: String? { "denied" }
}

private final class FakeLaunchBackend: LaunchAtLoginBackend, @unchecked Sendable {
    var currentStatus: LaunchAtLoginStatus
    let registerError: Error?
    let unregisterError: Error?
    let statusAfterRegisterError: LaunchAtLoginStatus?
    let statusAfterUnregisterError: LaunchAtLoginStatus?
    let statusAfterRegister: LaunchAtLoginStatus?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var statusReadCount = 0

    init(
        status: LaunchAtLoginStatus,
        registerError: Error? = nil,
        unregisterError: Error? = nil,
        statusAfterRegisterError: LaunchAtLoginStatus? = nil,
        statusAfterUnregisterError: LaunchAtLoginStatus? = nil,
        statusAfterRegister: LaunchAtLoginStatus? = nil
    ) {
        self.currentStatus = status
        self.registerError = registerError
        self.unregisterError = unregisterError
        self.statusAfterRegisterError = statusAfterRegisterError
        self.statusAfterUnregisterError = statusAfterUnregisterError
        self.statusAfterRegister = statusAfterRegister
    }

    var status: LaunchAtLoginStatus {
        statusReadCount += 1
        return currentStatus
    }

    func register() throws {
        registerCount += 1
        if let registerError {
            if let statusAfterRegisterError {
                currentStatus = statusAfterRegisterError
            }
            throw registerError
        }
        currentStatus = statusAfterRegister ?? .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError {
            if let statusAfterUnregisterError {
                currentStatus = statusAfterUnregisterError
            }
            throw unregisterError
        }
        currentStatus = .disabled
    }
}

private final class FakeLaunchItemsOpener: LaunchAtLoginSettingsOpener, @unchecked Sendable {
    private(set) var openCount = 0

    func openLoginItems() {
        openCount += 1
    }
}
