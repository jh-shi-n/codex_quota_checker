// 목적: 사용자 제공 SVG의 macOS 메뉴 막대 이미지 제공
// 이용처: 표시 계정이 없는 경우의 메뉴 막대 앱 안내 버튼
// 사용방법: 메뉴 막대 생성 시 menuBarIcon 호출
import AppKit

/// 설치 앱 또는 Swift 패키지 번들의 메뉴용 템플릿 자산 제공
@MainActor
public enum AppBranding {
    /// 실제 그림 영역만 포함한 18pt 템플릿 아이콘 생성 및 시스템 색상 적용
    public static func menuBarIcon() -> NSImage? {
        let installedBundle = Bundle.main.resourceURL?
            .appendingPathComponent("CodexQuotaMonitor_CodexQuotaMonitorKit.bundle")
        let bundle = installedBundle.flatMap { Bundle(url: $0) } ?? Bundle.module
        guard let url = bundle.url(forResource: "menu-bar-template", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "LLM Quota Checker"
        return image
    }
}
