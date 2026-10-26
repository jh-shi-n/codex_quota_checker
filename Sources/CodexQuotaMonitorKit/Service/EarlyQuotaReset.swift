// 목적: 예정 시각 이전의 계정별 할당량 초기화 판별
// 이용처: 정상 한도 조회 결과 반영 직전
// 사용방법: 이전 정상 스냅샷과 새 상태를 detect에 전달
import Foundation

/// 계정과 초기화된 한도 종류를 포함한 조기 리셋 이벤트
public struct EarlyQuotaReset: Equatable, Sendable {
    public let accountID: String
    public let windows: [Window]
    public let scheduleChangedWindows: [Window]

    /// 실제 회복 구간과 일정 변경 구간을 구분한 알림 정보 구성
    public init(accountID: String, windows: [Window], scheduleChangedWindows: [Window] = []) {
        self.accountID = accountID
        self.windows = windows
        self.scheduleChangedWindows = scheduleChangedWindows
    }

    /// 큰 주간 일정 변경의 알림 기준: 조회 간격에 따른 이동을 제외한 1시간 이상 변화
    public static let weeklyScheduleChangeThreshold: TimeInterval = 3_600

    /// 사용량 회복과 독립적인 주간 일정 변경의 알림 대상 구성
    public static func notification(accountID: String, changes: [QuotaResetChange], now: Date) -> Self? {
        let early = changes.filter { $0.previousReset > now }
        let resets = early.filter { $0.kind == .reset }.map(\.window)
        let schedules = early.filter { change in
            change.kind == .scheduleChanged && change.window == .secondary &&
            change.currentReset.map { date in
                date > now &&
                abs(date.timeIntervalSince(change.previousReset)) >= weeklyScheduleChangeThreshold &&
                abs(change.scheduleShift) >= weeklyScheduleChangeThreshold
            } == true
        }.map(\.window)
        let windows = [Window.primary, .secondary].filter { resets.contains($0) || schedules.contains($0) }
        return windows.isEmpty ? nil : Self(accountID: accountID, windows: windows, scheduleChangedWindows: schedules)
    }

    /// 서로 독립적으로 초기화되는 할당량 구간
    public enum Window: String, Equatable, Sendable {
        case primary
        case secondary

        public var title: String {
            switch self {
            case .primary: "5시간 한도"
            case .secondary: "전체 한도"
            }
        }
    }

    /// 주간 소진 중 5시간 초기화 알림만 제외하고 주간 초기화 알림 유지
    public func suppressingUnavailablePrimary(weeklyRemaining: Double?) -> Self? {
        let allowed = windows.filter { $0 != .primary || weeklyRemaining != 0 }
        return allowed.isEmpty ? nil : Self(accountID: accountID, windows: allowed,
            scheduleChangedWindows: scheduleChangedWindows.filter { allowed.contains($0) })
    }

    /// 원인 분류와 독립적인 조기 초기화 감지의 이전 스냅샷 호환 경계
    public static func detect(
        previous: PreferencesStore.QuotaSnapshot?,
        current: AccountState,
        now: Date = Date()
    ) -> EarlyQuotaReset? {
        guard current.status == .normal, let previous else { return nil }
        var before = AccountState(
            id: current.id, email: current.email, planType: current.planType,
            primaryUsedPercent: previous.primaryUsedPercent, secondaryUsedPercent: previous.secondaryUsedPercent,
            primaryResetAt: previous.primaryResetAt, secondaryResetAt: previous.secondaryResetAt,
            resetCredits: previous.resetCredits, lastUpdated: previous.lastUpdated, status: .normal
        )
        before.configurationGeneration = current.configurationGeneration
        return notification(accountID: current.id,
            changes: QuotaResetChange.detect(previous: before, current: current, now: now), now: now)
    }
}
