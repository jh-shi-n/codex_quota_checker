// 목적: 숫자·세로막대 노치 그래픽 구성
// 이용처: 노치와 설정 미리보기
// 사용방법: 정규화된 표시 모델 전달
// 실행 예시: QuotaVerticalBarsView(presentation: value)
import SwiftUI

/// 링 한 칸에 맞춘 두 자리 11pt·세 자리 9pt 숫자와 독립 세로막대
struct QuotaVerticalBarsView: View {
    let presentation: NotchQuotaPresentation

    var body: some View {
        let text = presentation.text(presentation.fiveHour)
        HStack(spacing: 1) {
            Text(text)
                .font(.system(size: QuotaVerticalBarsMetrics.fontSize(for: text),
                              weight: .semibold, design: .monospaced))
                .tracking(QuotaVerticalBarsMetrics.tracking)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(.white)
                .frame(width: QuotaVerticalBarsMetrics.numberWidth)
            HStack(spacing: 1) {
                QuotaBarView(value: presentation.fiveHour, vertical: true, size: CGSize(width: 2, height: 18))
                QuotaBarView(value: presentation.overall, vertical: true, size: CGSize(width: 2, height: 18))
            }
        }
        .frame(width: 22, height: 22)
    }
}

/// 세 자리 숫자까지 말줄임 없이 표시하는 고정 숫자 영역 규격
enum QuotaVerticalBarsMetrics {
    static let numberWidth: CGFloat = 16
    static let tracking: CGFloat = -0.3

    /// 두 자리 숫자의 크기 유지 및 세 자리 숫자만 축소
    static func fontSize(for text: String) -> CGFloat {
        text.count >= 3 ? 9 : 11
    }
}
