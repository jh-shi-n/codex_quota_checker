// 목적: 위 5시간·아래 전체 숫자 노치 그래픽 구성
// 이용처: 노치와 설정 미리보기
// 사용방법: 정규화된 표시 모델 전달
// 실행 예시: QuotaStackedNumbersView(presentation: value)
import SwiftUI

/// 값 색상의 5시간 숫자와 고정 회색의 전체 숫자
struct QuotaStackedNumbersView: View {
    let presentation: NotchQuotaPresentation

    var body: some View {
        VStack(spacing: 0) {
            Text(presentation.text(presentation.fiveHour))
                .font(.system(size: QuotaStackedNumbersMetrics.primaryFontSize, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
                .foregroundStyle(NotchQuotaPresentation.color(for: presentation.fiveHour).swiftUIColor)
                .frame(width: 22, height: 12)
            Text(presentation.text(presentation.overall))
                .font(.system(size: QuotaStackedNumbersMetrics.secondaryFontSize, weight: .regular, design: .monospaced))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
                .foregroundStyle(NotchQuotaPresentation.secondary.swiftUIColor)
                .frame(width: 22, height: 10)
        }
        .frame(width: 22, height: 22)
    }
}

/// 링 한 칸에 세 자리 숫자 두 줄을 온전히 표시하는 글꼴 규격
enum QuotaStackedNumbersMetrics {
    static let primaryFontSize: CGFloat = 11
    static let secondaryFontSize: CGFloat = 9
}
