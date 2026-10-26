// 목적: 서버 계정 토큰 합계와 로컬 상세 집계의 범위 분리
// 이용처: 계정 상세의 서버 일별 사용량 표시
// 사용방법: account/usage/read 성공 응답만 검증 후 구성
import Foundation

/// 서버 날짜 문자열 그대로 유지하는 일별 계정 토큰 합계
public struct AccountTokenUsage: Equatable, Sendable {
    /// 서버 일별 버킷과 로컬 보완 집계에 공통 적용하는 UTC 날짜 기준
    public static var reportingCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    public struct Day: Equatable, Sendable, Identifiable {
        public let date: String
        public let tokens: Int64
        public var id: String { date }
    }
    public let fetchedAt: Date
    public let accountEmail: String?
    public let lifetimeTokens: Int64?
    public let peakDailyTokens: Int64?
    /// nil은 서버 미제공, 빈 배열은 서버가 반환한 빈 목록
    public let days: [Day]?

    /// 누락·null 유지 및 잘못된 숫자·날짜·중복 날짜의 전체 응답 거절
    public init(result: CodexJSONValue, fetchedAt: Date = Date(), accountEmail: String? = nil) throws {
        guard let object = result.objectValue, let summary = object["summary"]?.objectValue else {
            throw CodexQuotaServiceError.malformedResponse("Missing token usage summary")
        }
        self.fetchedAt = fetchedAt
        self.accountEmail = accountEmail
        lifetimeTokens = try Self.counter(summary["lifetimeTokens"])
        peakDailyTokens = try Self.counter(summary["peakDailyTokens"])
        if let raw = object["dailyUsageBuckets"], raw != .null {
            guard let buckets = raw.arrayValue else { throw Self.invalidResponse }
            var dates = Set<String>()
            days = try buckets.map { bucket in
                guard let value = bucket.objectValue,
                      let date = value["startDate"]?.stringValue,
                      Self.validDate(date), dates.insert(date).inserted,
                      let tokens = try Self.counter(value["tokens"]) else { throw Self.invalidResponse }
                return Day(date: date, tokens: tokens)
            }.sorted { $0.date < $1.date }
        } else { days = nil }
    }

    private static let invalidResponse = CodexQuotaServiceError.malformedResponse("Invalid token usage data")

    /// Double 기반 전송 모델의 정수 정밀도 범위 밖 숫자 거절
    private static func counter(_ value: CodexJSONValue?) throws -> Int64? {
        guard let value, value != .null else { return nil }
        guard let number = value.numberValue, number.isFinite, number >= 0,
              number <= 9_007_199_254_740_991, number.rounded(.towardZero) == number else {
            throw invalidResponse
        }
        return Int64(number)
    }

    /// 시간대 변환 없이 그레고리력 날짜의 형식·실재 여부 검증
    private static func validDate(_ text: String) -> Bool {
        guard text.utf8.count == 10, text.utf8.enumerated().allSatisfy({ index, byte in
            [4, 7].contains(index) ? byte == 45 : (48...57).contains(byte)
        }) else { return false }
        let pieces = text.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3, pieces[0] > 0 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])) else { return false }
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        return check.year == pieces[0] && check.month == pieces[1] && check.day == pieces[2]
    }
}
