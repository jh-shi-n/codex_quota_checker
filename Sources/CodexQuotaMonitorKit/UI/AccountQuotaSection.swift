// 목적: 제공자별 할당량 비율·초기화 예정 시각 표시
// 이용처: 계정 상세의 5시간·주간 할당량 카드
// 사용방법: AccountQuotaSection(account:) 구성
// 실행 예시: AccountQuotaSection(account: state)
import SwiftUI

/// 제공자별 예정 시각 표시 기준을 적용한 두 할당량 카드
public struct AccountQuotaSection: View {
    public let account: AccountState

    /// 현재 계정의 할당량·예정 시각 스냅샷 연결
    public init(account: AccountState) {
        self.account = account
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("현재 할당량")
                        .font(.headline.weight(.semibold))
                        .fixedSize()
                    if let notice = AccountDashboardFormatting.fiveHourResetNotice(for: account, now: context.date) {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                HStack(alignment: .top, spacing: 8) {
                    quotaCard(
                        title: "5시간 할당량",
                        subtitle: "5-hour quota",
                        remaining: account.fiveHourRemainingPercent,
                        resetAt: account.primaryResetAt,
                        observation: account.primaryResetObservation,
                        isVerificationPending: account.isPrimaryResetVerificationPending,
                        now: context.date
                    )
                    quotaCard(
                        title: account.provider == .claude ? "주간 할당량" : "전체 할당량",
                        subtitle: account.provider == .claude ? "Weekly quota" : "Overall quota",
                        remaining: account.overallRemainingPercent,
                        resetAt: account.secondaryResetAt,
                        observation: account.secondaryResetObservation,
                        isVerificationPending: account.isSecondaryResetVerificationPending,
                        now: context.date
                    )
                }
            }
        }
    }

    /// 제공자별 확인 기준을 통과한 미래 예정 시각의 날짜·카운트다운 표시
    @ViewBuilder
    private func quotaCard(
        title: String,
        subtitle: String,
        remaining: Double?,
        resetAt: Date?,
        observation: ResetTimeObservation,
        isVerificationPending: Bool,
        now: Date
    ) -> some View {
        let displayedReset = AccountDashboardFormatting.observedResetDate(
            resetAt, observation: observation, status: account.status, now: now, provider: account.provider
        )
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .accessibilityLabel(subtitle)

            HStack(alignment: .center, spacing: 10) {
                DashboardQuotaRing(remainingPercent: remaining)
                    .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("남은 시간")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(AccountDashboardFormatting.remainingTimeText(until: displayedReset, now: now))
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("초기화")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(AccountDashboardFormatting.dateText(displayedReset))
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(isVerificationPending ? "초기화 시각 재확인 중" : AccountDashboardFormatting.resetScheduleStatusText(
                resetAt, observation: observation, status: account.status, now: now, provider: account.provider
            ))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(subtitle), \(remaining.map { QuotaDonutView.percentText($0) } ?? "—")")
    }
}

/// A quota ring whose value can be selected independently of the account's
/// compact dual-window donut.
struct DashboardQuotaRing: View {
    let remainingPercent: Double?

    var body: some View {
        let value = remainingPercent.map(QuotaColors.clampedPercent)
        let progress = (value ?? 0) / 100
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: 9)
            if let value {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        QuotaColors.swiftUIColor(for: value),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(QuotaDonutView.percentText(value))
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                    Text("남음")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("—")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Quota \(value.map { QuotaDonutView.percentText($0) } ?? "unavailable")")
    }
}
