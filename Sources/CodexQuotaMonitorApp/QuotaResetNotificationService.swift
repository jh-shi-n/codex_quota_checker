// 목적: macOS 시스템 알림 어댑터와 조기 리셋 전달 연결
// 이용처: 앱 시작, 설정의 권한·테스트 동작, 조기 리셋 이벤트
// 사용방법: start 호출 후 retryAuthorization·sendTestNotification·notify 사용
import Foundation
import OSLog
import UserNotifications
import CodexQuotaMonitorKit

/// 앱 번들의 알림 권한 조회와 노치 대체 전달 관리
@MainActor
final class QuotaResetNotificationService: NSObject, UNUserNotificationCenterDelegate {
    let delivery: QuotaResetNotificationDelivery

    private let center: UNUserNotificationCenter?
    private let logger = Logger(subsystem: "com.example.codexquotamonitor", category: "QuotaResetNotification")

    /// 앱 번들에 한해 시스템 알림 어댑터 구성
    init(
        onFallback: @escaping @MainActor @Sendable (QuotaResetNotificationFallback) -> Void
    ) {
        let center = Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
        self.center = center
        let backend = center.map(UNQuotaResetNotificationBackend.init(center:))
        self.delivery = QuotaResetNotificationDelivery(
            backend: backend,
            onFallback: onFallback,
            onDiagnostic: { [logger] event in
                logger.notice("\(event, privacy: .public)")
            }
        )
        super.init()
    }

    /// 앱 시작 시 시스템 알림 권한 상태만 조회
    func start() {
        center?.delegate = self
        Task { await delivery.start() }
    }

    /// 설정 화면의 사용자 동작에 따른 권한 요청·재확인
    func retryAuthorization() {
        Task { await delivery.requestAuthorization() }
    }

    /// 설정 화면의 사용자 동작에 따른 테스트 알림 전달
    func sendTestNotification() {
        Task { await delivery.sendTestNotification() }
    }

    /// 감지된 조기 리셋의 시스템 알림 전달 시도
    func notify(_ reset: EarlyQuotaReset, displayName: String? = nil) {
        logger.notice("reset_detected windows=\(reset.windows.count, privacy: .public)")
        Task { await delivery.notifyReset(reset, displayName: displayName) }
    }

    /// 앱 전면 실행 중 배너와 알림 센터 표시
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

/// UserNotifications 프레임워크 접근을 공통 전달 계약에 연결
@MainActor
private final class UNQuotaResetNotificationBackend: QuotaResetNotificationBackend {
    private let center: UNUserNotificationCenter

    /// 공유 알림 센터 주입
    init(center: UNUserNotificationCenter) {
        self.center = center
    }

    /// SDK의 Sendable 지원과 무관하게 권한 값만 액터 경계로 전달
    func authorizationStatus() async throws -> QuotaResetNotificationAuthorization {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                let authorization: QuotaResetNotificationAuthorization = switch settings.authorizationStatus {
                case .notDetermined:
                    .notRequested
                case .denied:
                    .denied
                case .authorized:
                    .authorized
                case .provisional:
                    .provisional
                case .ephemeral:
                    .ephemeral
                @unknown default:
                    .unknown
                }
                continuation.resume(returning: authorization)
            }
        }
    }

    /// 시스템 알림 권한 요청
    func requestAuthorization() async throws {
        _ = try await center.requestAuthorization(options: [.alert])
    }

    /// 조용한 즉시 표시 알림 전달
    func deliver(title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }
}
