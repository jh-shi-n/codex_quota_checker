// 목적: 초기화 시간 설정의 수동 실행·자동 전송 선택·결과 표시
// 이용처: 링 버튼의 계정 상세 화면
// 사용방법: 계정·실행 상태와 관찰 가능한 설정 호스트 연결
import SwiftUI

/// 설정 변경을 관찰하여 계정 상세 간 공통 체크 상태와 저장 실패 반영
struct UsageWindowProbePreferencesView: View {
    @ObservedObject var preferences: PreferencesStore
    let section: UsageWindowProbeSection

    var body: some View {
        var content = section
        content.automaticResetPingEnabled = Binding(
            get: { preferences.automaticResetPingEnabled },
            set: { preferences.updateAutomaticResetPing($0) }
        )
        content.automaticResetPingError = preferences.persistenceError
        return content
    }
}

/// 초기화 시간 설정 요청의 실행 상태와 결과 표시
public struct UsageWindowProbeSection: View {
    /// 섹션 제목
    public static let sectionTitle = "초기화 시간 설정"

    /// 실제 요청과 서버 초기화 시각의 관계를 설명하는 안내
    public static let informationText = "짧은 확인 요청을 보내 사용 구간을 시작하고, 서버에서 초기화 시간을 다시 확인합니다. 소량의 토큰이 사용되며, 초기화 시간은 서버 상태에 따라 달라질 수 있습니다."

    public let account: AccountState
    public let probe: UsageWindowProbePresentationResult?
    public let isRunning: Bool
    public let runningStartedAt: Date?
    public let lastExecutionAt: Date?
    public let isConfigured: Bool
    public let onRun: () -> Void
    public var automaticResetPingEnabled: Binding<Bool>?
    public var automaticResetPingError: String?
    @State private var isInformationPresented = false

    /// 계정과 최신 Reset 결과를 받는 섹션 생성
    public init(
        account: AccountState,
        probe: UsageWindowProbePresentationResult? = nil,
        isRunning: Bool = false,
        runningStartedAt: Date? = nil,
        lastExecutionAt: Date? = nil,
        isConfigured: Bool? = nil,
        onRun: @escaping () -> Void = {},
        automaticResetPingEnabled: Binding<Bool>? = nil
    ) {
        self.account = account
        self.probe = probe
        self.isRunning = isRunning
        self.runningStartedAt = runningStartedAt
        self.lastExecutionAt = lastExecutionAt
        self.isConfigured = isConfigured ?? (account.status != .notConfigured)
        self.onRun = onRun
        self.automaticResetPingEnabled = automaticResetPingEnabled
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(Self.sectionTitle)
                    .font(.headline.weight(.semibold))
                    .fixedSize()
                if let automaticResetPingEnabled {
                    Toggle("자동 전송", isOn: automaticResetPingEnabled)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                        .help("모든 계정에 공통 적용됩니다. 초기화 후 최소 Ping으로 실제 할당량을 사용하며, 주간 잔량 10% 이하·미확인 또는 5시간 잔량 소진 시 생략합니다.")
                        .accessibilityIdentifier("automatic-reset-ping-toggle")
                        .accessibilityLabel("할당량 초기화 시 자동 전송")
                }
                Button { isInformationPresented.toggle() } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.appIcon)
                .help("초기화 시간 설정 작동 방식")
                .accessibilityLabel("초기화 시간 설정 안내")
                .popover(isPresented: $isInformationPresented, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("작동 방식")
                            .font(.headline)
                        Text(Self.informationText)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .frame(width: 290, alignment: .leading)
                }
            }

            if let automaticResetPingError {
                Text(automaticResetPingError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    ProbeFlightAnimation(state: flightState)
                        .id("\(account.id)-\(account.configurationGeneration)")
                        .frame(minWidth: 48)
                    Button(action: onRun) {
                        Text(buttonTitle)
                    }
                    .buttonStyle(.appPrimary)
                    .disabled(!canRun)
                    .help("최소 요청으로 사용 구간을 시작하고 서버의 초기화 시간을 확인합니다. 실제 사용량이 발생하며, 시간 설정 여부는 서버 상태에 따라 달라집니다.")
                    .accessibilityLabel(buttonTitle)
                    .accessibilityHint("최소 요청으로 서버 사용량이 발생할 수 있습니다")
                }

                probeDetails
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            }
        }
    }

    /// 요청 전송과 한도 조회를 합친 비행 표시 상태
    var flightState: ProbeFlightState {
        if isRunning { return .sending }
        guard let result = probe?.result else { return .idle }
        return result.isSuccess && probe?.quotaRefreshSucceeded != false ? .succeeded : .failed
    }

    /// 설정 계정의 유휴 상태 실행 허용 여부
    public var canRun: Bool {
        isConfigured && AccountDashboardActionState.canRunProbe(
            account: account,
            isRunning: isRunning
        )
    }

    /// 실행 중 여부에 따른 버튼 표시명
    public var buttonTitle: String {
        if isRunning { return "전송 중…" }
        return "시간 설정"
    }

    @ViewBuilder
    private var probeDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            detailRow(label: "마지막 실행 시각", value: lastRunText)
            detailRow(label: "결과", value: resultText)
            detailRow(label: "소모 토큰", value: tokenText)
        }
        .font(.caption)
    }

    /// 결과 행의 레이블과 표시값 구성
    @ViewBuilder
    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .fontWeight(.medium)
                .lineLimit(2)
        }
    }

    /// 마지막 버튼 실행 시각 표시; 서버 응답 시각으로 덮어쓰기 제외
    var lastRunText: String {
        let startedAt = lastExecutionAt ?? runningStartedAt
        guard let startedAt else { return "—" }
        return AccountDashboardFormatting.dateText(startedAt, timeStyle: .medium)
    }

    /// Ping 실행·취소와 한도 재조회 결과를 구분한 문구
    var resultText: String {
        // While a new request is active, do not leave a previous failure or
        // success looking like the current result. The terminal categorical
        // result is shown again as soon as the callback completes.
        if isRunning { return "전송 중" }
        guard let result = probe?.result else {
            return "실행 전"
        }
        if result.isCancelled { return "취소됨" }
        if result.isSuccess, probe?.quotaRefreshSucceeded == false {
            return "전송 완료 · 한도 조회 실패"
        }
        if result.isSuccess, probe?.quotaRefreshSucceeded == true {
            return "초기화 시간 확인 완료"
        }
        return result.isSuccess ? "전송 완료" : (result.failureCategory?.userMessage ?? "실패")
    }

    /// 서버가 제공한 합계 또는 입력·출력 합산만 표시하고 이전 실행 수치 혼용 방지
    var tokenText: String {
        guard !isRunning, let usage = probe?.result.usage, usage.hasReportedUsage else { return "—" }
        if let total = usage.totalTokensIncludingComponents {
            return "\(AccountDashboardFormatting.numberText(Int64(total))) 토큰"
        }
        return [
            usage.inputTokens.map { "입력 \(AccountDashboardFormatting.numberText(Int64($0)))" },
            usage.outputTokens.map { "출력 \(AccountDashboardFormatting.numberText(Int64($0)))" },
        ].compactMap { $0 }.joined(separator: " · ")
    }

}
