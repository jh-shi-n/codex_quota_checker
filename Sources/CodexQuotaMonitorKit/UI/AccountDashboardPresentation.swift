import Foundation

/// The callback contracts used by the account dashboard.  The closures are
/// deliberately account-state based so a panel can never accidentally read a
/// sibling account's home or usage data.
public typealias UsageWindowProbeRunner = @MainActor @Sendable (AccountState) async -> UsageWindowProbePresentationResult
public typealias TokenUsageSnapshotLookup = @MainActor @Sendable (String) async -> TokenUsageSnapshot?
public typealias TokenUsageSnapshotRefresh = @MainActor @Sendable (AccountState) async -> TokenUsageSnapshot
public typealias TokenUsageCacheLookup = TokenUsageSnapshotLookup
public typealias TokenUsageRefreshHandler = TokenUsageSnapshotRefresh

/// - 목적: Ping 결과와 최신 한도 갱신 관찰값의 UI 전달
/// - 보관 정보: 제한된 결과, 두 Reset 구간, 성공한 갱신 계정 스냅샷
/// - 제외 정보: 프로세스 출력, 계정 경로
public struct UsageWindowProbePresentationResult: Equatable, Sendable {
    public let result: UsageWindowProbeResult
    public let primaryResetBefore: Date?
    public let primaryResetAfter: Date?
    public let secondaryResetBefore: Date?
    public let secondaryResetAfter: Date?
    public let quotaRefreshSucceeded: Bool?
    public let refreshedAccount: AccountState?
    /// 계정 경로와 세대가 현재 상세와 일치하는지 여부
    public let isCurrentAccount: Bool
    public let resetConfirmation: ResetTimeConfirmationResult?

    /// 하위 호환 가능한 Ping 및 한도 갱신 결과 생성
    public init(
        result: UsageWindowProbeResult,
        primaryResetBefore: Date? = nil,
        primaryResetAfter: Date? = nil,
        secondaryResetBefore: Date? = nil,
        secondaryResetAfter: Date? = nil,
        quotaRefreshSucceeded: Bool? = nil,
        refreshedAccount: AccountState? = nil,
        isCurrentAccount: Bool = true,
        resetConfirmation: ResetTimeConfirmationResult? = nil
    ) {
        self.result = result
        self.primaryResetBefore = primaryResetBefore
        self.primaryResetAfter = primaryResetAfter
        self.secondaryResetBefore = secondaryResetBefore
        self.secondaryResetAfter = secondaryResetAfter
        self.quotaRefreshSucceeded = quotaRefreshSucceeded
        self.refreshedAccount = refreshedAccount
        self.isCurrentAccount = isCurrentAccount
        self.resetConfirmation = resetConfirmation
    }

    public var isSuccess: Bool { result.isSuccess }
    public var usage: UsageWindowProbeTokenUsage? { result.usage }
    public var failureCategory: UsageWindowProbeFailureCategory? { result.failureCategory }
}

public typealias UsageWindowProbeCompositeResult = UsageWindowProbePresentationResult
public typealias UsageWindowProbeOutcome = UsageWindowProbePresentationResult

/// 계정 대시보드의 스냅샷 선택 정책
enum AccountDashboardPresentation {
    /// - 목적: 계정 상세에 표시할 최신 한도 스냅샷 선택
    /// - 우선순위: 동일 계정의 성공한 Ping 갱신 결과 중 더 최신 `lastUpdated`
    /// - 동률·시각 누락: 현재 전달된 계정 스냅샷 유지
    static func accountForDisplay(
        current: AccountState,
        probe: UsageWindowProbePresentationResult?
    ) -> AccountState {
        guard let probe,
              probe.isCurrentAccount,
              probe.result.accountID == current.id,
              probe.result.isSuccess,
              probe.quotaRefreshSucceeded == true,
              let refreshedAccount = probe.refreshedAccount,
              refreshedAccount.id == current.id,
              refreshedAccount.configurationGeneration == current.configurationGeneration,
              refreshedAccount.email == current.email,
              refreshedAccount.planType == current.planType,
              current.primaryResetSegmentID.map({ $0 == refreshedAccount.primaryResetSegmentID }) ?? true,
              current.secondaryResetSegmentID.map({ $0 == refreshedAccount.secondaryResetSegmentID }) ?? true,
              let currentUpdatedAt = current.lastUpdated,
              let refreshedUpdatedAt = refreshedAccount.lastUpdated,
              refreshedUpdatedAt > currentUpdatedAt
        else { return current }

        return refreshedAccount
    }
}

