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

    /// 조기 초기화 중 리셋권 사용·사용 여부 불명확한 조회 제외
    public static func detect(
        previous: PreferencesStore.QuotaSnapshot?,
        current: AccountState,
        now: Date = Date()
    ) -> EarlyQuotaReset? {
        guard current.status == .normal, let previous else { return nil }
        var windows: [Window] = []
        if didReset(
            previousUsed: previous.primaryUsedPercent,
            currentUsed: current.primaryUsedPercent,
            previousReset: previous.primaryResetAt,
            currentReset: current.primaryResetAt,
            now: now
        ) {
            windows.append(.primary)
        }
        if didReset(
            previousUsed: previous.secondaryUsedPercent,
            currentUsed: current.secondaryUsedPercent,
            previousReset: previous.secondaryResetAt,
            currentReset: current.secondaryResetAt,
            now: now
        ) {
            windows.append(.secondary)
        }
        guard !windows.isEmpty,
              let credits = current.resetCredits,
              credits.usageEvidence(comparedTo: previous.resetCredits, now: now) == .notObserved
        else { return nil }
        return EarlyQuotaReset(accountID: current.id, windows: windows)
    }

    /// 사용량 0 도달 또는 새 리셋 구간 진입을 동반한 사용량 감소 확인
    private static func didReset(
        previousUsed: Double?,
        currentUsed: Double?,
        previousReset: Date?,
        currentReset: Date?,
        now: Date
    ) -> Bool {
        guard let previousUsed, let currentUsed,
              let previousReset, now < previousReset,
              currentUsed < previousUsed
        else { return false }
        return currentUsed == 0 || currentReset.map { $0 > previousReset } == true
    }
}
