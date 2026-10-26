// 목적: 서버 일별 합계를 잔디·주간 차트의 날짜 셀로 구성
// 이용처: 계정 토큰 그래프와 날짜 선택 상세
// 사용방법: 서버 날짜 문자열을 UTC 달력 좌표로만 변환; 미제공 값은 nil 유지
import Foundation

/// 실제 0·미제공·미래 날짜를 구분한 서버 사용량 셀
struct AccountUsageCalendar {
    struct Day: Identifiable, Equatable {
        let date: Date
        let tokens: Int64?
        let isFuture: Bool
        let segment: Int
        var isLocal = false
        var id: Date { date }
    }
    static var calendar: Calendar {
        AccountTokenUsage.reportingCalendar
    }
    let today: Date
    let cutoff: Date
    private let values: [Date: Int64]
    private let localTokens: Int64?

    /// 서버 날짜의 시간대 이동 없이 표시 범위와 제공 수치 구성
    init(snapshot: AccountTokenUsage?, localToday: TokenUsageSnapshot? = nil, now: Date = Date(), months: Int = 12) {
        let calendar = Self.calendar
        today = calendar.startOfDay(for: now)
        cutoff = TokenUsageOptions(retentionMonths: months).cutoff(at: now, calendar: calendar)
        values = Dictionary((snapshot?.days ?? []).compactMap { day in
            Self.date(day.date).map { ($0, day.tokens) }
        }, uniquingKeysWith: { _, last in last })
        if let localToday, localToday.availability == .available,
           calendar.isDate(localToday.generatedAt, inSameDayAs: now) {
            localTokens = localToday.today.totalTokens
        } else { localTokens = nil }
    }

    /// 최근 24주 고정 셀 구성; 누락 날짜의 0 채움 제외
    var heatmap: [Day] {
        days(start: Self.calendar.date(byAdding: .day, value: -167, to: today)!, count: 168)
    }

    /// 월~일 주간 범위와 누락 날짜에서 끊기는 선 구간 구성
    func week(offset: Int) -> [Day] {
        let current = Self.calendar.dateInterval(of: .weekOfYear, for: today)!.start
        let bounded = min(0, max(minimumWeekOffset, offset))
        return days(start: Self.calendar.date(byAdding: .day, value: bounded * 7, to: current)!, count: 7)
    }

    var minimumWeekOffset: Int {
        let current = Self.calendar.dateInterval(of: .weekOfYear, for: today)!.start
        let first = Self.calendar.dateInterval(of: .weekOfYear, for: cutoff)!.start
        return -max(0, (Self.calendar.dateComponents([.day], from: first, to: current).day ?? 0) / 7)
    }

    /// 선택 날짜가 없으면 오늘의 서버 제공 여부 반환
    func day(at date: Date?) -> Day {
        days(start: date.map { Self.calendar.startOfDay(for: $0) } ?? today, count: 1)[0]
    }

    /// 유효한 제공 날짜만 수치 부여; 누락 구간마다 선 식별자 증가
    private func days(start: Date, count: Int) -> [Day] {
        var segment = 0
        return (0..<count).map { index in
            let date = Self.calendar.date(byAdding: .day, value: index, to: start)!
            let isLocal = date == today && values[date] == nil && localTokens != nil
            let tokens = date >= cutoff && date <= today ? (values[date] ?? (isLocal ? localTokens : nil)) : nil
            if tokens == nil { segment += 1 }
            return Day(date: date, tokens: tokens, isFuture: date > today, segment: segment, isLocal: isLocal)
        }
    }

    /// 검증된 서버 날짜를 시간대 독립 달력 좌표로 변환
    static func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// 서버의 연월일을 그대로 유지하는 날짜 표시
    static func label(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}
