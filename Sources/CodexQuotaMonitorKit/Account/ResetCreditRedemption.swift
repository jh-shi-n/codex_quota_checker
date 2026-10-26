// 목적: 확인된 리셋권 사용과 중복 요청 방지
// 이용처: 계정 상세 리셋권 목록과 앱 사용 요청
// 사용방법: 확인 창 승인 후 store.start 호출
// 실행 예시: swift test --filter ResetCredit
import Combine
import Foundation

/// 서버의 리셋권 사용 결과 구분
public enum ResetCreditOutcome: String, Equatable, Sendable {
    case reset, nothingToReset, noCredit, alreadyRedeemed

    public var message: String {
        switch self {
        case .reset: return "리셋권을 사용했습니다."
        case .alreadyRedeemed: return "이미 처리된 사용 요청입니다."
        case .nothingToReset: return "현재 초기화할 수 있는 한도가 없습니다."
        case .noCredit: return "사용 가능한 리셋권이 없습니다."
        }
    }
}

/// 계정·리셋권·재시도 키를 유지하는 사용 요청 경계
public typealias ResetCreditRunner = @MainActor @Sendable (
    AccountState, String, String
) async -> Result<ResetCreditOutcome, CodexQuotaServiceError>

/// 호스트 미연결 시 사용 요청 차단
public enum ResetCreditDefaults {
    public static let unavailable: ResetCreditRunner = { _, _, _ in
        .failure(.protocolError("리셋권 사용 기능을 연결할 수 없습니다."))
    }
}

/// 화면 재진입과 양쪽 패널 사이의 중복 사용 방지
@MainActor
final class ResetCreditRedemptionStore: ObservableObject {
    static let shared = ResetCreditRedemptionStore()

    /// 계정 경로 변경 전후의 요청 격리
    private struct Key: Hashable {
        let accountID: String
        let generation: Int
    }

    @Published private var running: Set<Key> = []
    @Published private var messages: [Key: String] = [:]
    private var attempts: [Key: [String: String]] = [:]
    private var redeemed: [Key: Set<String>] = [:]

    /// 현재 계정 설정에 해당하는 작업 키 구성
    private func key(_ account: AccountState) -> Key {
        Key(accountID: account.id, generation: account.configurationGeneration)
    }

    /// 계정 내 사용 처리 중 여부 반환
    func isRunning(for account: AccountState) -> Bool { running.contains(key(account)) }

    /// 마지막 사용 결과 또는 오류 안내 반환
    func message(for account: AccountState) -> String? { messages[key(account)] }

    /// 서버 가용 상태·소멸일·완료 기록에 따른 사용 가능 여부 판정
    func canUse(_ credit: RateLimitResetCredits.Credit, for account: AccountState, now: Date = Date()) -> Bool {
        !isRunning(for: account) && credit.status == "available" && !credit.id.isEmpty
            && (credit.expiresAt.map { $0 > now } ?? true)
            && !(redeemed[key(account)]?.contains(credit.id) ?? false)
            && (account.resetCredits?.availableCount ?? 0) > 0
            && (account.resetCredits?.availableCredits?.contains(where: { $0.id == credit.id }) ?? false)
    }

    /// 승인 이후 단일 요청 실행; 응답 유실 재시도에는 기존 키 재사용
    @discardableResult
    func start(
        credit: RateLimitResetCredits.Credit, account: AccountState, runner: @escaping ResetCreditRunner
    ) -> Task<Void, Never>? {
        let operationID = UUID()
        let logger = DiagnosticLogContext.logger ?? .shared
        guard canUse(credit, for: account) else {
            logger.record(.resetCreditRejected, operationID: operationID, accountID: account.id,
                          fields: [.reason: .identifier(isRunning(for: account) ? "already_running" : "unavailable")])
            return nil
        }
        let key = key(account)
        let isRetry = attempts[key]?[credit.id] != nil
        let attempt = attempts[key]?[credit.id] ?? UUID().uuidString
        attempts[key, default: [:]][credit.id] = attempt
        running.insert(key)
        messages[key] = nil
        logger.record(.resetCreditRequested, operationID: operationID, accountID: account.id,
                      fields: [.generation: .integer(account.configurationGeneration),
                               .reason: .identifier(isRetry ? "retry" : "new_request")])
        return Task { @MainActor in
            defer { running.remove(key) }
            let started = ProcessInfo.processInfo.systemUptime
            let result = await DiagnosticLogContext.$operationID.withValue(operationID) {
                await runner(account, credit.id, attempt)
            }
            var fields: [DiagnosticField: DiagnosticValue] = [
                .durationMS: DiagnosticLogContext.elapsedMS(since: started),
                .generation: .integer(account.configurationGeneration),
            ]
            switch result {
            case let .success(outcome):
                fields[.status] = .identifier(outcome.rawValue)
                logger.record(.resetCreditFinished, operationID: operationID, accountID: account.id, fields: fields)
                messages[key] = outcome.message
                if outcome == .reset || outcome == .alreadyRedeemed {
                    redeemed[key, default: []].insert(credit.id)
                } else {
                    attempts[key]?[credit.id] = nil
                }
            case let .failure(error):
                fields[.status] = .identifier("failed")
                fields[.failure] = .identifier(Self.failureCode(error))
                fields[.appErrorCode] = .identifier(error.appErrorCode.rawValue)
                logger.record(.resetCreditFinished, level: error == .cancelled ? .notice : .error,
                              operationID: operationID, accountID: account.id, fields: fields)
                messages[key] = error.appErrorCode.message("사용 결과를 확인하지 못했습니다. 한도를 새로고침해 주세요. 다시 사용하면 같은 요청으로 확인합니다.")
            }
        }
    }

    /// 원문 메시지·경로를 제외한 리셋권 요청 오류 분류
    private static func failureCode(_ error: CodexQuotaServiceError) -> String {
        switch error {
        case .notConfigured: "not_configured"
        case .loginRequired: "login_required"
        case .codexNotFound: "codex_not_found"
        case .timeout: "timeout"
        case .cancelled: "cancelled"
        case .processCrashed: "process_crashed"
        case .malformedResponse: "malformed_response"
        case .protocolError: "protocol_error"
        case .transport: "transport"
        }
    }
}
