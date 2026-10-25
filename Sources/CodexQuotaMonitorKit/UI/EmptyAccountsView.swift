// 목적: 계정 미등록·전체 비활성화 상태의 앱 설명과 설정 진입 제공
// 이용처: 표시 계정이 없을 때의 메뉴 막대 팝오버
// 사용방법: 등록 계정 존재 여부와 설정 열기 콜백 전달
import SwiftUI

/// 계정 삭제와 표시 비활성화의 안내 문구 구분
public struct EmptyAccountsPresentation: Equatable, Sendable {
    public static let appName = "Codex Quota Checker"
    public static let appDescription = "Codex 계정의 남은 할당량과 초기화 시각을 메뉴 막대에서 확인하는 앱입니다."
    public let hasRegisteredAccounts: Bool

    /// 경로 등록 여부를 기준으로 빈 화면 상태 구성
    public init(hasRegisteredAccounts: Bool) {
        self.hasRegisteredAccounts = hasRegisteredAccounts
    }

    public var message: String {
        hasRegisteredAccounts ? "모든 계정이 비활성화되어 있습니다." : "현재 등록된 계정이 없습니다."
    }

    public var detail: String {
        hasRegisteredAccounts ? "설정에서 표시할 계정을 활성화해 주세요." : "계정 연결을 눌러 사용할 계정을 등록해 주세요."
    }
}

/// 메뉴 막대 아이콘에서 앱 용도 확인 후 설정을 여는 안내 화면
public struct EmptyAccountsView: View {
    public static let contentSize = CGSize(width: 340, height: 260)
    public let presentation: EmptyAccountsPresentation
    private let onOpenSettings: () -> Void
    private let onConnectAccount: () -> Void

    /// 현재 등록 상태와 설정 이동 동작 연결
    public init(
        hasRegisteredAccounts: Bool,
        onConnectAccount: (() -> Void)? = nil,
        onOpenSettings: @escaping () -> Void
    ) {
        self.presentation = EmptyAccountsPresentation(hasRegisteredAccounts: hasRegisteredAccounts)
        self.onOpenSettings = onOpenSettings
        self.onConnectAccount = onConnectAccount ?? onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(EmptyAccountsPresentation.appName)
                .font(.headline)
            Text(EmptyAccountsPresentation.appDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(presentation.message)
                .font(.callout.weight(.medium))
            Text(presentation.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("설정 열기", action: onOpenSettings)
                    .buttonStyle(.appAction)
                if !presentation.hasRegisteredAccounts {
                    Button("계정 연결", action: onConnectAccount)
                        .buttonStyle(.appPrimary)
                }
            }
        }
        .padding(20)
        .frame(width: Self.contentSize.width)
    }
}
