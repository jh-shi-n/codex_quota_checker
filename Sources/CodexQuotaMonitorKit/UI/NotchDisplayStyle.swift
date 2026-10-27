// 목적: 노치 디자인 종류·크기와 새 디자인의 순수 표시 계산 정의
// 이용처: 설정 미리보기·노치 그래픽·패널 배치
// 사용방법: 스타일 선택 및 계정별 NotchQuotaPresentation 생성
// 실행 예시: NotchQuotaPresentation(account: account)
import Foundation

/// 기존 링을 기본값으로 유지하는 노치 디자인
public enum NotchDisplayStyle: String, CaseIterable, Sendable {
    case ring, horizontalBars, verticalBars, stackedNumbers

    /// 설정에 표시할 디자인 이름
    public var title: String {
        switch self {
        case .ring: "링"
        case .horizontalBars: "숫자 + 가로막대"
        case .verticalBars: "숫자 + 세로막대"
        case .stackedNumbers: "숫자 2단"
        }
    }

    /// 비율 유지 축소의 기준이 되는 디자인별 원래 크기
    public var size: CGSize {
        switch self {
        case .ring: CGSize(width: 22, height: 22)
        case .horizontalBars: CGSize(width: 34, height: 30)
        case .verticalBars: CGSize(width: 22, height: 22)
        case .stackedNumbers: CGSize(width: 22, height: 22)
        }
    }

    /// 링 한 칸의 정사각형 안에 원래 비율을 유지하는 그래픽 크기
    public func fittedSize(forDiameter diameter: CGFloat) -> CGSize {
        let safeDiameter = diameter.isFinite ? max(0, diameter) : 0
        let scale = safeDiameter / max(size.width, size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// 링과 독립된 5시간·전체 값 표시 및 새 디자인의 50·20 경계 규칙
struct NotchQuotaPresentation {
    let fiveHour: Double?
    let overall: Double?
    let placeholder: String
    static let track = QuotaRGB(red: 0x3A, green: 0x3A, blue: 0x3A)
    static let secondary = QuotaRGB(red: 0x9A, green: 0x9A, blue: 0x9A)

    /// 기존 계정 상태 분류 재사용 및 인증 불가 상태의 이전 값 숨김
    init(account: AccountState) {
        let state = QuotaDonutState(account: account)
        switch account.status {
        case .normal, .loading, .timeout, .error:
            fiveHour = account.fiveHourRemainingPercent.map(QuotaColors.clampedPercent)
            overall = account.overallRemainingPercent.map(QuotaColors.clampedPercent)
        case .notConfigured, .loginRequired, .codexNotFound:
            fiveHour = nil
            overall = nil
        }
        placeholder = state.centerSymbol ?? (state.isLoading ? "…" : "—")
    }

    /// 범위 정규화 후 기존 숫자 반올림 규칙 적용; 누락값 구분
    func text(_ value: Double?) -> String {
        value.map(QuotaDonutMetrics.compactValueText) ?? placeholder
    }

    /// 반올림 이전 실제 잔여량 기준의 초록·노랑·빨강 선택
    static func color(for value: Double?) -> QuotaRGB {
        guard let value else { return secondary }
        switch QuotaColors.clampedPercent(value) {
        case 50...: return QuotaColors.normal
        case 20..<50: return QuotaColors.attention
        default: return QuotaColors.low
        }
    }

    /// 누락값과 비정상 수치를 포함하는 0…1 채움 비율
    static func progress(_ value: Double?) -> Double {
        value.map { QuotaColors.clampedPercent($0) / 100 } ?? 0
    }
}
