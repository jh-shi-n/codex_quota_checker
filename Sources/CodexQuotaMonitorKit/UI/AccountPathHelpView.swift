// 목적: Codex CLI 경로 확인용 영어 요청 복사와 앱 내 경로 입력 안내
// 이용처: 최초 연결·재연결 가이드와 추가 계정 설정
// 사용방법: 경로 입력 영역에 AccountPathHelpView 배치
import AppKit
import SwiftUI

/// 설정 수정 없이 현재 CLI 계정 폴더만 확인하는 공통 요청
public enum AccountPathHelp {
    public static let prompt = """
    Find the absolute path of the account storage directory used by this CLI session (Codex or Claude Code), not the current working directory.

    Check CODEX_HOME in this session's environment. If it is set, resolve it to an absolute path. Otherwise, check ~/.codex.

    For Claude Code, check CLAUDE_CONFIG_DIR instead. If it is unset, check ~/.claude. Do not return the project working directory.

    Verify that the directory exists. Return the confirmed absolute path on a separate line so I can paste it into Codex Quota Checker. If you cannot determine the path, explain why instead of guessing.

    Do not display authentication file contents, tokens, or API keys. Do not modify any files or application settings.
    """

    /// 영어 요청의 클립보드 반영 성공 여부 반환
    @MainActor
    public static func copyPrompt(to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(prompt, forType: .string)
    }
}

/// 경로를 모르는 사용자의 CLI 확인·붙여 넣기·연결 확인 안내
public struct AccountPathHelpView: View {
    @State private var copyMessage: String?

    /// 가이드·설정 공용 경로 안내 초기화
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("계정 경로를 모르시나요?")
                .font(.callout.weight(.medium))
            Text("아래 요청을 복사해 사용 중인 Codex 또는 Claude CLI에 붙여 넣으세요. 응답받은 경로를 위 입력란에 붙여 넣은 뒤 연결해 주세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("CLI에 물어볼 요청 복사") {
                    copyMessage = AccountPathHelp.copyPrompt()
                        ? "영어 요청을 복사했습니다."
                        : "복사하지 못했습니다. 다시 시도해 주세요."
                }
                .accessibilityIdentifier("copy-codex-account-path-prompt")
                if let copyMessage {
                    Text(copyMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
