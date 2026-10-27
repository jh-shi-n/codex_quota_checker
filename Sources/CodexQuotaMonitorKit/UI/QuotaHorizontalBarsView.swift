// 목적: 숫자·가로막대 노치 그래픽 구성
// 이용처: 노치와 설정 미리보기
// 사용방법: 정규화된 표시 모델 전달
// 실행 예시: QuotaHorizontalBarsView(presentation: value)
import SwiftUI

/// 위 5시간 숫자와 아래 5시간·전체 막대
struct QuotaHorizontalBarsView: View {
    let presentation: NotchQuotaPresentation

    var body: some View {
        VStack(spacing: 4) {
            Text(presentation.text(presentation.fiveHour))
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.white)
                .frame(height: 18)
            VStack(spacing: 2) {
                QuotaBarView(value: presentation.fiveHour, vertical: false)
                QuotaBarView(value: presentation.overall, vertical: false)
            }
        }
        .frame(width: 34, height: 30)
    }
}

/// 방향별 고정 트랙과 개별 값의 채움
struct QuotaBarView: View {
    let value: Double?
    let vertical: Bool
    /// 작은 노치 구역에서 사용하는 개별 막대 규격
    var size: CGSize? = nil

    var body: some View {
        let width: CGFloat = size?.width ?? (vertical ? 4 : 30)
        let height: CGFloat = size?.height ?? (vertical ? 20 : 3)
        let progress = NotchQuotaPresentation.progress(value)
        ZStack(alignment: vertical ? .bottom : .leading) {
            RoundedRectangle(cornerRadius: 2).fill(NotchQuotaPresentation.track.swiftUIColor)
            RoundedRectangle(cornerRadius: 2)
                .fill(NotchQuotaPresentation.color(for: value).swiftUIColor)
                .frame(width: vertical ? width : width * progress,
                       height: vertical ? height * progress : height)
        }
        .frame(width: width, height: height)
        .clipped()
    }
}
