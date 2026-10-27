// 목적: 기존 링 그래픽과 로딩 애니메이션 유지
// 이용처: 노치·계정 상세·설정 미리보기
// 사용방법: 계정과 지름·색상 모드 전달
// 실행 예시: QuotaRingGraphic(account: account, diameter: 22)
import SwiftUI

/// 노치와 계정 상세에서 재사용하는 기존 링 그래픽
struct QuotaRingGraphic: View {
    let account: AccountState
    let diameter: CGFloat
    let showAccountLabel: Bool
    /// 고정 배경에서 글자와 소진 구간에 함께 적용하는 색상 모드
    let fixedAppearance: QuotaAppearance?

    @Environment(\.accountDisplayNames) private var accountDisplayNames
    @Environment(\.colorScheme) private var colorScheme
    @State private var loadingRotation = 0.0
    @State private var loadingAnimationState = QuotaLoadingAnimationState()

    /// 고정 배경 색상 모드 또는 시스템 색상 모드를 사용하는 링 초기화
    init(
        account: AccountState,
        diameter: CGFloat,
        showAccountLabel: Bool = true,
        fixedAppearance: QuotaAppearance? = nil
    ) {
        self.account = account
        self.diameter = diameter
        self.showAccountLabel = showAccountLabel
        self.fixedAppearance = fixedAppearance
    }

    var body: some View {
        let state = QuotaDonutState(account: account)
        let presentation = QuotaDonutPresentation(account: account)
        let progress = presentation.ringPercent.map { $0 / 100 } ?? 0
        let appearance = fixedAppearance ?? (colorScheme == .dark ? .dark : .light)

        ZStack {
            Circle()
                .stroke(
                    presentation.trackColor(for: appearance).swiftUIColor,
                    style: StrokeStyle(lineWidth: QuotaDonutMetrics.ringWidth, lineCap: .round)
                )

            if state.isLoading {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(
                        Color.accentColor.opacity(0.76),
                        style: StrokeStyle(lineWidth: QuotaDonutMetrics.ringWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90 + loadingRotation))
            } else if let percent = presentation.ringPercent, percent > 0 {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        presentation.ringColor?.swiftUIColor ?? QuotaColors.swiftUIColor(for: percent),
                        style: StrokeStyle(lineWidth: QuotaDonutMetrics.ringWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            } else if state.showsErrorRing {
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(
                        QuotaColors.swiftUIColor(for: 0),
                        style: StrokeStyle(lineWidth: QuotaDonutMetrics.ringWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }

            VStack(spacing: showAccountLabel ? -1 : 0) {
                if let symbol = state.centerSymbol {
                    Text(symbol)
                        .font(.system(size: max(9, diameter * (showAccountLabel ? 0.68 : 0.74)), weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.65)
                } else if let percent = presentation.centerPercent {
                    Text(
                        showAccountLabel
                            ? QuotaDonutView.percentText(percent)
                            : QuotaDonutMetrics.compactValueText(percent)
                    )
                        .font(.system(
                            size: max(
                                showAccountLabel ? 6.5 : 9.5,
                                diameter * (showAccountLabel ? 0.34 : 0.48)
                            ),
                            weight: .semibold,
                            design: .monospaced
                        ))
                        .minimumScaleFactor(showAccountLabel ? 0.55 : 0.7)
                        .lineLimit(1)
                }

                if showAccountLabel {
                    Text(AccountDisplayName.resolved(accountDisplayNames[account.id], slotID: account.id))
                        .font(.system(size: max(5, diameter * 0.26), weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.55)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(fixedAppearance.map {
                QuotaDonutMetrics.centerTextColor(for: $0).swiftUIColor
            } ?? .primary)
            .frame(width: diameter * (showAccountLabel ? 0.88 : 0.96), height: diameter * (showAccountLabel ? 0.78 : 0.88))
        }
        .frame(width: diameter, height: diameter)
        .onAppear {
            updateLoadingAnimation(isLoading: state.isLoading)
        }
        .onChange(of: state.isLoading) { _, isLoading in
            updateLoadingAnimation(isLoading: isLoading)
        }
        .onDisappear {
            loadingAnimationState.reset()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                loadingRotation = 0
            }
        }
    }

    /// 최초 로딩 전환에만 회전 시작 및 완료 시 애니메이션 중지
    private func updateLoadingAnimation(isLoading: Bool) {
        switch loadingAnimationState.transition(isLoading: isLoading) {
        case .none:
            return
        case .stop:
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                loadingRotation = 0
            }
        case .start:
            loadingRotation = 0
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                loadingRotation = 360
            }
        }
    }
}
