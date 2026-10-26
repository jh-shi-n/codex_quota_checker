// 목적: 로컬 입력·출력·캐시 토큰과 일별 집계 모델 정의
// 이용처: 세션 기록 집계·SQLite 저장·기여량 표시
// 사용방법: 캐시 필드 미제공 시 nil, 합계는 입력·출력만 사용
import Foundation

/// 음수 정규화가 적용된 토큰 집계; 캐시는 입력의 일부이며 nil은 기록 미제공
public struct TokenUsageTotals: Equatable, Sendable {
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cachedInputTokens: Int64?

    public var totalTokens: Int64 {
        TokenUsageArithmetic.saturatingAdd(inputTokens, outputTokens)
    }

    /// 입력·출력과 선택적 캐시 사용량 초기화; 캐시의 합계 중복 가산 제외
    public init(inputTokens: Int64 = 0, outputTokens: Int64 = 0, cachedInputTokens: Int64? = nil) {
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.cachedInputTokens = cachedInputTokens.map { max(0, $0) }
    }

    public static let zero = Self()

    /// 알려진 캐시 사용량의 포화 합산; 양쪽 모두 미제공인 경우 nil 유지
    public func adding(_ other: Self) -> Self {
        Self(
            inputTokens: TokenUsageArithmetic.saturatingAdd(inputTokens, other.inputTokens),
            outputTokens: TokenUsageArithmetic.saturatingAdd(outputTokens, other.outputTokens),
            cachedInputTokens: cachedInputTokens == nil && other.cachedInputTokens == nil
                ? nil
                : TokenUsageArithmetic.saturatingAdd(cachedInputTokens ?? 0, other.cachedInputTokens ?? 0)
        )
    }
}

/// One rollout/session contribution on one local calendar day.
public struct TokenUsageSessionUsage: Equatable, Sendable {
    public let date: Date
    public let totals: TokenUsageTotals

    public var inputTokens: Int64 { totals.inputTokens }
    public var outputTokens: Int64 { totals.outputTokens }
    public var cachedInputTokens: Int64? { totals.cachedInputTokens }
    public var totalTokens: Int64 { totals.totalTokens }

    public init(date: Date, totals: TokenUsageTotals = .zero) {
        self.date = date
        self.totals = totals
    }

    /// 세션 날짜와 입력·출력·선택적 캐시 사용량 구성
    public init(date: Date, inputTokens: Int64, outputTokens: Int64, cachedInputTokens: Int64? = nil) {
        self.init(
            date: date,
            totals: TokenUsageTotals(inputTokens: inputTokens, outputTokens: outputTokens, cachedInputTokens: cachedInputTokens)
        )
    }
}

/// An already aggregated day used by the dashboard contribution grid.
public struct TokenUsageDailyPoint: Equatable, Sendable {
    public let date: Date
    public let totals: TokenUsageTotals
    public let sessionCount: Int64

    public var inputTokens: Int64 { totals.inputTokens }
    public var outputTokens: Int64 { totals.outputTokens }
    public var cachedInputTokens: Int64? { totals.cachedInputTokens }
    public var totalTokens: Int64 { totals.totalTokens }

    public init(
        date: Date,
        totals: TokenUsageTotals = .zero,
        sessionCount: Int64 = 0
    ) {
        self.date = date
        self.totals = totals
        self.sessionCount = max(0, sessionCount)
    }

    /// 일별 입력·출력·선택적 캐시 사용량과 세션 수 구성
    public init(
        date: Date,
        inputTokens: Int64,
        outputTokens: Int64,
        cachedInputTokens: Int64? = nil,
        sessionCount: Int64 = 0
    ) {
        self.init(
            date: date,
            totals: TokenUsageTotals(inputTokens: inputTokens, outputTokens: outputTokens, cachedInputTokens: cachedInputTokens),
            sessionCount: sessionCount
        )
    }
}

