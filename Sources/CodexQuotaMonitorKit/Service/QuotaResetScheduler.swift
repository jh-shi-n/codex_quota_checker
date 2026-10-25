// 목적: 안정 관측된 초기화 시각의 사전 알림 및 도달 시 재조회
// 이용처: 앱 수명주기와 계정 상태 변경 처리
// 사용방법: reconcile로 상태 반영, start·stop으로 로컬 타이머 관리
import Foundation

/// 초기화 시각 도달과 실제 초기화 확인을 구분하는 시스템 알림
public struct QuotaResetAlert: Equatable, Sendable {
    public let accountID: String
    public let title: String
    public let body: String
}

/// 일반 조회 타이머와 독립적인 계정별 초기화 예약 관리
@MainActor
public final class QuotaResetScheduler {
    /// 서로 독립적으로 예약하는 5시간·7일 한도
    private enum Window: String, CaseIterable {
        case primary, secondary
        var title: String { self == .primary ? "5시간 할당량" : "7일 할당량" }
    }

    /// 초기화 시각과 계정 세대에 귀속되는 1회 처리 상태
    private struct Entry {
        let account: AccountState
        let window: Window
        let resetAt: Date
        let segmentID: UUID?
        var reminderHandled: Bool
        var boundaryHandled = false
    }

    private var entries: [String: Entry] = [:]
    private var accounts: [String: AccountState] = [:]
    private var reminderMinutes = 5
    private var loop: Task<Void, Never>?
    private var isTicking = false
    private let refresh: @MainActor (String) async -> AccountState?
    private let notify: @MainActor (QuotaResetAlert) async -> Void

    /// 해당 계정의 실제 재조회 및 macOS 알림 전달 동작 주입
    public init(
        refresh: @escaping @MainActor (String) async -> AccountState?,
        notify: @escaping @MainActor (QuotaResetAlert) async -> Void
    ) {
        self.refresh = refresh
        self.notify = notify
    }

    /// 상태·설정 변경 시 예약 교체; 로딩과 일시적 실패는 기존 예약만 유지
    public func reconcile(states: [AccountState], reminderMinutes: Int, now: Date = Date()) {
        let nextLead = PreferencesStore.normalizedResetReminderMinutes(reminderMinutes)
        let leadChanged = nextLead != self.reminderMinutes
        self.reminderMinutes = nextLead
        accounts = Dictionary(states.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for account in states {
            for window in Window.allCases {
                let key = "\(account.id).\(window.rawValue)"
                let reset = window == .primary ? account.primaryResetAt : account.secondaryResetAt
                let observation = window == .primary ? account.primaryResetObservation : account.secondaryResetObservation
                let segmentID = window == .primary ? account.primaryResetSegmentID : account.secondaryResetSegmentID
                if var old = entries[key], sameIdentity(old.account, account), old.segmentID == segmentID {
                    // 도달과 동시에 정기 조회가 완료되어도 미처리 도달 이벤트 유지
                    if old.resetAt <= now && !old.boundaryHandled,
                       [.normal, .loading, .timeout, .error].contains(account.status) {
                        continue
                    }
                    if let reset, abs(reset.timeIntervalSince(old.resetAt)) <= 2,
                       observation == .stableObserved,
                       [.normal, .loading, .timeout, .error].contains(account.status) {
                        if leadChanged {
                            old.reminderHandled = nextLead == 0 || now >= old.resetAt.addingTimeInterval(-Double(nextLead * 60))
                        }
                        entries[key] = old
                        continue
                    }
                }
                entries[key] = nil
                guard account.status == .normal, observation == .stableObserved,
                      let reset, reset.timeIntervalSince1970.isFinite, reset > now else { continue }
                entries[key] = Entry(
                    account: account, window: window, resetAt: reset, segmentID: segmentID,
                    reminderHandled: nextLead == 0 || now >= reset.addingTimeInterval(-Double(nextLead * 60))
                )
            }
        }
        entries = entries.filter { accounts[$0.value.account.id] != nil }
    }

    /// 초당 로컬 시각 비교 시작; 네트워크 조회는 도달 이벤트에서만 수행
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }

    /// 앱 종료 시 로컬 타이머 및 예약 해제
    public func stop() {
        loop?.cancel()
        loop = nil
        entries.removeAll()
    }

