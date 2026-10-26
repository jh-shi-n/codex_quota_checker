// 목적: macOS 로그인 항목 등록과 관찰 가능한 실제 상태 제공
// 이용처: 앱 수명주기와 설정 화면의 자동실행 상태 동기화
// 사용방법: 상태 확인 시 refreshStatus, 사용자 변경 시 setEnabled 호출
// 실행 예시: service.refreshStatus()
import Combine
import Foundation
import ServiceManagement

public enum LaunchAtLoginStatus: String, Equatable, Sendable {
    case enabled
    case disabled
    case requiresApproval
    case notFound
}

public enum LaunchAtLoginError: Error, Equatable, Sendable {
    case operationFailed(String)
}

extension LaunchAtLoginError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .operationFailed:
            return AppErrorCode.loginItem.message("로그인 시 자동 실행 설정을 변경하지 못했습니다.")
        }
    }
}

/// 실제 로그인 항목 변경 없이 등록 호출을 검증하는 backend 경계
public protocol LaunchAtLoginBackend: AnyObject, Sendable {
    var status: LaunchAtLoginStatus { get }
    /// 명시적 켜기 요청의 등록 수행
    func register() throws
    /// 명시적 끄기 요청의 등록 해제 수행
    func unregister() throws
}

/// 사용자 요청에 따른 시스템 로그인 항목 열기 경계
public protocol LaunchAtLoginSettingsOpener: AnyObject, Sendable {
    /// 사용자 요청의 시스템 설정 열기
    func openLoginItems()
}

/// ServiceManagement의 메인 앱 로그인 항목 연결
public final class SystemLaunchAtLoginBackend: LaunchAtLoginBackend, @unchecked Sendable {
    private let service: SMAppService

    /// 메인 앱 또는 지정된 ServiceManagement 서비스 연결
    public init(service: SMAppService = .mainApp) {
        self.service = service
    }

    public var status: LaunchAtLoginStatus {
        switch service.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        case .notRegistered:
            return .disabled
        @unknown default:
            return .notFound
        }
    }

    /// 시스템 로그인 항목 등록
    public func register() throws {
        try service.register()
    }

    /// 시스템 로그인 항목 등록 해제
    public func unregister() throws {
        try service.unregister()
    }
}

/// 시스템 로그인 항목 화면 열기 구현
public final class SystemLaunchAtLoginSettingsOpener: LaunchAtLoginSettingsOpener, @unchecked Sendable {
    /// 시스템 설정 열기 구현 생성
    public init() {}

    /// 시스템 로그인 항목 화면 열기
    public func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// 사용자 조작에만 등록·해제를 허용하는 자동실행 상태 제공자
@MainActor
public final class LaunchAtLoginService: ObservableObject {
    public let backend: any LaunchAtLoginBackend
    public let settingsOpener: any LaunchAtLoginSettingsOpener
    public private(set) var lastError: LaunchAtLoginError?
    @Published public private(set) var currentStatus: LaunchAtLoginStatus

    /// 실제 서비스 또는 격리된 테스트 backend와 설정 열기 동작 연결
    public init(
        backend: any LaunchAtLoginBackend = SystemLaunchAtLoginBackend(),
        settingsOpener: any LaunchAtLoginSettingsOpener = SystemLaunchAtLoginSettingsOpener()
    ) {
        self.backend = backend
        self.settingsOpener = settingsOpener
        self.currentStatus = backend.status
    }

    public var status: LaunchAtLoginStatus {
        backend.status
    }

    /// 등록 변경 없이 시스템 상태 재조회 및 변경된 화면 상태 발행
    @discardableResult
    public func refreshStatus() -> LaunchAtLoginStatus {
        let latest = backend.status
        if currentStatus != latest { currentStatus = latest }
        DiagnosticLogContext.record(.launchAtLoginStatusRead, fields: [.status: .identifier(latest.rawValue)])
        return latest
    }

    /// 명시적 사용자 요청의 등록·해제와 실패 후 실제 상태 동기화
    @discardableResult
    public func setEnabled(_ enabled: Bool) -> Result<LaunchAtLoginStatus, LaunchAtLoginError> {
        lastError = nil
        var operationError: NSError?
        defer {
            let latest = refreshStatus()
            var fields: [DiagnosticField: DiagnosticValue] = [
                .status: .identifier(latest.rawValue),
                .reason: .identifier(enabled ? "register" : "unregister"),
            ]
            if let operationError {
                fields[.errorDomain] = .identifier(operationError.domain)
                fields[.errorCode] = .integer(operationError.code)
            }
            DiagnosticLogContext.record(.launchAtLoginChanged,
                level: operationError == nil ? .notice : .error, fields: fields)
        }
        let currentStatus = backend.status
        if enabled {
            if currentStatus == .enabled || currentStatus == .requiresApproval {
                return .success(currentStatus)
            }
        } else if currentStatus == .disabled || currentStatus == .notFound {
            return .success(currentStatus)
        }

        do {
            if enabled {
                try backend.register()
            } else {
                try backend.unregister()
            }
            return .success(backend.status)
        } catch {
            operationError = error as NSError
            // 등록 오류와 동시에 승인 대기로 바뀐 경우 실제 승인 상태 우선 안내
            if enabled, backend.status == .requiresApproval {
                return .success(.requiresApproval)
            }
            let mapped = LaunchAtLoginError.operationFailed(error.localizedDescription)
            lastError = mapped
            return .failure(mapped)
        }
    }

    /// 사용자 요청에만 시스템 로그인 항목 화면 열기
    public func openSystemSettingsLoginItems() {
        settingsOpener.openLoginItems()
    }
}
