// 목적: 조기 리셋 시스템 알림 권한·전달 상태 관리
// 이용처: 앱 알림 어댑터와 설정 화면
// 사용방법: backend 주입 후 상태 확인, 권한 요청, 리셋·테스트 전달 호출
import Combine
import Foundation

/// macOS 알림 권한 상태의 앱 공통 표현
public enum QuotaResetNotificationAuthorization: Equatable, Sendable {
    case checking
    case notRequested
    case denied
    case authorized
    case provisional
    case ephemeral
    case unavailable
    case unknown
    case error
}

/// 마지막 시스템 알림 전달 결과
public enum QuotaResetNotificationOutcome: Equatable, Sendable {
    case idle
    case delivered
    case fallback
    case testDelivered
    case testFailed
    case failed
}

/// 설정 화면에 노출하는 권한·전달 상태
public struct QuotaResetNotificationStatus: Equatable, Sendable {
    public let authorization: QuotaResetNotificationAuthorization
    public let outcome: QuotaResetNotificationOutcome
    public let authorizationError: String?
    public let deliveryError: String?

    /// 알림 전달 상태 생성
    public init(
        authorization: QuotaResetNotificationAuthorization,
        outcome: QuotaResetNotificationOutcome = .idle,
        authorizationError: String? = nil,
        deliveryError: String? = nil
    ) {
        self.authorization = authorization
        self.outcome = outcome
        self.authorizationError = authorizationError
        self.deliveryError = deliveryError
    }
}

/// 실제 시스템 알림 접근을 분리하는 어댑터 계약
@MainActor
public protocol QuotaResetNotificationBackend: AnyObject {
    /// 현재 macOS 권한 상태 조회
    func authorizationStatus() async throws -> QuotaResetNotificationAuthorization

    /// 사용자 동작에 따른 macOS 권한 요청
    func requestAuthorization() async throws

    /// 즉시 표시할 시스템 알림 전달
    func deliver(title: String, body: String) async throws
}

/// 노치 대체 전달에 필요한 조기 리셋 정보
public struct QuotaResetNotificationFallback: Equatable, Sendable {
    public let id: String
    public let accountID: String
    public let windowTitles: [String]
    public let isFailure: Bool
    public let isScheduleChange: Bool

    /// 계정·리셋 구간별 대체 표시 정보 생성
    public init(id: String, accountID: String, windowTitles: [String], isFailure: Bool = false, isScheduleChange: Bool = false) {
        self.id = id
        self.accountID = accountID
        self.windowTitles = windowTitles
        self.isFailure = isFailure
        self.isScheduleChange = isScheduleChange
    }
}

/// 시스템 알림 전달과 실패 시 노치 대체 표시를 조정하는 상태 모델
@MainActor
public final class QuotaResetNotificationDelivery: ObservableObject {
    /// 시스템 알림 기능이 없는 호스트의 설정 화면 기본 모델
    public static let unavailable = QuotaResetNotificationDelivery(backend: nil)

    @Published public private(set) var status: QuotaResetNotificationStatus
    public private(set) var isRequestingAuthorization = false

    private var authorizationRevision = 0
    private let backend: (any QuotaResetNotificationBackend)?
    private let onFallback: @MainActor @Sendable (QuotaResetNotificationFallback) -> Void
    private let onDiagnostic: @MainActor @Sendable (String) -> Void

    /// 시스템 알림 어댑터와 대체 전달 콜백 지정
    public init(
        backend: (any QuotaResetNotificationBackend)?,
        onFallback: @escaping @MainActor @Sendable (QuotaResetNotificationFallback) -> Void = { _ in },
        onDiagnostic: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) {
        self.backend = backend
        self.onFallback = onFallback
        self.onDiagnostic = onDiagnostic
        self.status = QuotaResetNotificationStatus(
            authorization: backend == nil ? .unavailable : .checking
        )
    }

    /// 앱 시작 시 권한 상태만 조회
    public func start() async {
        await refreshAuthorization()
    }

