// 목적: 서버 계정 토큰 그래프의 형태·날짜 표시 범위 설정
// 이용처: 앱 설정의 토큰 사용량 섹션
// 사용방법: 저장된 표시 옵션 바인딩 전달
import SwiftUI

/// 서버 보관 범위와 구분한 그래프 표시 정책
struct TokenUsageSettingsSection: View {
    @Binding var options: TokenUsageOptions

    var body: some View {
        Section("계정 토큰 사용량") {
            Picker("표시 방식", selection: $options.displayMode) {
                ForEach(TokenUsageDisplayMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("token-usage-display-mode")
            Picker("날짜 표시 범위", selection: $options.retentionMonths) {
                Text("3개월").tag(3)
                Text("6개월").tag(6)
                Text("1년").tag(12)
            }
            Text("서버 사용량을 우선 표시합니다. 오늘 내역이 없으면 연결 계정의 로컬 사용량으로 보완합니다. 잔디는 최근 24주를 표시합니다.")
                .font(.caption).foregroundStyle(.secondary)
            Text("날짜는 UTC를 기준으로 표시하며, 미제공 날짜는 0과 구분합니다. 로컬 기록은 서버의 누적·일 최대 수치를 바꾸지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
