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
            Text("잔디는 최근 24주를 표시합니다. 계정 서버에서 제공한 날짜만 사용하며, 미제공 날짜는 0으로 표시하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            Text("표시 범위는 서버의 내역 제공 기간을 늘리지 않습니다. 로컬 세션 로그는 토큰 집계에 사용하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
