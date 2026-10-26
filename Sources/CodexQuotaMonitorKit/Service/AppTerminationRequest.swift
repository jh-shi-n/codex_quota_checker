// 목적: Swift 작업의 동기 종료 대기와 비동기 정리 작업 사이의 교착 방지
// 이용처: 업데이트 helper 준비 이후 앱 종료 요청
// 사용방법: Task 안에서 schedule 호출, 요청 작업 반환 후 앱 실행 루프에서 종료
import AppKit

/// 종료 정리 Task가 실행될 수 있도록 AppKit 종료를 별도 실행 루프 작업으로 전달
@MainActor
public enum AppTerminationRequest {
    /// 실행 직전 요청 유효성을 재확인하고 Swift 작업 밖에서 종료 요청
    public static func schedule(when isCurrent: @escaping @MainActor @Sendable () -> Bool = { true }) {
        RunLoop.main.perform(inModes: [.common, .default]) {
            MainActor.assumeIsolated {
                guard isCurrent() else { return }
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
