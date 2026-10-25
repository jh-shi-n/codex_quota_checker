// 목적: 토큰 차트 표시와 달력 기준 보관 정책 정의
// 이용처: 설정 저장·장기 집계·주간 차트
// 사용방법: 기본값으로 이전 설정 복원 후 정규화된 옵션 적용
import Foundation

/// 일별 사용량 비교에 사용할 차트 형태
public enum TokenChartStyle: String, Codable, CaseIterable, Sendable {
    case bar, line
    public var title: String { self == .bar ? "막대" : "선" }
}

/// 기존 차트 사용 여부와 형태를 결합한 화면 선택값
public enum TokenUsageDisplayMode: String, CaseIterable, Sendable {
    case heatmap, weeklyBar, weeklyLine

    /// 설정 선택 메뉴의 표시 이름 제공
    public var title: String {
        switch self {
        case .heatmap: "잔디"
        case .weeklyBar: "주간 막대"
        case .weeklyLine: "주간 선"
        }
    }
}

/// 표시 여부와 독립적으로 유지되는 일별 집계 보관 정책
public struct TokenUsageOptions: Codable, Equatable, Sendable {
    public static let retentionChoices = [3, 6, 12]
    public static let maximumHistoryDays = 367
    public var weeklyChartEnabled: Bool
    public var chartStyle: TokenChartStyle
    public var retentionMonths: Int

    /// 기존 사용자의 잔디 유지 및 1년 보관 기본값 구성
    public init(weeklyChartEnabled: Bool = false, chartStyle: TokenChartStyle = .bar, retentionMonths: Int = 12) {
        self.weeklyChartEnabled = weeklyChartEnabled
        self.chartStyle = chartStyle
        self.retentionMonths = Self.retentionChoices.contains(retentionMonths) ? retentionMonths : 12
    }

    /// 기존 저장 필드와 통합 표시 선택의 양방향 변환 및 잔디 전환 시 이전 차트 형태 보존
    public var displayMode: TokenUsageDisplayMode {
        get { weeklyChartEnabled ? (chartStyle == .bar ? .weeklyBar : .weeklyLine) : .heatmap }
        set {
            weeklyChartEnabled = newValue != .heatmap
            if newValue == .weeklyBar { chartStyle = .bar }
            if newValue == .weeklyLine { chartStyle = .line }
        }
    }

    private enum CodingKeys: String, CodingKey { case weeklyChartEnabled, chartStyle, retentionMonths }

    /// 이전 파일의 누락 필드와 알 수 없는 선택값을 기본값으로 복원
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            weeklyChartEnabled: try values.decodeIfPresent(Bool.self, forKey: .weeklyChartEnabled) ?? false,
            chartStyle: TokenChartStyle(rawValue: try values.decodeIfPresent(String.self, forKey: .chartStyle) ?? "bar") ?? .bar,
            retentionMonths: try values.decodeIfPresent(Int.self, forKey: .retentionMonths) ?? 12
        )
    }

    /// 달력 개월 수 이전의 날짜를 포함하는 보관 시작일 반환
    public func cutoff(at date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        let months = Self.retentionChoices.contains(retentionMonths) ? retentionMonths : 12
        return calendar.startOfDay(for: calendar.date(byAdding: .month, value: -months, to: date) ?? date)
    }
}
