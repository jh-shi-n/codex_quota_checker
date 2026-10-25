// 목적: 예정 시각 이전의 계정별 할당량 초기화 판별
// 이용처: 정상 한도 조회 결과 반영 직전
// 사용방법: 이전 정상 스냅샷과 새 상태를 detect에 전달
import Foundation

/// 계정과 초기화된 한도 종류를 포함한 조기 리셋 이벤트
public struct EarlyQuotaReset: Equatable, Sendable {
    public let accountID: String
    public let windows: [Window]

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
        return allowed.isEmpty ? nil : Self(accountID: accountID, windows: allowed)
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
        let windows = QuotaResetChange.detect(previous: before, current: current, now: now)
            .filter { $0.kind == .reset && $0.previousReset > now }.map(\.window)
        guard !windows.isEmpty else { return nil }
        return EarlyQuotaReset(accountID: current.id, windows: windows)
    }
}
