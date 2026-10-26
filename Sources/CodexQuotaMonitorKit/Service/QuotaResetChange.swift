// 목적: 할당량 초기화 감지·일정 변경·원인 분류의 공통 판정
// 이용처: 계정 관측 구간·조기 알림·자동 Ping·예약 유효성 확인
// 사용방법: 동일 계정의 이전·현재 정상 서버 스냅샷을 detect에 전달
import Foundation

/// 관측 가능한 초기화 근거와 추정 원인을 분리한 한도별 변화
public struct QuotaResetChange: Equatable, Sendable {
    public enum Kind: String, Sendable { case reset, scheduleChanged }
    public enum Cause: String, Sendable { case scheduled, resetCredit, unknown }
    public let window: EarlyQuotaReset.Window
    public let kind: Kind
    public let cause: Cause
    public let previousReset: Date
    public let currentReset: Date?
    public let scheduleShift: TimeInterval

    /// 계정 식별·조회 순서 확인 후 사용량 회복과 시각 변경의 독립 판정
    public static func detect(previous: AccountState, current: AccountState, now: Date = Date()) -> [Self] {
        guard previous.status == .normal, current.status == .normal,
              previous.id == current.id,
              previous.configurationGeneration == current.configurationGeneration,
              previous.email == current.email, previous.planType == current.planType else { return [] }
        if let old = previous.lastUpdated, let latest = current.lastUpdated, latest <= old { return [] }
        let evidence = current.resetCredits?.usageEvidence(comparedTo: previous.resetCredits, now: now)
        return [EarlyQuotaReset.Window.primary, .secondary].compactMap { window in
            let oldReset = window == .primary ? previous.primaryResetAt : previous.secondaryResetAt
            let reset = window == .primary ? current.primaryResetAt : current.secondaryResetAt
            let oldUsed = window == .primary ? previous.primaryUsedPercent : previous.secondaryUsedPercent
            let used = window == .primary ? current.primaryUsedPercent : current.secondaryUsedPercent
            guard let oldReset, oldReset.timeIntervalSince1970.isFinite else { return nil }
            let recovered = oldUsed.flatMap { old in used.map { $0 < old && ($0 == 0 || reset.map { $0 > oldReset.addingTimeInterval(ResetTimeTracker.resetTolerance) } == true) } } == true
            if recovered {
                let cause: Cause = evidence == .used ? .resetCredit : (oldReset <= now ? .scheduled : .unknown)
                return Self(window: window, kind: .reset, cause: cause, previousReset: oldReset, currentReset: reset, scheduleShift: 0)
            }
            guard let reset, reset.timeIntervalSince1970.isFinite else { return nil }
            let delta = reset.timeIntervalSince(oldReset)
            let elapsed = current.lastUpdated.flatMap { latest in previous.lastUpdated.map { latest.timeIntervalSince($0) } }
            guard abs(delta) > ResetTimeTracker.resetTolerance,
                  elapsed.map({ abs(delta - $0) > ResetTimeTracker.resetTolerance }) ?? true else { return nil }
            return Self(window: window, kind: .scheduleChanged, cause: evidence == .used ? .resetCredit : .unknown,
                previousReset: oldReset, currentReset: reset, scheduleShift: delta - (elapsed ?? 0))
        }
    }
}
