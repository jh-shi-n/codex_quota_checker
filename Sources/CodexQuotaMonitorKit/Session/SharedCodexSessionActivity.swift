// 목적: 인증된 추가 홈의 세션 활동 결합
// 이용처: 활동 감시기·계정 상세의 공통 소스 처리
// 사용방법: SharedCodexSessionActivity.snapshot 호출
// 실행 예시: await SharedCodexSessionActivity.snapshot(account: slot, accounts: slots, provider: provider)
import Foundation

/// 기존 제공자의 홈별 개인정보·행 수 제한을 유지하는 결합 경계
public enum SharedCodexSessionActivity {
    /// 매 조회 인증 확인과 세션 ID별 최신 메타데이터 단일 표시
    public static func snapshot(account: AccountConfig, accounts: [AccountConfig],
                                provider: any SessionActivityProvider,
                                resolver: SharedCodexHomeResolver = SharedCodexHomeResolver()) async -> SessionActivitySnapshot {
        let signature = resolver.signature(for: account, accounts: accounts)
        let homes = resolver.homes(for: account, accounts: accounts)
        var snapshots: [SessionActivitySnapshot] = []
        for home in homes { snapshots.append(await provider.snapshot(accountID: account.id, home: home)) }
        guard signature == resolver.signature(for: account, accounts: accounts) else { return .unavailable(accountID: account.id) }
        if snapshots.count == 1 { return snapshots[0] }
        var sessions: [String: SessionActivityMainSession] = [:]
        for snapshot in snapshots {
            for session in snapshot.sessions {
                if let old = sessions[session.threadID],
                   (old.lastActivityAt ?? .distantPast) >= (session.lastActivityAt ?? .distantPast) { continue }
                sessions[session.threadID] = session
            }
        }
        return SessionActivitySnapshot(accountID: account.id,
            state: snapshots.allSatisfy { $0.state == .unavailable } ? .unavailable : .available,
            sessions: SessionActivityMainSession.ordered(Array(sessions.values)))
    }
}
