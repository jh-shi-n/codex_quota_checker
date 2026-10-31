// 목적: 설정 표시 탭의 디자인 선택·미리보기 제공
// 이용처: SettingsView의 표시 탭
// 사용방법: 저장소와 연결된 스타일 바인딩 전달
// 실행 예시: NotchDisplayStyleSettingsSection(selection: $style)
import SwiftUI

/// 모든 디자인을 동시에 비교할 수 있는 미리보기 포함 Picker
struct NotchDisplayStyleSettingsSection: View {
    @Binding var selection: NotchDisplayStyle

    var body: some View {
        Section("노치 표시 방식") {
            Picker("디자인", selection: $selection) {
                ForEach(NotchDisplayStyle.allCases, id: \.self) { style in
                    HStack(spacing: 12) {
                        preview(style)
                        Text(style.title)
                    }
                    .tag(style)
                }
            }
            .pickerStyle(.radioGroup)
            Text("5시간 할당량은 가로막대·숫자의 위쪽과 세로막대의 왼쪽에 표시합니다. 전체 할당량은 아래쪽과 오른쪽에 표시합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("남은 할당량이 50% 이상이면 초록, 20% 이상 50% 미만이면 노랑, 20% 미만이면 빨강으로 표시합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 실제 노치와 동일한 그래픽으로 정상·주의·부족 예시 제공
    private func preview(_ style: NotchDisplayStyle) -> some View {
        HStack(spacing: 12) {
            ForEach([92, 35, 12], id: \.self) { remaining in
                NotchQuotaGraphic(
                    account: AccountState(id: "preview-\(remaining)",
                                          primaryUsedPercent: Double(100 - remaining),
                                          secondaryUsedPercent: Double(100 - (remaining == 92 ? 100 : remaining == 35 ? 60 : 18)), status: .normal),
                    style: style, diameter: QuotaDonutMetrics.maximumDiameter
                )
            }
        }
        .frame(width: 160, height: 42)
        .background(.black, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}
