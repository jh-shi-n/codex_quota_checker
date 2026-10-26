// 목적: Foundation 자식 프로세스 그룹의 제한시간 종료 및 비차단 파이프 정리
// 이용처: Codex 조회와 업데이트 검증 도구의 자식 수명 관리
import Darwin
import Foundation

/// Foundation이 생성한 전용 그룹만 종료하는 공통 도구
public enum ProcessGroupTermination {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var groups = Set<pid_t>()
    /// 부모 앱과 분리된 그룹 ID의 실행 직후 확인
    static func group(of process: Process) -> pid_t? {
        let pid = process.processIdentifier
        guard pid > 1, getpgid(pid) == pid, pid != getpgrp() else { return nil }
        lock.lock(); groups.insert(pid); lock.unlock()
        return pid
    }

    /// wrapper 종료 이후에도 같은 그룹의 native 자식에 TERM·KILL 전달
    static func terminate(_ process: Process, group: pid_t?, until deadline: Date) {
        defer {
            if let group { lock.lock(); groups.remove(group); lock.unlock() }
        }
        if let group { _ = kill(-group, SIGTERM) }
        else if process.isRunning { process.terminate() }
        let grace = min(deadline, Date().addingTimeInterval(0.25))
        while Date() < grace {
            let alive = group.map { kill(-$0, 0) == 0 } ?? process.isRunning
            if !alive { break }
            Thread.sleep(forTimeInterval: min(0.01, max(0, grace.timeIntervalSinceNow)))
        }
        if let group { _ = kill(-group, SIGKILL) }
        else if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
    }

    /// 종료 응답 전에 남은 probe·토큰·app-server 자식 그룹의 강제 정리 대기
    public static func shutdown() async {
        await Task.detached { shutdownSync() }.value
    }

    /// 동기 worker에서 종료 대상 그룹 스냅샷 정리
    private static func shutdownSync() {
        lock.lock(); let remaining = groups; lock.unlock()
        for group in remaining { _ = kill(-group, SIGTERM) }
        if !remaining.isEmpty { Thread.sleep(forTimeInterval: 0.25) }
        for group in remaining { _ = kill(-group, SIGKILL) }
        lock.lock(); groups.subtract(remaining); lock.unlock()
    }

    /// EOF를 보장하지 않는 상속 파이프의 제한시간·최대 바이트 비차단 읽기
    static func drain(_ handle: FileHandle, limit: Int, receive: (Data) -> Void) {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return }
        let deadline = Date().addingTimeInterval(0.1)
        var remaining = limit
        var buffer = [UInt8](repeating: 0, count: 8192)
        while remaining > 0 && Date() < deadline {
            let count = Darwin.read(fd, &buffer, min(buffer.count, remaining))
            if count > 0 { receive(Data(buffer.prefix(count))); remaining -= count }
            else if count == -1 && errno == EINTR { continue }
            else { return }
        }
    }
}