    /// 도달 계정별 1회 재조회 후 알림; 절전 중 지나간 사전 알림 생략
    public func tick(now: Date = Date()) async {
        guard !isTicking else { return }
        isTicking = true
        defer { isTicking = false }
        var due: [Entry] = []
        var reminders: [Entry] = []
        for key in entries.keys.sorted() {
            guard var entry = entries[key] else { continue }
            if !entry.boundaryHandled && entry.resetAt <= now {
                entry.boundaryHandled = true
                entry.reminderHandled = true
                due.append(entry)
            } else if !entry.reminderHandled && reminderMinutes > 0 {
                let fireAt = entry.resetAt.addingTimeInterval(-Double(reminderMinutes * 60))
                if fireAt <= now {
                    entry.reminderHandled = true
                    if now < entry.resetAt && now.timeIntervalSince(fireAt) < 60 {
                        reminders.append(entry)
                    }
                }
            }
            entries[key] = entry
        }
        for entry in reminders {
            guard let current = accounts[entry.account.id], sameIdentity(entry.account, current), !Task.isCancelled else { continue }
            guard entry.segmentID == segmentID(current, window: entry.window) else { continue }
            if entry.window == .primary, current.secondaryRemainingPercent == 0 { continue }
            let currentReset = entry.window == .primary ? current.primaryResetAt : current.secondaryResetAt
            guard let currentReset, abs(currentReset.timeIntervalSince(entry.resetAt)) <= 2 else { continue }
            await notify(QuotaResetAlert(
                accountID: entry.account.id, title: "할당량 초기화 예정",
                body: "\(entry.account.id): \(reminderMinutes)분 뒤 \(entry.window.title)이 초기화될 예정입니다."
            ))
        }
        let ids = Set(due.map { $0.account.id }).sorted()
        var refreshed: [String: AccountState] = [:]
        await withTaskGroup(of: (String, AccountState?).self) { group in
            for id in ids {
                guard let first = due.first(where: { $0.account.id == id }),
                      let current = accounts[id], sameIdentity(first.account, current), !Task.isCancelled else { continue }
                group.addTask { [refresh] in (id, await refresh(id)) }
            }
            for await (id, state) in group {
                if let state { refreshed[id] = state }
            }
        }
        for id in ids {
            guard let first = due.first(where: { $0.account.id == id }),
                  let before = accounts[id], sameIdentity(first.account, before), !Task.isCancelled else { continue }
            let updated = refreshed[id]
            for entry in due where entry.account.id == id {
                guard let current = accounts[id], sameIdentity(entry.account, current), !Task.isCancelled else { continue }
                if entry.segmentID != segmentID(current, window: entry.window) {
                    guard let updated, QuotaResetChange.detect(previous: entry.account, current: updated, now: now)
                        .contains(where: { $0.window.rawValue == entry.window.rawValue && $0.kind == .reset && $0.cause == .scheduled }) else { continue }
                }
                if entry.window == .primary,
                   (updated?.secondaryRemainingPercent ?? current.secondaryRemainingPercent) == 0 { continue }
                let reset = entry.window == .primary ? updated?.primaryResetAt : updated?.secondaryResetAt
                let detail: String
                if updated?.status != .normal {
                    detail = "최신 상태를 확인하지 못했습니다. 다음 정기 조회에서 다시 확인합니다."
                } else if let reset, reset > entry.resetAt.addingTimeInterval(2) {
                    detail = "조회 후 초기화 시각 변경을 확인했습니다."
                } else {
                    detail = "다시 조회했으며 초기화 시각 변경은 아직 확인되지 않았습니다."
                }
                await notify(QuotaResetAlert(
                    accountID: id, title: "할당량 초기화 예정 시각 도달",
                    body: "\(id)의 \(entry.window.title) 초기화 예정 시각에 도달했습니다. \(detail)"
                ))
            }
        }
    }

    /// 계정 경로 세대·로그인 계정·구독의 일치 확인
    private func sameIdentity(_ lhs: AccountState, _ rhs: AccountState) -> Bool {
        lhs.id == rhs.id && lhs.configurationGeneration == rhs.configurationGeneration
            && lhs.email == rhs.email && lhs.planType == rhs.planType
    }

    /// 알림 대상을 현재 한도별 관측 구간과 대조하는 식별자 조회
    private func segmentID(_ account: AccountState, window: Window) -> UUID? {
        window == .primary ? account.primaryResetSegmentID : account.secondaryResetSegmentID
    }
}
