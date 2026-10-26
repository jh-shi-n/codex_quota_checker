// 목적: 정상 조회 이력에 따른 초기화 시각의 안정·이동 관측
// 이용처: 계정별·한도별 초기화 예정 시각 표시
// 사용방법: 새 정상 조회마다 observe 호출; 실패·계정 변경 시 이력 폐기
import Foundation

/// 서버 상태 확정과 구분되는 초기화 시각 관측 결과
public enum ResetTimeObservation: String, Equatable, Sendable {
    case checking
    case stableObserved
    case movingObserved
}

/// 동일 초기화 구간에서 재사용 가능한 고정 관측 근거
public struct ResetTimeEvidence: Codable, Equatable, Sendable {
    public let resetAt: Date
    public let observedAt: Date

    /// 실제 고정 관측의 시각과 조회 시점 보관
    public init(resetAt: Date, observedAt: Date) {
        self.resetAt = resetAt
        self.observedAt = observedAt
    }

    /// 만료·시계 역행·일정 변경 시 기존 근거 폐기
    public func matches(_ reset: Date?, now: Date = Date()) -> Bool {
        guard let reset, reset.timeIntervalSince1970.isFinite,
              resetAt.timeIntervalSince1970.isFinite, observedAt.timeIntervalSince1970.isFinite,
              observedAt <= now.addingTimeInterval(2), observedAt < resetAt,
              resetAt > now, reset > now else { return false }
        return abs(reset.timeIntervalSince(resetAt)) <= ResetTimeTracker.resetTolerance
    }
}

/// 최신 시각과 독립적인 간격·오차 기반 관측 및 구간 식별
struct ResetTimeTracker: Sendable {
    static let tolerance: TimeInterval = 2
    static let resetTolerance: TimeInterval = 3
    /// 서버 초기화 시각과 벽시계·단조 시계의 관측 기준
    private struct Sample: Sendable {
        let resetAt: Date
        let observedAt: Date
        let uptime: TimeInterval
    }

    private var samples: [Sample] = []
    private(set) var observation: ResetTimeObservation = .checking
    private(set) var segmentID = UUID()

    /// 새 초기화·일정 변경 이후 이전 관측 근거 폐기
    mutating func restart() { self = Self() }

    /// 유효한 시각 즉시 반영; 만료·누락 제외 및 경과 시간에 비례한 이동 판별
    mutating func observe(
        resetAt: Date?, observedAt: Date, uptime: TimeInterval,
        maximumGap: TimeInterval = 900
    ) -> ResetTimeObservation {
        guard let resetAt,
              resetAt.timeIntervalSince1970.isFinite,
              observedAt.timeIntervalSince1970.isFinite,
              uptime.isFinite, resetAt > observedAt
        else {
            restart()
            return observation
        }
        let next = Sample(resetAt: resetAt, observedAt: observedAt, uptime: uptime)
        if let last = samples.last {
            let elapsed = observedAt.timeIntervalSince(last.observedAt)
            let monotonicElapsed = uptime - last.uptime
            if elapsed <= 0 { return observation }
            if elapsed > maximumGap || monotonicElapsed < 0
                || abs(elapsed - monotonicElapsed) > Self.tolerance || last.resetAt <= observedAt {
                restart()
                samples = [next]
                return observation
            }
            let resetDelta = resetAt.timeIntervalSince(last.resetAt)
            if abs(resetDelta) > Self.resetTolerance && abs(resetDelta - elapsed) > Self.resetTolerance {
                restart()
                samples = [next]
                return observation
            }
            // 짧은 간격의 비례 이동을 고정으로 오인하지 않는 상대 오차 적용
            let stableTolerance = min(Self.resetTolerance, elapsed / 3)
            if abs(resetDelta) <= stableTolerance {
                samples = [next]
                observation = .stableObserved
                return observation
            }
        }
        samples.append(next)
        samples = Array(samples.suffix(3))
        guard samples.count == 3, let first = samples.first else {
            observation = .checking
            return observation
        }
        let movingTolerance = min(Self.resetTolerance, observedAt.timeIntervalSince(first.observedAt) / 3)
        let moving = samples.allSatisfy {
            abs($0.resetAt.timeIntervalSince(first.resetAt)
                - $0.observedAt.timeIntervalSince(first.observedAt)) <= movingTolerance
        }
        let fixedWithJitter = !moving && samples.allSatisfy {
            abs($0.resetAt.timeIntervalSince(first.resetAt)) <= Self.resetTolerance
        } && abs(resetAt.timeIntervalSince(first.resetAt)) <= movingTolerance
        if fixedWithJitter {
            observation = .stableObserved
            samples = [next]
        } else {
            observation = moving ? .movingObserved : .checking
            if !moving { samples = Array(samples.suffix(2)) }
        }
        return observation
    }
}
