// 목적: 어두운 계정 상세 화면의 구독 등급별 뱃지 색상 제공
import SwiftUI

/// 낮은 등급의 초록색부터 높은 등급의 붉은색까지 구독 색상 구성
enum SubscriptionBadgeStyle {
    /// 서버 구독 코드에 따른 뱃지 강조색 선택
    static func accentColor(for planType: String?) -> Color {
        let (red, green, blue) = components(for: planType)
        return Color(red: red, green: green, blue: blue)
    }

    /// 밝은 글자 대비를 유지하는 불투명 뱃지 배경 구성
    static func backgroundColor(for planType: String?) -> Color {
        let (red, green, blue) = components(for: planType)
        return Color(
            red: red * 0.18 + 0.075 * 0.82,
            green: green * 0.18 + 0.085 * 0.82,
            blue: blue * 0.18 + 0.10 * 0.82
        )
    }

    /// 구독 등급별 밝은 강조색의 RGB 성분 선택
    private static func components(for planType: String?) -> (Double, Double, Double) {
        switch planType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "free": return (0.40, 0.88, 0.58)
        case "go": return (0.64, 0.88, 0.42)
        case "plus", "edu", "edu_plus": return (0.88, 0.86, 0.40)
        case "prolite", "self_serve_business_prolite": return (1.00, 0.76, 0.42)
        case "pro", "team", "business", "self_serve_business_usage_based", "edu_pro":
            return (1.00, 0.60, 0.40)
        case "max", "max5x", "max20x", "promax": return (1.00, 0.44, 0.42)
        case "enterprise", "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based":
            return (1.00, 0.40, 0.48)
        default: return (0.72, 0.74, 0.78)
        }
    }
}
