// 목적: SQLite 작업의 UI 실행 흐름 분리 및 직렬 실행
// 이용처: 설정 캐시와 계정 토큰 캐시의 비동기 영속화
import Foundation

/// 단일 DB를 공유하는 캐시 작업의 전용 직렬 큐
 enum DatabaseWorkQueue {
    private static let queue = DispatchQueue(label: "com.codexquotamonitor.database", qos: .utility)

    /// 동기 SQLite 작업을 전용 큐에서 수행하고 결과 전달
    static func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }
}
