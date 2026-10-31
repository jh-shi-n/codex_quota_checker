// 목적: 설정 탭과 화면 전용 슬롯·제공자 표기 제공
// 이용처: 설정 창과 계정 순서 편집기
// 사용방법: 탭 라벨 또는 슬롯 ID·저장 경로로 표시값 조회
// 실행 예시: SettingsAccountLabel.slot("C1")
import AppKit
import SwiftUI

/// 표시 순서와 번들 아이콘을 공유하는 설정 탭
public enum SettingsTab: String, CaseIterable, Sendable {
    case general, accounts, display, notifications

    /// 상단 탭의 한글 제목 제공
    public var title: String {
        switch self {
        case .general: "일반"
        case .accounts: "계정"
        case .display: "표시"
        case .notifications: "알림"
        }
    }

    /// 병렬 제작 리소스와 일치하는 확장자 제외 파일명 제공
    var resourceName: String { "settings-tab-\(rawValue)" }

    /// 설치 번들 우선 선택 및 누락 리소스의 아이콘 생략, 패키지 번들의 지연 조회
    @MainActor static func loadIcon(
        named name: String,
        resourcesURL: URL? = Bundle.main.resourceURL,
        fallbackBundle: () -> Bundle = { Bundle.module }
    ) -> NSImage? {
        let installedBundle = resourcesURL?
            .appendingPathComponent("CodexQuotaMonitor_CodexQuotaMonitorKit.bundle")
        let bundle = installedBundle.flatMap { Bundle(url: $0) } ?? fallbackBundle()
        guard let url = bundle.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 24, height: 24)
        return image
    }

    /// 탭별 아이콘의 반복 디코딩 방지
    @MainActor private static let icons = Dictionary(uniqueKeysWithValues: allCases.compactMap { tab in
        loadIcon(named: tab.resourceName).map { (tab, $0) }
    })

    /// 기본 macOS 탭에서 사용할 제목과 선택적 아이콘 구성
    @MainActor @ViewBuilder var label: some View {
        if let icon = Self.icons[self] {
            Label { Text(title) } icon: { Image(nsImage: icon) }
        } else {
            Text(title)
        }
    }
}

/// 저장 ID와 앱 공용 기본 이름을 변경하지 않는 설정 전용 표기
public enum SettingsAccountLabel {
    /// 알려진 네 슬롯만 한글 표기로 변환
    public static func slot(_ id: String) -> String {
        switch id {
        case "C1": "슬롯1"
        case "C2": "슬롯2"
        case "C3": "슬롯3"
        case "C4": "슬롯4"
        default: id
        }
    }

    /// 저장된 연결 경로의 기존 제공자 판별 결과 표시
    public static func providerBadge(path: String) -> String {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return "비어 있음" }
        return AccountProvider.detect(home: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)).displayName
    }
}
