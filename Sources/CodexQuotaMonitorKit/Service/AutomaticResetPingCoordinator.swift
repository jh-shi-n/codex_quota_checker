// 목적: 실제 할당량 초기화 확인 후 계정별 최소 Ping 자동 전송
// 이용처: 정상 한도 상태 반영과 자동 전송 설정 변경
// 사용방법: reconcile에 최신 상태·사용 여부 전달, 종료 시 stop 호출
import Foundation

/// 초기화 감지·잔량 제한·계정 격리·순차 재시도의 단일 실행 경계
@MainActor
public final class AutomaticResetPingCoordinator {
    private typealias Window = EarlyQuotaReset.Window

    /// 동일 계정의 중복 실행과 취소 후 늦은 완료 처리 구분
    private struct Operation {
        let id: UUID
        let account: AccountState
        var windows: [Window]
        let task: Task<Void, Never>
    }

    private var accounts: [String: AccountState] = [:]
    private var baselines: [String: AccountState] = [:]
    private var operations: [String: Operation] = [:]
    private var enabled = false
    private let refresh: @MainActor (String) async -> AccountState?
    private let probe: @MainActor (AccountState) async -> UsageWindowProbePresentationResult
    private let notify: @MainActor (QuotaResetAlert) async -> Void
    private let now: @MainActor () -> Date
    private let sleep: @MainActor (TimeInterval) async throws -> Void

    /// 실제 네트워크·알림·시계·재시도 대기의 주입
    public init(
        refresh: @escaping @MainActor (String) async -> AccountState?,
        probe: @escaping @MainActor (AccountState) async -> UsageWindowProbePresentationResult,
        notify: @escaping @MainActor (QuotaResetAlert) async -> Void,
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.refresh = refresh
        self.probe = probe
        self.notify = notify
        self.now = now
        self.sleep = sleep
    }

