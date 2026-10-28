// 목적: 계정 폴더 경로의 직접 선택
// 이용처: 첫 연결 가이드 및 일반 설정의 계정 경로 입력
// 사용방법: 현재 경로를 전달하고 취소가 아닌 경우에만 반환 경로 반영
import AppKit

/// 경로 추측·폴더 생성 없이 숨김 폴더까지 선택 가능한 macOS 패널
@MainActor
public enum AccountFolderPicker {
    /// 폴더 한 개만 선택하고 취소 시 nil 반환
    public static func choose(currentPath: String = "") -> String? {
        let panel = NSOpenPanel()
        panel.title = "CLI 계정 폴더 선택"
        panel.message = "사용하려는 Codex 또는 Claude 계정의 폴더를 선택해 주세요. 숨김 폴더도 표시됩니다."
        panel.prompt = "폴더 선택"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        let validator = AccountPathValidator.live
        if validator.validate(currentPath) == .valid {
            panel.directoryURL = URL(fileURLWithPath: validator.normalizedPath(currentPath))
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.standardizedFileURL.path
    }
}
