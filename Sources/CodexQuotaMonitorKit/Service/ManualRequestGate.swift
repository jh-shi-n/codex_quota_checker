// 목적: 계정별 연속 수동 요청 3회 허용과 마지막 클릭 기준 5초 차단
// 이용처: 새로고침·수동 Ping의 공통 진입점과 상세 화면 안내
// 사용방법: 전송 전 allow 호출, message로 차단 안내 조회
import Combine
import Foundation

/// 자동·후속 조회와 분리된 사용자 요청의 연속 클릭 제한
@MainActor
public final class ManualRequestGate: ObservableObject {
    public static let shared = ManualRequestGate()
    private struct Key: Hashable {
        let id: String
        let generation: Int
    }
    private struct Burst {
        var count: Int
        var lastAttempt: TimeInterval
    }
    @Published private var bursts: [Key: Burst] = [:]
    private let uptime: () -> TimeInterval
    public static let cooldown: TimeInterval = 5

    /// 벽시계 변경과 무관한 단조 시계 또는 테스트 시계 연결
    public init(uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
    }

    /// 마지막 시도에서 5초 미만이면 연속 횟수 증가; 네 번째부터 전송 차단
    public func allow(_ account: AccountState) -> Bool {
        let key = Key(id: account.id, generation: account.configurationGeneration)
        let now = uptime()
        var burst = bursts[key] ?? Burst(count: 0, lastAttempt: now)
        let elapsed = now - burst.lastAttempt
        if elapsed >= Self.cooldown || elapsed < 0 { burst.count = 0 }
        burst.count = min(4, burst.count + 1)
        burst.lastAttempt = now
        bursts[key] = burst
        return burst.count <= 3
    }

    /// 차단 중 재클릭마다 연장되는 마지막 시도 기준 안내
    public func message(for account: AccountState) -> String? {
        guard let burst = bursts[Key(id: account.id, generation: account.configurationGeneration)],
              burst.count > 3 else { return nil }
        let elapsed = uptime() - burst.lastAttempt
        return elapsed >= 0 && elapsed < Self.cooldown ? "5초 뒤 이용해주세요" : nil
    }
}