/// Pure formatting and semantic helpers shared by the dashboard and focused
/// presentation tests.  They never access account files or invoke a service.
public enum AccountDashboardFormatting {
    /// 정상·로딩 상태의 유효한 고정 관측만 초기화 일정으로 표시
    public static func observedResetDate(
        _ resetAt: Date?, observation: ResetTimeObservation,
        status: AccountStatus, now: Date = Date()
    ) -> Date? {
        guard [.normal, .loading].contains(status), observation == .stableObserved,
              let resetAt, resetAt.timeIntervalSince1970.isFinite, resetAt > now else { return nil }
        return resetAt
    }

    /// 미확인·변동·만료·실패 상태의 일정 확정 오인 방지 문구
    public static func resetScheduleStatusText(
        _ resetAt: Date?, observation: ResetTimeObservation,
        status: AccountStatus, now: Date = Date()
    ) -> String {
        guard [.normal, .loading].contains(status) else { return "초기화 시각 조회 미확인" }
        guard let resetAt, resetAt.timeIntervalSince1970.isFinite else { return "초기화 시각 미확인" }
        guard resetAt > now else { return "초기화 시각 재확인 필요" }
        switch observation {
        case .stableObserved: return "할당량 시간 고정"
        case .movingObserved: return "초기화 시각 변동 중"
        case .checking: return "초기화 시각 확인 중"
        }
    }

    /// 평균의 반올림과 Int64 상한 적용; 비정상·음수 입력은 0으로 정규화
    static func roundedTokenAverage(_ average: Double) -> Int64 {
        guard average.isFinite, average > 0 else { return 0 }
        let rounded = average.rounded()
        return rounded >= Double(Int64.max) ? Int64.max : Int64(rounded)
    }

    /// 현재 할당량 제목 옆의 5시간 한도 안내; 이동·실패·만료·7일 한도 제외
    public static func fiveHourResetNotice(for account: AccountState, now: Date = Date()) -> String? {
        guard let reset = observedResetDate(account.primaryResetAt,
            observation: account.primaryResetObservation, status: account.status, now: now) else { return nil }
        let remaining = remainingTimeText(until: reset, now: now)
        return "\(remaining) 뒤 5시간 할당량이 초기화될 예정입니다."
    }

