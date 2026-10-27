// 목적: 선택된 디자인의 노치 그래픽 분기와 안전 영역 축소
// 이용처: 공통 계정 버튼·설정 미리보기
// 사용방법: 계정·스타일·표시 높이 전달
// 실행 예시: NotchQuotaGraphic(account: account, style: .ring, diameter: 22)
import SwiftUI

/// 기존 링과 스타일별 순수 그래픽의 공통 진입점
struct NotchQuotaGraphic: View {
    let account: AccountState
    let style: NotchDisplayStyle
    let diameter: CGFloat
    var showAccountLabel = false

    var body: some View {
        if style == .ring {
            QuotaRingGraphic(account: account, diameter: diameter,
                             showAccountLabel: showAccountLabel, fixedAppearance: .dark)
        } else {
            let presentation = NotchQuotaPresentation(account: account)
            let fittedSize = style.fittedSize(forDiameter: diameter)
            let scale = fittedSize.width / style.size.width
            graphic(presentation)
                .scaleEffect(scale)
                .frame(width: diameter, height: diameter)
        }
    }

    /// 디자인별 독립 그래픽 선택
    @ViewBuilder private func graphic(_ presentation: NotchQuotaPresentation) -> some View {
        switch style {
        case .horizontalBars: QuotaHorizontalBarsView(presentation: presentation)
        case .verticalBars: QuotaVerticalBarsView(presentation: presentation)
        case .stackedNumbers: QuotaStackedNumbersView(presentation: presentation)
        case .ring: EmptyView()
        }
    }
}