    /// 현재 권한 상태 재조회
    public func refreshAuthorization() async {
        guard !isRequestingAuthorization else { return }
        guard let backend else {
            updateAuthorization(.unavailable, error: nil)
            return
        }

        authorizationRevision += 1
        let revision = authorizationRevision
        let previousError = status.authorizationError
        updateAuthorization(.checking, error: previousError)
        do {
            let authorization = try await backend.authorizationStatus()
            guard revision == authorizationRevision else { return }
            let recovered = [.authorized, .provisional, .ephemeral].contains(authorization)
            updateAuthorization(authorization, error: recovered ? nil : previousError)
            onDiagnostic("authorization_status_read")
        } catch {
            guard revision == authorizationRevision else { return }
            updateAuthorization(.error, error: AppOperationFailure(.notificationDelivery, "시스템 알림 처리에 실패했습니다.", underlying: error).localizedDescription)
            onDiagnostic("authorization_status_failed")
        }
    }

    /// 사용자 요청에 따라 권한 요청 후 최신 권한 상태 재조회
    public func requestAuthorization() async {
        guard !isRequestingAuthorization else { return }
        authorizationRevision += 1
        isRequestingAuthorization = true
        defer { isRequestingAuthorization = false }
        guard let backend else {
            updateAuthorization(.unavailable, error: nil)
            return
        }

        updateAuthorization(.checking, error: nil)
        var requestError: String?
        do {
            try await backend.requestAuthorization()
            onDiagnostic("authorization_request_completed")
        } catch {
            requestError = AppOperationFailure(.notificationDelivery, "시스템 알림 처리에 실패했습니다.", underlying: error).localizedDescription
            onDiagnostic("authorization_request_failed")
        }

        do {
            let authorization = try await backend.authorizationStatus()
            let recovered = [.authorized, .provisional, .ephemeral].contains(authorization)
            updateAuthorization(authorization, error: recovered ? nil : requestError)
            onDiagnostic("authorization_status_read")
        } catch {
            updateAuthorization(.error, error: AppOperationFailure(.notificationDelivery, "시스템 알림 처리에 실패했습니다.", underlying: error).localizedDescription)
            onDiagnostic("authorization_status_failed")
        }
    }

    /// 조기 리셋 알림 전달 및 실패 이벤트의 노치 대체 표시
    public func notifyReset(_ reset: EarlyQuotaReset, displayName: String? = nil) async {
        let hasScheduleChange = !reset.scheduleChangedWindows.isEmpty
        DiagnosticLogContext.record(.quotaResetNotification, accountID: reset.accountID, fields: [
            .status: .identifier("attempt"), .reason: .identifier(hasScheduleChange ? "schedule_changed" : "reset")
        ])
        let fallback = QuotaResetNotificationFallback(
            id: UUID().uuidString,
            accountID: reset.accountID,
            windowTitles: reset.windows.map { window in
                hasScheduleChange
                    ? "\(window.title) \(reset.scheduleChangedWindows.contains(window) ? "초기화 일정 변경" : "조기 초기화")"
                    : window.title
            },
            isScheduleChange: hasScheduleChange
        )
        let name = AccountDisplayName.resolved(displayName, slotID: reset.accountID)
        let recovered = reset.windows.filter { !reset.scheduleChangedWindows.contains($0) }
        var messages: [String] = []
        if !recovered.isEmpty {
            messages.append("\(name)의 \(recovered.map(\.title).joined(separator: ", "))가 예정 시각보다 일찍 초기화되었습니다.")
        }
        if hasScheduleChange {
            messages.append("\(name)의 주간 한도 초기화 예정 시각이 크게 변경되었습니다.")
        }
        let body = messages.joined(separator: " ")

        guard await isAuthorizedForDelivery() else {
            status = replacingDelivery(outcome: .fallback, error: nil)
            onDiagnostic("reset_fallback_authorization_unavailable")
            DiagnosticLogContext.record(.quotaResetNotification, accountID: reset.accountID,
                fields: [.status: .identifier("fallback"), .reason: .identifier("authorization_unavailable")])
            onFallback(fallback)
            return
        }

        do {
            try await backend?.deliver(title: hasScheduleChange ? "할당량 초기화 일정 변경" : "할당량 조기 리셋", body: body)
            status = replacingDelivery(outcome: .delivered, error: nil)
            onDiagnostic("reset_notification_delivered")
            DiagnosticLogContext.record(.quotaResetNotification, accountID: reset.accountID,
                fields: [.status: .identifier("delivered")])
        } catch {
            status = replacingDelivery(outcome: .fallback, error: AppOperationFailure(.notificationDelivery, "시스템 알림 처리에 실패했습니다.", underlying: error).localizedDescription)
            onDiagnostic("reset_fallback_delivery_failed")
            DiagnosticLogContext.record(.quotaResetNotification, accountID: reset.accountID,
                fields: [.status: .identifier("fallback"), .reason: .identifier("delivery_failed")])
            onFallback(fallback)
        }
    }

