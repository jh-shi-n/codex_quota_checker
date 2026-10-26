// 목적: Ping 이후 전송과 독립적인 한도별 시각 고정 확인
// 이용처: 수동·자동 Ping의 공통 후속 조회
// 사용방법: 전송 성공 후 confirm 호출, 조회·시계·대기 주입 가능
import Foundation

/// 시각 관측·조회 실패·새 구간 전환의 구분
public enum ResetTimeConfirmationStatus: String, Equatable, Sendable {
    case checking, stableObserved, movingObserved, unavailable, superseded

    /// 전송 성공 여부와 독립적인 한도별 화면 문구
    public var text: String {
        switch self {
        case .checking: "확인 중"
        case .stableObserved: "고정 관측"
        case .movingObserved: "변동 중"
        case .unavailable: "조회 미확인"
        case .superseded: "새 구간 재관측"
        }
    }
}

/// 계정·관측 구간에 귀속되는 제한된 후속 조회 결과
public struct ResetTimeConfirmationResult: Equatable, Sendable {
    public let primary: ResetTimeConfirmationStatus
    public let secondary: ResetTimeConfirmationStatus
    public let account: AccountState?
    public let lastRefreshSucceeded: Bool
    public let isCurrentAccount: Bool
    public let queryCount: Int

    /// 대상 구간의 안정성 확인 여부 반환
    public func isStable(for windows: [EarlyQuotaReset.Window] = [.primary, .secondary]) -> Bool {
        windows.allSatisfy { ($0 == .primary ? primary : secondary) == .stableObserved }
    }
}

/// 계정 상세 수명과 독립적인 최대 네 번의 조회·중복 응답 배제
@MainActor
public final class ResetTimeConfirmationService {
    private let refresh: @MainActor (String) async -> AccountState?
    private let current: @MainActor (String) -> AccountState?
    private let now: @MainActor () -> Date
    private let sleep: @MainActor (TimeInterval) async throws -> Void

    /// 실제 갱신·현재 상태·시계·10초 대기 연결
    public init(
        refresh: @escaping @MainActor (String) async -> AccountState?,
        current: @escaping @MainActor (String) -> AccountState?,
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.refresh = refresh
        self.current = current
        self.now = now
        self.sleep = sleep
    }

    /// 즉시 조회 후 10초 간격 최대 3회 확인; 추가 Ping 전송 제외
    public func confirm(_ account: AccountState) async -> ResetTimeConfirmationResult {
        var primary: ResetTimeConfirmationStatus = .checking
        var secondary: ResetTimeConfirmationStatus = .checking
        var primarySegment: UUID?
        var secondarySegment: UUID?
        var latest: AccountState?
        var lastUpdated = account.lastUpdated
        var succeeded = false
        var queries = 0
        var isCurrent = true
        var identity = account
        for attempt in 0...3 {
            if attempt > 0 {
                do { try await sleep(10) }
                catch { isCurrent = false; break }
            }
            guard !Task.isCancelled, let active = current(account.id), sameIdentity(identity, active),
                  ![.notConfigured, .loginRequired, .codexNotFound].contains(active.status) else {
                isCurrent = false
                break
            }
            if primarySegment != nil, active.primaryResetSegmentID != primarySegment { primary = .superseded }
            if secondarySegment != nil, active.secondaryResetSegmentID != secondarySegment { secondary = .superseded }
            if primary == .superseded && secondary == .superseded { break }
            let fresh = await refresh(account.id)
            queries += 1
            guard !Task.isCancelled, let active = current(account.id), sameIdentity(identity, active),
                  ![.notConfigured, .loginRequired, .codexNotFound].contains(active.status) else {
                isCurrent = false
                break
            }
            if let fresh, !sameIdentity(identity, fresh) || !sameIdentity(fresh, active) { isCurrent = false; break }
            // 조회 시각의 단조 증가를 확인하여 재사용 응답을 관측 근거에서 제외
            if let fresh, let updated = fresh.lastUpdated {
                succeeded = fresh.status == .normal && active.status == .normal && abs(updated.timeIntervalSince(now())) <= 30
                    && (lastUpdated.map { updated > $0 } ?? true)
                    && (active.lastUpdated.map { updated >= $0 } ?? true)
            } else { succeeded = false }
            if succeeded, let fresh {
                identity = fresh
                if fresh.primaryResetSegmentID != active.primaryResetSegmentID { primary = .superseded }
                if fresh.secondaryResetSegmentID != active.secondaryResetSegmentID { secondary = .superseded }
                latest = fresh
                lastUpdated = fresh.lastUpdated
                if primarySegment != nil, fresh.primaryResetSegmentID != primarySegment { primary = .superseded }
                if secondarySegment != nil, fresh.secondaryResetSegmentID != secondarySegment { secondary = .superseded }
                if primary != .superseded {
                    primarySegment = fresh.primaryResetSegmentID
                    primary = status(fresh.primaryResetObservation, reset: fresh.primaryResetAt)
                }
                if secondary != .superseded {
                    secondarySegment = fresh.secondaryResetSegmentID
                    secondary = status(fresh.secondaryResetObservation, reset: fresh.secondaryResetAt)
                }
            } else {
                if primary != .superseded { primary = .unavailable }
                if secondary != .superseded { secondary = .unavailable }
            }
            DiagnosticLogContext.record(.resetConfirmationUpdated, accountID: account.id, fields: [
                .attempt: .integer(queries), .observation: .identifier("\(primary.rawValue)_\(secondary.rawValue)")
            ])
            if [.stableObserved, .superseded].contains(primary) && [.stableObserved, .superseded].contains(secondary) { break }
        }
        return ResetTimeConfirmationResult(primary: primary, secondary: secondary, account: latest,
            lastRefreshSucceeded: succeeded, isCurrentAccount: isCurrent, queryCount: queries)
    }

    /// 유효한 미래 시각과 관측 결과의 공통 확인 상태 변환
    private func status(_ observation: ResetTimeObservation, reset: Date?) -> ResetTimeConfirmationStatus {
        guard let reset, reset.timeIntervalSince1970.isFinite, reset > now() else { return .unavailable }
        switch observation {
        case .checking: return .checking
        case .stableObserved: return .stableObserved
        case .movingObserved: return .movingObserved
        }
    }

    /// 전송 대상 계정의 경로 세대·로그인·구독 일치 확인
    private func sameIdentity(_ lhs: AccountState, _ rhs: AccountState) -> Bool {
        lhs.acceptsIdentity(of: rhs)
    }
}
