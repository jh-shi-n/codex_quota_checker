import Foundation

/// Immutable snapshot consumed by the UI for one account.
public struct AccountState: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var provider: AccountProvider = .codex
    /// 경로 변경 시 상세 화면 상태를 분리하는 비영속 슬롯 세대
    public var configurationGeneration = 0
    /// 서버의 통합 리셋권 잔여 개수와 선택적 소멸일 목록
    public var resetCredits: RateLimitResetCredits?
    public var email: String?
    public var planType: String?
    public var primaryResetAt: Date?
    public var secondaryResetAt: Date?
    /// 영속 스냅샷과 분리한 현재 실행의 초기화 시각 관측
    public var primaryResetObservation: ResetTimeObservation = .checking
    public var secondaryResetObservation: ResetTimeObservation = .checking
    public var lastUpdated: Date?
    public var status: AccountStatus
    public var errorMessage: String?
    private var normalizedPrimaryUsedPercent: Double?
    private var normalizedSecondaryUsedPercent: Double?

    /// The rolling five-hour quota reported as `rateLimits.primary`.
    public var primaryUsedPercent: Double? {
        get { normalizedPrimaryUsedPercent }
        set { normalizedPrimaryUsedPercent = newValue.map(Self.clampPercent) }
    }

    public var primaryRemainingPercent: Double? {
        get { normalizedPrimaryUsedPercent.map { Self.clampPercent(100 - $0) } }
        set { normalizedPrimaryUsedPercent = Self.usedPercent(fromRemaining: newValue) }
    }

    /// The overall quota reported as `rateLimits.secondary`.
    public var secondaryUsedPercent: Double? {
        get { normalizedSecondaryUsedPercent }
        set { normalizedSecondaryUsedPercent = newValue.map(Self.clampPercent) }
    }

    public var secondaryRemainingPercent: Double? {
        get { normalizedSecondaryUsedPercent.map { Self.clampPercent(100 - $0) } }
        set { normalizedSecondaryUsedPercent = Self.usedPercent(fromRemaining: newValue) }
    }

    public var fiveHourRemainingPercent: Double? { primaryRemainingPercent }
    public var overallRemainingPercent: Double? { secondaryRemainingPercent }

    /// Compatibility aliases for callers and persisted payloads created before
    /// primary/secondary quotas were modeled separately.
    public var usedPercent: Double? {
        get { primaryUsedPercent }
        set {
            primaryUsedPercent = newValue
            secondaryUsedPercent = newValue
        }
    }

    public var remainingPercent: Double? {
        get { primaryRemainingPercent }
        set {
            primaryRemainingPercent = newValue
            secondaryRemainingPercent = newValue
        }
    }

    public var resetAt: Date? {
        get { primaryResetAt }
        set { primaryResetAt = newValue }
    }

    public init(
        id: String,
        email: String? = nil,
        planType: String? = nil,
        primaryUsedPercent: Double? = nil,
        secondaryUsedPercent: Double? = nil,
        primaryRemainingPercent: Double? = nil,
        secondaryRemainingPercent: Double? = nil,
        primaryResetAt: Date? = nil,
        secondaryResetAt: Date? = nil,
        usedPercent: Double? = nil,
        remainingPercent: Double? = nil,
        resetAt: Date? = nil,
        resetCredits: RateLimitResetCredits? = nil,
        lastUpdated: Date? = nil,
        status: AccountStatus,
        errorMessage: String? = nil,
        provider: AccountProvider = .codex
    ) {
        self.resetCredits = resetCredits
        self.provider = provider
        self.id = id
        self.email = email
        self.planType = planType
        self.primaryResetAt = primaryResetAt ?? resetAt
        self.secondaryResetAt = secondaryResetAt
        self.lastUpdated = lastUpdated
        self.status = status
        self.errorMessage = errorMessage

        let legacyUsed = usedPercent ?? Self.usedPercent(fromRemaining: remainingPercent)
        self.normalizedPrimaryUsedPercent = primaryUsedPercent.map(Self.clampPercent)
            ?? Self.usedPercent(fromRemaining: primaryRemainingPercent)
            ?? legacyUsed.map(Self.clampPercent)
        self.normalizedSecondaryUsedPercent = secondaryUsedPercent.map(Self.clampPercent)
            ?? Self.usedPercent(fromRemaining: secondaryRemainingPercent)

        // Legacy in-memory callers supplied one quota that powered both the
        // number and ring. Preserve that visual behavior until refresh.
        if primaryUsedPercent == nil,
           primaryRemainingPercent == nil,
           secondaryUsedPercent == nil,
           secondaryRemainingPercent == nil,
           let legacyUsed {
            self.normalizedSecondaryUsedPercent = Self.clampPercent(legacyUsed)
            self.secondaryResetAt = resetAt
        }
    }

    public static func loading(id: String) -> AccountState {
        AccountState(id: id, status: .loading)
    }

    public static func notConfigured(id: String) -> AccountState {
        AccountState(id: id, status: .notConfigured)
    }

    public static func clampPercent(_ value: Double) -> Double {
        if value.isNaN || value == -.infinity { return 0 }
        if value == .infinity { return 100 }
        return min(100, max(0, value))
    }

    private static func usedPercent(fromRemaining value: Double?) -> Double? {
        value.map { clampPercent(100 - clampPercent($0)) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, email, planType, resetCredits
        case primaryUsedPercent, secondaryUsedPercent
        case primaryRemainingPercent, secondaryRemainingPercent
        case primaryResetAt, secondaryResetAt
        case usedPercent, remainingPercent, resetAt
        case lastUpdated, status, errorMessage
        case provider
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            email: try container.decodeIfPresent(String.self, forKey: .email),
            planType: try container.decodeIfPresent(String.self, forKey: .planType),
            primaryUsedPercent: try container.decodeIfPresent(Double.self, forKey: .primaryUsedPercent),
            secondaryUsedPercent: try container.decodeIfPresent(Double.self, forKey: .secondaryUsedPercent),
            primaryRemainingPercent: try container.decodeIfPresent(Double.self, forKey: .primaryRemainingPercent),
            secondaryRemainingPercent: try container.decodeIfPresent(Double.self, forKey: .secondaryRemainingPercent),
            primaryResetAt: try container.decodeIfPresent(Date.self, forKey: .primaryResetAt),
            secondaryResetAt: try container.decodeIfPresent(Date.self, forKey: .secondaryResetAt),
            usedPercent: try container.decodeIfPresent(Double.self, forKey: .usedPercent),
            remainingPercent: try container.decodeIfPresent(Double.self, forKey: .remainingPercent),
            resetAt: try container.decodeIfPresent(Date.self, forKey: .resetAt),
            resetCredits: try container.decodeIfPresent(RateLimitResetCredits.self, forKey: .resetCredits),
            lastUpdated: try container.decodeIfPresent(Date.self, forKey: .lastUpdated),
            status: try container.decode(AccountStatus.self, forKey: .status),
            errorMessage: try container.decodeIfPresent(String.self, forKey: .errorMessage),
            provider: try container.decodeIfPresent(AccountProvider.self, forKey: .provider) ?? .codex
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(resetCredits, forKey: .resetCredits)
        try container.encode(id, forKey: .id)
        try container.encode(provider, forKey: .provider)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(planType, forKey: .planType)
        try container.encodeIfPresent(primaryUsedPercent, forKey: .primaryUsedPercent)
        try container.encodeIfPresent(secondaryUsedPercent, forKey: .secondaryUsedPercent)
        try container.encodeIfPresent(primaryRemainingPercent, forKey: .primaryRemainingPercent)
        try container.encodeIfPresent(secondaryRemainingPercent, forKey: .secondaryRemainingPercent)
        try container.encodeIfPresent(primaryResetAt, forKey: .primaryResetAt)
        try container.encodeIfPresent(secondaryResetAt, forKey: .secondaryResetAt)
        try container.encodeIfPresent(usedPercent, forKey: .usedPercent)
        try container.encodeIfPresent(remainingPercent, forKey: .remainingPercent)
        try container.encodeIfPresent(resetAt, forKey: .resetAt)
        try container.encodeIfPresent(lastUpdated, forKey: .lastUpdated)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
    }
}