    /// 서버 구독 코드의 한글 뱃지 표시명 변환 및 미확인 값 처리
    public static func subscriptionBadgeText(_ planType: String?) -> String {
        guard let planType else { return "—" }
        switch planType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "": return "—"
        case "free": return "무료"
        case "go": return "Go"
        case "plus": return "플러스"
        case "pro": return "프로"
        case "prolite": return "프로 라이트"
        case "promax": return "프로 맥스"
        case "team": return "팀"
        case "business": return "비즈니스"
        case "self_serve_business_prolite": return "비즈니스 프로 라이트"
        case "self_serve_business_usage_based": return "비즈니스 사용량 기반"
        case "enterprise", "ent26": return "엔터프라이즈"
        case "enterprise_cbp_automation": return "엔터프라이즈 자동화"
        case "enterprise_cbp_usage_based": return "엔터프라이즈 사용량 기반"
        case "edu": return "교육"
        case "edu_plus": return "교육 플러스"
        case "edu_pro": return "교육 프로"
        default: return "구독 확인 필요"
        }
    }

    public static func numberText(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// 백만 미만의 원래 숫자와 백만 이상 소수 첫째 자리 축약 표시
    public static func tokenCountText(_ value: Int64) -> String {
        guard value.magnitude >= 1_000_000 else { return numberText(value) }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return (formatter.string(from: NSDecimalNumber(decimal: Decimal(value) / 1_000_000)) ?? String(value)) + "백만"
    }

    public static func abbreviatedNumber(_ value: Int64) -> String {
        let sign = value < 0 ? "-" : ""
        let magnitude = Double(value.magnitude)
        let (scaled, suffix): (Double, String) = {
            switch magnitude {
            case 1_000_000_000...:
                return (magnitude / 1_000_000_000, "B")
            case 1_000_000...:
                return (magnitude / 1_000_000, "M")
            case 1_000...:
                return (magnitude / 1_000, "K")
            default:
                return (magnitude, "")
            }
        }()

        guard !suffix.isEmpty else { return "\(sign)\(numberText(value))" }
        let rounded: String
        if scaled >= 100 || scaled.rounded() == scaled {
            rounded = String(format: "%.0f", scaled)
        } else {
            var trimmed = String(format: "%.1f", scaled)
            while trimmed.last == "0" { trimmed.removeLast() }
            if trimmed.last == "." { trimmed.removeLast() }
            rounded = trimmed
        }
        return "\(sign)\(rounded)\(suffix)"
    }

    public static func dateText(
        _ date: Date?,
        dateStyle: DateFormatter.Style = .medium,
        timeStyle: DateFormatter.Style = .short
    ) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter.string(from: date)
    }

    public static func remainingTimeText(
        until date: Date?,
        now: Date = Date()
    ) -> String {
        guard let date else { return "—" }
        let seconds = Int((date.timeIntervalSince(now)).rounded())
        guard seconds > 0 else { return "곧 초기화" }
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)시간 \(minutes)분" : "\(hours)시간"
        }
        return "\(max(1, minutes))분"
    }

    /// Presents reset observation as `before → after (▼N분)` or
    /// `before → after (▲N분)`.  A missing side is kept explicit rather than
    /// implying that the probe changed the reset schedule.
    public static func resetDeltaText(
        before: Date?,
        after: Date?,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        guard let before, let after else {
            if let after { return dateText(after, dateStyle: .none, timeStyle: .short) }
            if let before { return dateText(before, dateStyle: .none, timeStyle: .short) }
            return "—"
        }

        let beforeText = dateText(before, dateStyle: .none, timeStyle: .short)
        let afterText = dateText(after, dateStyle: .none, timeStyle: .short)
        let minutes = Int((after.timeIntervalSince(before) / 60).rounded())
        guard minutes != 0 else { return "\(beforeText) → \(afterText)" }
        let arrow = minutes < 0 ? "▼" : "▲"
        let unit = "분"
        _ = calendar
        return "\(beforeText) → \(afterText) (\(arrow)\(abs(minutes))\(unit))"
    }

    /// 한도 조회 실패와 Reset 관찰값을 구분하는 날짜 표시
    public static func resetObservationText(
        before: Date?,
        after: Date?,
        quotaRefreshSucceeded: Bool?
    ) -> String {
        if quotaRefreshSucceeded == false {
            guard let before else { return "한도 조회 실패" }
            let priorDate = dateText(before, dateStyle: .medium, timeStyle: .short)
            return "기존 \(priorDate) · 한도 조회 실패"
        }

        guard let after else {
            guard let before else { return "—" }
            let priorDate = dateText(before, dateStyle: .medium, timeStyle: .short)
            return quotaRefreshSucceeded == true
                ? "조회 후 Reset 없음 · 이전 \(priorDate)"
                : "이전 \(priorDate)"
        }

        let afterText = dateText(after, dateStyle: .medium, timeStyle: .short)
        guard let before else { return afterText }
        let beforeText = dateText(before, dateStyle: .medium, timeStyle: .short)
        let minutes = Int((after.timeIntervalSince(before) / 60).rounded())
        guard minutes != 0 else { return "\(beforeText) → \(afterText)" }
        let arrow = minutes < 0 ? "▼" : "▲"
        return "\(beforeText) → \(afterText) (\(arrow)\(abs(minutes))분)"
    }
}

