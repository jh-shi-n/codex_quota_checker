// 목적: 상세 화면 수명과 독립적인 계정별 초기화 갱신 관리
// 이용처: 계정 상세의 실행 상태와 결과 복원
// 사용방법: start 호출 후 isRunning·presentation 조회
import Combine
import Foundation

/// 계정 전환과 팝오버 닫기 이후에도 갱신 작업과 결과 유지
@MainActor
public final class UsageWindowProbeStore: ObservableObject {
    public static let shared = UsageWindowProbeStore()

    /// 경로 변경 전후의 동일 슬롯 작업과 결과 분리
    private struct Key: Hashable {
        let id: String
        let generation: Int

        /// 계정 슬롯과 설정 세대로 식별자 생성
        init(_ account: AccountState) {
            id = account.id
            generation = account.configurationGeneration
        }
    }

    @Published private var results: [Key: UsageWindowProbePresentationResult] = [:]
    @Published private var lastStartedAtByAccount: [Key: Date] = [:]
    @Published private var tasks: [Key: Operation] = [:]
    @Published private var confirming: Set<Key> = []

    /// 취소 후 재시작된 동일 계정 작업의 완료 처리 격리
    private struct Operation {
        let id: UUID
        let task: Task<Void, Never>
        let startedAt: Date
        let logger: DiagnosticLogger
    }

    /// 현재 계정 설정에 속한 실행 상태 반환
    func isRunning(for account: AccountState) -> Bool {
        tasks[Key(account)] != nil
    }

    /// 전송 완료 이후 추가 한도 조회 중인 계정 상태 반환
    func isConfirming(for account: AccountState) -> Bool { confirming.contains(Key(account)) }

    /// 현재 수동 실행의 전송 완료·시각 확인 단계 반영
    public func markConfirming(for account: AccountState) {
        let key = Key(account)
        if tasks[key] != nil { confirming.insert(key) }
    }

    /// 팝오버 재진입에도 유지되는 현재 요청의 시작 시각 조회
    func startedAt(for account: AccountState) -> Date? {
        tasks[Key(account)]?.startedAt
    }

    /// 버튼 실행 시각의 메모리 조회; 완료·팝오버 닫기 이후에도 유지
    func lastStartedAt(for account: AccountState) -> Date? {
        lastStartedAtByAccount[Key(account)]
    }

    /// 현재 계정 설정에 속한 마지막 실행 결과 반환
    func presentation(for account: AccountState) -> UsageWindowProbePresentationResult? {
        results[Key(account)]
    }

    /// 중복 실행 방지 및 화면 취소와 독립적인 Ping·한도 재조회 실행
    @discardableResult
    func start(for account: AccountState, runner: @escaping UsageWindowProbeRunner) -> Task<Void, Never>? {
        let key = Key(account)
        let operationID = UUID()
        let logger = DiagnosticLogContext.logger ?? .shared
        var initialFields = DiagnosticLogContext.resetFields(before: account)
        initialFields[.generation] = .integer(key.generation)
        logger.record(.probeRequested, operationID: operationID, accountID: account.id, fields: initialFields)
        guard AccountDashboardActionState.canRunProbe(account: account, isRunning: tasks[key] != nil) else {
            logger.record(.probeRejected, operationID: operationID, accountID: account.id,
                          fields: [.reason: .identifier(tasks[key] != nil ? "already_running" : "not_configured")])
            return nil
        }
        let startedAt = Date()
        lastStartedAtByAccount = lastStartedAtByAccount.filter { $0.key.id != key.id || $0.key == key }
        lastStartedAtByAccount[key] = startedAt
        let task = Task { @MainActor in
            defer {
                if tasks[key]?.id == operationID {
                    confirming.remove(key)
                    tasks[key] = nil
                }
            }
            let presentation = await DiagnosticLogContext.$operationID.withValue(operationID) {
                await runner(account)
            }
            guard !Task.isCancelled else {
                logger.record(.probeResultDiscarded, operationID: operationID, accountID: account.id,
                              fields: [.reason: .identifier("cancelled")])
                return
            }
            if presentation.result.accountID == account.id, presentation.isCurrentAccount {
                results[key] = presentation
                var fields: [DiagnosticField: DiagnosticValue] = [
                    .generation: .integer(key.generation),
                    .status: .identifier(presentation.result.status.rawValue),
                ]
                if let date = presentation.primaryResetBefore { fields[.primaryResetBefore] = .timestamp(date) }
                if let date = presentation.primaryResetAfter { fields[.primaryResetAfter] = .timestamp(date) }
                if let date = presentation.secondaryResetBefore { fields[.secondaryResetBefore] = .timestamp(date) }
                if let date = presentation.secondaryResetAfter { fields[.secondaryResetAfter] = .timestamp(date) }
                if let succeeded = presentation.quotaRefreshSucceeded { fields[.applied] = .boolean(succeeded) }
                let reason: String
                if presentation.result.isCancelled { reason = "cancelled" }
                else if !presentation.result.isSuccess { reason = "probe_failed" }
                else if presentation.quotaRefreshSucceeded != true { reason = "quota_refresh_failed" }
                else if presentation.primaryResetAfter == nil { reason = "primary_reset_missing" }
                else if presentation.primaryResetBefore == presentation.primaryResetAfter,
                        presentation.secondaryResetBefore == presentation.secondaryResetAfter {
                    reason = "reset_times_unchanged"
                } else { reason = "reset_times_changed" }
                fields[.reason] = .identifier(reason)
                logger.record(.probeResultApplied, operationID: operationID, accountID: account.id,
                              fields: fields)
            } else {
                logger.record(.probeResultDiscarded, operationID: operationID, accountID: account.id,
                              fields: [.reason: .identifier("account_changed")])
            }
        }
        tasks[key] = Operation(id: operationID, task: task, startedAt: startedAt, logger: logger)
        return task
    }

    /// 앱 종료 시 진행 중 Ping·한도 조회 취소 및 늦은 응답 반영 방지
    public func cancelAll() {
        for (key, operation) in tasks {
            operation.logger.record(
                .probeCancelled, operationID: operation.id, accountID: key.id,
                fields: [.generation: .integer(key.generation)]
            )
            operation.task.cancel()
        }
        tasks.removeAll()
        confirming.removeAll()
    }
}
