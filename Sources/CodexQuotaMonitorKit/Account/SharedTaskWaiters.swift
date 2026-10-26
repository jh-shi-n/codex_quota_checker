// 목적: 공유 비동기 조회의 소비자 가입과 마지막 소비자 취소 간 경쟁 차단
// 이용처: AccountStore detached 조회의 waiter 수명 관리
import Foundation

/// 마지막 소비자 이탈과 신규 가입 허용 여부의 원자적 관리
final class SharedTaskWaiters: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters = Set<UUID>()
    private var closing = false
    private let cancel: @Sendable () -> Void

    /// 마지막 소비자 이탈 시 실행할 취소 동작 지정
    init(cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }

    /// 취소 시작 이후 신규 소비자의 기존 작업 가입 거부
    func tryAdd(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closing else { return false }
        waiters.insert(id)
        return true
    }

    /// 비어 있는 상태를 닫힘으로 전이한 뒤 실제 작업 취소
    func remove(_ id: UUID) {
        lock.lock()
        let removed = waiters.remove(id) != nil
        let shouldCancel = removed && waiters.isEmpty && !closing
        if shouldCancel { closing = true }
        lock.unlock()
        if shouldCancel { cancel() }
    }
}