public enum AccountDashboardDefaults {
    /// 계정 파일 접근 없이 로컬 집계와 동일한 168일 기본 스냅샷 제공
    public static func unavailableTokenUsageSnapshot(
        generatedAt: Date = Date()
    ) -> TokenUsageSnapshot {
        TokenUsageAggregator().emptySnapshot(
            generatedAt: generatedAt,
            availability: .unavailable,
            error: .invalidHome
        )
    }

    /// A cache miss is intentionally distinct from an unavailable scan. It
    /// lets the dashboard render its empty state until Update is requested.
    public static let emptyTokenUsageLookup: TokenUsageSnapshotLookup = { _ in nil }

    /// Safe fallback for hosts that do not install the app's explicit update
    /// closure. It never scans a home or claims that usage was read.
    public static let unavailableTokenUsageRefresh: TokenUsageSnapshotRefresh = { _ in
        unavailableTokenUsageSnapshot()
    }

    public static func unavailableProbe(
        accountID: String,
        category: UsageWindowProbeFailureCategory = .notConfigured,
        now: Date = Date()
    ) -> UsageWindowProbePresentationResult {
        UsageWindowProbePresentationResult(
            result: UsageWindowProbeResult(
                accountID: accountID,
                status: .failure,
                startedAt: now,
                completedAt: now,
                failureCategory: category
            )
        )
    }
}

/// Relative levels used by the 12×7 contribution grid.  `.none` is also the
/// explicit no-data state; positive values map to the four visible intensity
/// levels in the reference design.
public enum TokenContributionIntensity: Int, CaseIterable, Equatable, Sendable {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3
    case veryHigh = 4

    public static var noData: Self { .none }
    public static var normal: Self { .medium }
    public static var veryLow: Self { .low }

    /// 분포 정렬 한 번으로 중복 값의 마지막 순위를 유지한 강도표 구성
    public static func levels(for distribution: [Int64]) -> [Int64: Self] {
        let positive = distribution.filter { $0 > 0 }.sorted()
        var levels: [Int64: Self] = [:]
        for (rank, value) in positive.enumerated() {
            levels[value] = intensity(rank: rank, count: positive.count)
        }
        return levels
    }

    /// 양수 분포 순위의 사분위 강도 변환
    private static func intensity(rank: Int, count: Int) -> Self {
        let bucket = min(3, (rank * 4) / max(1, count))
        return [.low, .medium, .high, .veryHigh][bucket]
    }

    public static func level(
        for value: Int64,
        distribution: [Int64]
    ) -> Self {
        guard value > 0 else { return .none }
        let positive = distribution.filter { $0 > 0 }.sorted()
        guard !positive.isEmpty else { return .none }
        let rank = positive.lastIndex(of: value) ?? {
            // A value not present in the supplied distribution is placed just
            // below the next observed value, preserving relative ordering.
            var insertion = 0
            while insertion < positive.count, positive[insertion] < value {
                insertion += 1
            }
            return insertion
        }()
        return intensity(rank: rank, count: positive.count)
    }

    public static func level(for value: Int64, in distribution: [Int64]) -> Self {
        level(for: value, distribution: distribution)
    }
}

/// Non-UI action guards make it easy to test callback state without creating a
/// SwiftUI view or launching an AppKit process.
public enum AccountDashboardActionState {
    public static func canRunProbe(
        account: AccountState,
        isRunning: Bool
    ) -> Bool {
        account.status != .notConfigured && !isRunning
    }
}