/// Whether a snapshot can be shown. An unavailable snapshot still has a
/// zero-filled day shape when produced by `TokenUsageAggregator`.
public enum TokenUsageAvailability: String, Codable, Equatable, Sendable {
    case available
    case unavailable
}

public enum TokenUsageSnapshotError: String, Codable, Equatable, Sendable {
    case invalidHome
    case sessionsDirectoryUnavailable
    case storageUnavailable
    case superseded
    case fileLimitExceeded
    case rolloutReadFailed
    case cancelled
    case readLimitExceeded

    /// 민감한 경로를 제외한 집계 실패 원인 안내
    public var userMessage: String {
        appErrorCode.message(failureSummary)
    }

    /// 집계 실패의 민감정보 없는 안내
    private var failureSummary: String {
        switch self {
        case .invalidHome: return "계정 경로를 확인해 주세요."
        case .sessionsDirectoryUnavailable: return "로컬 세션 폴더를 읽을 수 없습니다."
        case .storageUnavailable: return "토큰 집계를 DB에 저장하지 못했습니다. 저장 공간과 파일 접근 권한을 확인해 주세요."
        case .superseded: return "계정 설정이 변경되었습니다. 다시 업데이트해 주세요."
        case .fileLimitExceeded: return "세션 파일 수가 집계 상한을 초과했습니다. 일부 파일만 집계한 결과는 표시하지 않습니다."
        case .rolloutReadFailed: return "일부 세션 파일을 읽지 못했습니다. 파일 접근 권한을 확인한 뒤 다시 업데이트해 주세요."
        case .cancelled: return "토큰 집계가 취소되었습니다."
        case .readLimitExceeded: return "세션 기록의 읽기량이 집계 상한을 초과했습니다. 일부 기록만 집계한 결과는 표시하지 않습니다."
        }
    }
}

/// Immutable, privacy-bounded usage data for one configured CODEX_HOME.
public struct TokenUsageSnapshot: Equatable, Sendable {
    public static let historyDayCount = 168

    public let generatedAt: Date
    public let dailyPoints: [TokenUsageDailyPoint]
    /// 실제로 보관된 날짜 목록; nil은 기존 전체 날짜 데이터
    public let recordedDates: [Date]?
    public let today: TokenUsageTotals
    public let last7Days: TokenUsageTotals
    public let last30Days: TokenUsageTotals
    public let totalSessions: Int64
    public let averageTokensPerSession: Double
    public let availability: TokenUsageAvailability
    public let error: TokenUsageSnapshotError?

    /// Compatibility aliases make the snapshot convenient for callers that
    /// refer to the grid as `daily` or the summaries as `*Totals`.
    public var daily: [TokenUsageDailyPoint] { dailyPoints }
    public var points: [TokenUsageDailyPoint] { dailyPoints }
    public var todayTotals: TokenUsageTotals { today }
    public var last7DaysTotals: TokenUsageTotals { last7Days }
    public var last30DaysTotals: TokenUsageTotals { last30Days }
    public var state: TokenUsageAvailability { availability }

    public init(
        generatedAt: Date,
        dailyPoints: [TokenUsageDailyPoint],
        today: TokenUsageTotals = .zero,
        last7Days: TokenUsageTotals = .zero,
        last30Days: TokenUsageTotals = .zero,
        totalSessions: Int64 = 0,
        averageTokensPerSession: Double = 0,
        availability: TokenUsageAvailability = .available,
        error: TokenUsageSnapshotError? = nil,
        recordedDates: [Date]? = nil
    ) {
        self.generatedAt = generatedAt
        self.dailyPoints = dailyPoints
        self.recordedDates = recordedDates
        self.today = today
        self.last7Days = last7Days
        self.last30Days = last30Days
        self.totalSessions = max(0, totalSessions)
        self.averageTokensPerSession = averageTokensPerSession.isFinite
            ? max(0, averageTokensPerSession)
            : 0
        self.availability = availability
        self.error = error
    }