    /// 최초 조회·기능 활성화는 기준 상태만 수집하고 이후 실제 초기화에만 반응
    public func reconcile(states: [AccountState], enabled: Bool) {
        let wasEnabled = self.enabled
        self.enabled = enabled
        accounts = Dictionary(states.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for (id, operation) in operations {
            if let current = accounts[id], current.resetChanges.contains(where: { change in
                change.kind == .reset && operation.windows.contains(change.window)
                    && (change.window == .primary
                        ? current.primaryResetSegmentID != operation.account.primaryResetSegmentID
                        : current.secondaryResetSegmentID != operation.account.secondaryResetSegmentID)
            }) {
                operation.task.cancel()
                operations[id] = nil
                continue
            }
            if let current = accounts[id], current.status == .normal, !Self.canSend(current) {
                record(.automaticResetPingSkipped, id: id, reason: "quota_unavailable_or_low")
                operation.task.cancel()
                operations[id] = nil
                continue
            }
            if !enabled || accounts[id].map({ !sameIdentity(operation.account, $0)
                || [.notConfigured, .loginRequired, .codexNotFound].contains($0.status) }) ?? true {
                operation.task.cancel()
                operations[id] = nil
            }
        }
        baselines = baselines.filter { accounts[$0.key] != nil }
        for current in states {
            guard current.status == .normal else {
                if [.notConfigured, .loginRequired, .codexNotFound].contains(current.status) {
                    baselines[current.id] = nil
                }
                continue
            }
            let previous = baselines[current.id]
            baselines[current.id] = current
            guard enabled, wasEnabled, let previous, sameIdentity(previous, current),
                  let updated = current.lastUpdated, abs(updated.timeIntervalSince(now())) <= 30,
                  previous.lastUpdated.map({ updated > $0 }) ?? false
            else { continue }
            let changes = current.primaryResetSegmentID != nil || current.secondaryResetSegmentID != nil
                ? current.resetChanges : QuotaResetChange.detect(previous: previous, current: current, now: now())
            let windows = changes.filter { $0.kind == .reset }.map(\.window)
            guard !windows.isEmpty else { continue }
            record(.automaticResetPingDetected, id: current.id, reason: "reset_confirmed")
            guard Self.canSend(current) else {
                record(.automaticResetPingSkipped, id: current.id, reason: "quota_unavailable_or_low")
                continue
            }
            if var operation = operations[current.id] {
                operation.windows += windows.filter { !operation.windows.contains($0) }
                operations[current.id] = operation
                continue
            }
            let operationID = UUID()
            let task = Task { [weak self] in
                guard let self else { return }
                await DiagnosticLogContext.$operationID.withValue(operationID) {
                    await self.run(account: current, operationID: operationID)
                }
            }
            operations[current.id] = Operation(id: operationID, account: current, windows: windows, task: task)
        }
    }

    /// 체크 해제·앱 종료 시 전송·대기 취소와 과거 이벤트 재사용 방지
    public func stop() {
        enabled = false
        for operation in operations.values { operation.task.cancel() }
        operations.removeAll()
        baselines.removeAll()
    }

    /// 현재 예약 작업의 완료 대기; 실제 지연 없는 회귀 검사 경계
    func waitForPendingOperations() async {
        for operation in Array(operations.values) { await operation.task.value }
    }

    /// 주간 10% 초과·5시간 잔량 존재·정상 조회만 자동 전송 허용
    static func canSend(_ state: AccountState) -> Bool {
        state.status == .normal && state.secondaryRemainingPercent.map { $0 > 10 } == true
            && state.primaryRemainingPercent.map { $0 > 0 } == true
    }

    /// 최초 전송 후 5·15·30초 간격 최대 3회 재시도; Ping 성공 후에는 조회만 재시도
    private func run(account: AccountState, operationID: UUID) async {
        defer {
            if operations[account.id]?.id == operationID { operations[account.id] = nil }
        }
        var didSend = false
        var failure = "quota_refresh_failed"
        for attempt in 0...3 {
            guard isCurrent(account, operationID: operationID) else { return }
            if attempt > 0 {
                do { try await sleep([5.0, 15.0, 30.0][attempt - 1]) }
                catch { return }
            }
            guard isCurrent(account, operationID: operationID) else { return }
            record(.automaticResetPingAttempt, id: account.id, reason: didSend ? "confirm_only" : "preflight", attempt: attempt + 1)
            let fresh = await refresh(account.id)
            guard isCurrent(account, operationID: operationID) else { return }
            guard let fresh, sameIdentity(account, fresh) else {
                if fresh != nil { return }
                failure = "quota_refresh_failed"
                continue
            }
            if [.notConfigured, .loginRequired, .codexNotFound].contains(fresh.status) {
                failure = fresh.status.rawValue
                break
            }
            guard fresh.status == .normal,
                  let updated = fresh.lastUpdated, abs(updated.timeIntervalSince(now())) <= 30 else {
                failure = "quota_refresh_failed"
                continue
            }
            guard Self.canSend(fresh) else {
                record(.automaticResetPingSkipped, id: account.id, reason: "quota_unavailable_or_low")
                return
            }
            let windows = operations[account.id]?.windows ?? []
            if didSend {
                if hasResetTimes(fresh, windows: windows) {
                    record(.automaticResetPingFinished, id: account.id, reason: "confirmed", attempt: attempt + 1)
                    return
                }
                failure = "reset_confirmation_failed"
                continue
            }
            if windows.allSatisfy({ window in
                (window == .primary ? fresh.primaryUsedPercent : fresh.secondaryUsedPercent).map { $0 > 0 } == true
            }) || hasResetTimes(fresh, windows: windows) {
                record(.automaticResetPingSkipped, id: account.id, reason: "already_in_use_or_stable")
                return
            }
            let presentation = await probe(fresh)
            guard isCurrent(account, operationID: operationID), presentation.isCurrentAccount else { return }
            if presentation.result.isCancelled { return }
            if presentation.result.isSuccess {
                didSend = true
                if let confirmation = presentation.resetConfirmation {
                    guard confirmation.isCurrentAccount else { return }
                    let targetWindows = operations[account.id]?.windows ?? windows
                    if confirmation.isStable(for: targetWindows) {
                        record(.automaticResetPingFinished, id: account.id, reason: "confirmed", attempt: attempt + 1)
                    } else {
                        record(.automaticResetPingFinished, id: account.id, reason: "confirmation_incomplete", attempt: attempt + 1)
                        await notify(QuotaResetAlert(accountID: account.id, title: "자동 Ping 시각 확인 미완료",
                            body: "Ping 전송 완료 · 5시간 \(confirmation.primary.text) · 주간 \(confirmation.secondary.text). 추가 Ping은 보내지 않습니다."))
                    }
                    return
                }
                if presentation.quotaRefreshSucceeded == true,
                   let after = presentation.refreshedAccount, sameIdentity(account, after),
                   hasResetTimes(after, windows: operations[account.id]?.windows ?? windows) {
                    record(.automaticResetPingFinished, id: account.id, reason: "confirmed", attempt: attempt + 1)
                    return
                }
                failure = "reset_confirmation_failed"
            } else {
                failure = presentation.result.failureCategory?.rawValue ?? "probe_failed"
                if presentation.result.failureCategory == .alreadyRunning {
                    record(.automaticResetPingSkipped, id: account.id, reason: "ping_already_running")
                    return
                }
                if let category = presentation.result.failureCategory,
                   [.notConfigured, .missingAuthentication, .executableUnavailable, .configurationFailure,
                    .unsupportedModel, .authenticationFailure].contains(category) { break }
            }
        }
        guard isCurrent(account, operationID: operationID) else { return }
        record(.automaticResetPingFinished, id: account.id, reason: failure)
        await notify(QuotaResetAlert(accountID: account.id, title: "할당량 자동 Ping 실패",
            body: "\(account.id): \(didSend ? "Ping은 전송했으나 초기화 시각을 확인하지 못했습니다." : "초기화 후 자동 Ping을 완료하지 못했습니다.") 설정과 계정 상태를 확인해 주세요."))
    }

    /// 현재 관측 구간의 미래 시각과 고정 관측을 함께 확인
    private func hasResetTimes(_ account: AccountState, windows: [Window]) -> Bool {
        account.status == .normal && windows.allSatisfy { window in
            let date = window == .primary ? account.primaryResetAt : account.secondaryResetAt
            let observation = window == .primary ? account.primaryResetObservation : account.secondaryResetObservation
            return observation == .stableObserved && date.map { $0.timeIntervalSince1970.isFinite && $0 > now() } == true
        }
    }

    /// 계정 교체·로그아웃·설정 해제·취소 이후 응답과 알림 제외
    private func isCurrent(_ account: AccountState, operationID: UUID) -> Bool {
        enabled && !Task.isCancelled && operations[account.id]?.id == operationID
            && accounts[account.id].map { sameIdentity(account, $0) } == true
    }

    /// 슬롯 세대·로그인 계정·구독 변경 시 이전 작업의 권한 분리
    private func sameIdentity(_ lhs: AccountState, _ rhs: AccountState) -> Bool {
        lhs.id == rhs.id && lhs.configurationGeneration == rhs.configurationGeneration
            && lhs.email == rhs.email && lhs.planType == rhs.planType
    }

    /// 원본 응답·이메일·경로 없이 단계·시도 횟수·실패 분류만 기록
    private func record(_ event: DiagnosticEvent, id: String, reason: String, attempt: Int? = nil) {
        var fields: [DiagnosticField: DiagnosticValue] = [.reason: .identifier(reason)]
        if let attempt { fields[.attempt] = .integer(attempt) }
        DiagnosticLogContext.record(event,
            level: event == .automaticResetPingFinished && !["confirmed", "confirmation_incomplete"].contains(reason) ? .error : .notice,
            accountID: id, fields: fields)
    }
}
