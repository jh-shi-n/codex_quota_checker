// 목적: 저장된 설정 변경과 기존 설정 창의 화면 갱신 연결
// 이용처: AppKit·SwiftUI 공용 설정 호스트
// 사용방법: 관찰할 저장소와 동일 식별성을 유지할 콘텐츠 생성자 전달
// 실행 예시: SettingsPreferencesHost(preferences: store) { _ in settings }
import SwiftUI

/// 클로저 바인딩의 외부 변경을 설정 본문까지 전달하는 관찰 호스트
@MainActor
public struct SettingsPreferencesHost<Content: View>: View {
    @ObservedObject private var preferences: PreferencesStore
    private let content: (PreferencesStore) -> Content

    /// 실제 저장소의 변경을 구독하는 콘텐츠 구성
    public init(preferences: PreferencesStore, @ViewBuilder content: @escaping (PreferencesStore) -> Content) {
        self.preferences = preferences
        self.content = content
    }

    /// 초안 상태의 식별성을 유지하며 최신 설정으로 본문 재평가
    public var body: some View { content(preferences) }
}