    public init(
        generatedAt: Date,
        daily: [TokenUsageDailyPoint],
        today: TokenUsageTotals = .zero,
        last7Days: TokenUsageTotals = .zero,
        last30Days: TokenUsageTotals = .zero,
        totalSessions: Int64 = 0,
        averageTokensPerSession: Double = 0,
        availability: TokenUsageAvailability = .available,
        error: TokenUsageSnapshotError? = nil,
        recordedDates: [Date]? = nil
    ) {
        self.init(
            generatedAt: generatedAt,
            dailyPoints: daily,
            today: today,
            last7Days: last7Days,
            last30Days: last30Days,
            totalSessions: totalSessions,
            averageTokensPerSession: averageTokensPerSession,
            availability: availability,
            error: error, recordedDates: recordedDates
        )
    }
    /// 원본 집계 시각을 유지한 현재 날짜 기준 기간 요약 재계산
    public func rebased(to referenceDate: Date, calendar: Calendar = .autoupdatingCurrent) -> Self {
        guard !calendar.isDate(generatedAt, inSameDayAs: referenceDate) else { return self }
        let rebased = TokenUsageAggregator(calendar: calendar, dayCount: dailyPoints.count).aggregate(
            dailyPoints: dailyPoints,
            generatedAt: referenceDate,
            availability: availability,
            error: error
        )
        return Self(
            generatedAt: generatedAt,
            dailyPoints: rebased.dailyPoints,
            today: rebased.today,
            last7Days: rebased.last7Days,
            last30Days: rebased.last30Days,
            totalSessions: rebased.totalSessions,
            averageTokensPerSession: rebased.averageTokensPerSession,
            availability: availability,
            error: error, recordedDates: recordedDates
        )
    }

    /// 날짜가 경과해도 달력 개월 보관 경계와 실제 수집 날짜를 맞추는 표시 집계
    public func retained(months: Int, at referenceDate: Date, calendar: Calendar = .autoupdatingCurrent) -> Self {
        let cutoff = TokenUsageOptions(retentionMonths: months).cutoff(at: referenceDate, calendar: calendar)
        let today = calendar.startOfDay(for: referenceDate)
        let count = (calendar.dateComponents([.day], from: cutoff, to: today).day ?? 0) + 1
        let result = TokenUsageAggregator(calendar: calendar, dayCount: count).aggregate(
            dailyPoints: dailyPoints.filter { $0.date >= cutoff && $0.date <= today }, generatedAt: referenceDate)
        return Self(generatedAt: generatedAt, dailyPoints: result.dailyPoints,
            today: result.today, last7Days: result.last7Days, last30Days: result.last30Days,
            totalSessions: result.totalSessions, averageTokensPerSession: result.averageTokensPerSession,
            availability: availability, error: error,
            recordedDates: recordedDates?.filter { $0 >= cutoff && $0 <= today })
    }

}

/// A home-based provider contract keeps account credentials and account
/// metadata out of the usage reader.
public protocol TokenUsageProvider: Sendable {
    func snapshot(home: URL) async -> TokenUsageSnapshot
}

/// 보관 정책에 맞춘 수집 범위를 지원하는 선택적 제공자 경계
public protocol TokenUsageRangeProvider: TokenUsageProvider {
    /// 지정된 최근 날짜 범위의 로컬 집계 반환
    func snapshot(home: URL, historyDayCount: Int) async -> TokenUsageSnapshot
}

public typealias LocalTokenUsageProviding = TokenUsageProvider

public enum TokenUsageArithmetic {
    @inline(__always)
    public static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        if rhs > 0 && lhs > Int64.max - rhs { return Int64.max }
        if rhs < 0 && lhs < Int64.min - rhs { return Int64.min }
        return lhs + rhs
    }
}

public typealias DailyTokenUsage = TokenUsageDailyPoint
public typealias TokenUsageDay = TokenUsageDailyPoint
public typealias TokenUsageSummary = TokenUsageTotals
public typealias TokenUsageRolloutUsage = TokenUsageSessionUsage