    /// 예정 시각 사전·도달 알림의 시스템 전달과 실패 상태 기록
    @discardableResult
    public func notifyScheduled(_ alert: QuotaResetAlert, displayName: String? = nil) async -> Bool {
        guard await isAuthorizedForDelivery() else {
            status = replacingDelivery(outcome: .failed, error: nil)
            onDiagnostic("scheduled_notification_authorization_unavailable")
            return false
        }
        do {
            let name = AccountDisplayName.resolved(displayName, slotID: alert.accountID)
            let body = alert.body.hasPrefix(alert.accountID)
                ? name + alert.body.dropFirst(alert.accountID.count) : alert.body
            try await backend?.deliver(title: alert.title, body: body)
            status = replacingDelivery(outcome: .delivered, error: nil)
            return true
        } catch {
            status = replacingDelivery(outcome: .failed, error: AppOperationFailure(.notificationDelivery, "시스템 알림 처리에 실패했습니다.", underlying: error).localizedDescription)
            onDiagnostic("scheduled_notification_delivery_failed")
            return false
        }
    }

    /// 자동 Ping 최종 실패의 시스템 알림 및 권한·전달 불가 시 노치 대체
    public func notifyAutomaticPingFailure(_ alert: QuotaResetAlert, displayName: String? = nil) async {
        guard await !notifyScheduled(alert, displayName: displayName) else { return }
        onFallback(QuotaResetNotificationFallback(id: UUID().uuidString, accountID: alert.accountID,
            windowTitles: ["자동 Ping 실패"], isFailure: true))
    }

    /// 사용자 동작으로만 테스트 알림 전달
    public func sendTestNotification() async {
        guard await isAuthorizedForDelivery() else {
            status = replacingDelivery(outcome: .testFailed, error: nil)
            onDiagnostic("test_notification_authorization_unavailable")
            return
        }

        do {
            try await backend?.deliver(
                title: "Codex Quota Checker 테스트 알림",
                body: "시스템 알림 전달 확인용입니다. 할당량 상태는 변경되지 않습니다."
            )
            status = replacingDelivery(outcome: .testDelivered, error: nil)
            onDiagnostic("test_notification_delivered")
        } catch {
            status = replacingDelivery(outcome: .testFailed, error: AppOperationFailure(.notificationDelivery, "시스템 알림 처리에 실패했습니다.", underlying: error).localizedDescription)
            onDiagnostic("test_notification_failed")
        }
    }

    /// 현재 설정을 새로 읽고 실제 전달 가능 여부 반환
    private func isAuthorizedForDelivery() async -> Bool {
        await refreshAuthorization()
        switch status.authorization {
        case .authorized, .provisional, .ephemeral:
            return backend != nil
        case .checking, .notRequested, .denied, .unavailable, .unknown, .error:
            return false
        }
    }

    /// 마지막 전달 결과를 유지하며 권한 상태 갱신
    private func updateAuthorization(
        _ authorization: QuotaResetNotificationAuthorization,
        error: String?
    ) {
        status = QuotaResetNotificationStatus(
            authorization: authorization,
            outcome: status.outcome,
            authorizationError: error,
            deliveryError: status.deliveryError
        )
    }

    /// 현재 권한 상태와 마지막 결과를 유지하며 전달 결과 갱신
    private func replacingDelivery(
        outcome: QuotaResetNotificationOutcome,
        error: String?
    ) -> QuotaResetNotificationStatus {
        QuotaResetNotificationStatus(
            authorization: status.authorization,
            outcome: outcome,
            authorizationError: status.authorizationError,
            deliveryError: error
        )
    }
}
