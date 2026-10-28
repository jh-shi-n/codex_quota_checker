// 목적: Claude 로컬 토큰 집계 범위와 새로고침 안내
// 이용처: Claude 계정 토큰 사용량 영역
// 사용방법: 현재 계정의 토큰 사용량 아래 배치
// 실행 예시: ClaudeTokenCollectionView(account: account)
import SwiftUI

/// 별도 연결 없이 로컬 기록을 조회하는 토큰 사용량 안내
struct ClaudeTokenCollectionView: View {
    let account: AccountState

    var body: some View {
        Text("우상단 새로고침으로 Stats 캐시와 세션 기록을 다시 읽습니다. 연결 폴더의 기록만 포함하며 별도 수집 연결은 필요하지 않습니다.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
