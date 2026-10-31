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

    /// 이미지 선택기에 표시할 탭 아이콘 제공
    @MainActor var icon: NSImage? { Self.icons[self] }
}

/// 아이콘과 제목을 함께 표시하는 키보드 접근 가능 설정 탭 선택기
@MainActor struct SettingsTabSelector: NSViewRepresentable {
    @Binding var selection: SettingsTab

    /// SwiftUI 선택 바인딩을 보유할 조정자 생성
    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    /// 네이티브 이미지와 선택 상태를 가진 탭 버튼 구성
    func makeNSView(context: Context) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.spacing = 8

        for tab in SettingsTab.allCases {
            let button = NSButton(title: tab.title, target: context.coordinator, action: #selector(Coordinator.selectTab(_:)))
            button.identifier = NSUserInterfaceItemIdentifier("settings-tab-\(tab.rawValue)")
            button.setButtonType(.radio)
            button.image = tab.icon
            button.imagePosition = .imageAbove
            button.imageScaling = .scaleProportionallyDown
            button.state = selection == tab ? .on : .off
            button.contentTintColor = selection == tab ? .controlAccentColor : .secondaryLabelColor
            button.setAccessibilityIdentifier("settings-tab-\(tab.rawValue)")
            button.setAccessibilityLabel(tab.title)
            button.setAccessibilityTitle(tab.title)
            button.setAccessibilityRole(.radioButton)
            button.setAccessibilityValue(NSNumber(value: selection == tab ? 1 : 0))
            stack.addArrangedSubview(button)
        }
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.radioGroup)
        stack.setAccessibilityLabel("설정 탭")
        stack.setAccessibilityChildren(stack.arrangedSubviews)
        return stack
    }

    /// SwiftUI 선택 변경을 네이티브 버튼에 반영
    func updateNSView(_ stack: NSStackView, context: Context) {
        context.coordinator.selection = $selection
        for button in stack.arrangedSubviews.compactMap({ $0 as? NSButton }) {
            guard let identifier = button.identifier?.rawValue,
                  identifier.hasPrefix("settings-tab-"),
                  let tab = SettingsTab(rawValue: String(identifier.dropFirst("settings-tab-".count))) else { continue }
            button.state = selection == tab ? .on : .off
            button.contentTintColor = selection == tab ? .controlAccentColor : .secondaryLabelColor
            button.setAccessibilityValue(NSNumber(value: selection == tab ? 1 : 0))
        }
    }

    /// 네이티브 버튼 선택과 SwiftUI 바인딩 연결
    @MainActor final class Coordinator: NSObject {
        var selection: Binding<SettingsTab>

        /// 현재 선택 바인딩 저장
        init(selection: Binding<SettingsTab>) {
            self.selection = selection
        }

        /// 선택된 탭을 바인딩에 반영하는 네이티브 버튼 동작
        @objc func selectTab(_ sender: NSButton) {
            guard let identifier = sender.identifier?.rawValue,
                  identifier.hasPrefix("settings-tab-"),
                  let tab = SettingsTab(rawValue: String(identifier.dropFirst("settings-tab-".count))) else { return }
            selection.wrappedValue = tab
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
