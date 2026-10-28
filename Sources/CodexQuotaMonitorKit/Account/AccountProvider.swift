// 목적: 연결 폴더의 CLI 제공자 판별
// 이용처: 계정 연결·조회·활성 세션 분기
// 사용방법: AccountConfig.provider 또는 detect(home:) 호출
// 실행 예시: AccountProvider.detect(home: selectedFolder)
import Foundation

/// 기존 Codex 계정과 Claude 설정 폴더의 제공자 구분
public enum AccountProvider: String, Codable, Equatable, Sendable {
    case codex
    case claude

    public var displayName: String { self == .claude ? "Claude" : "Codex" }

    /// 인증 파일을 읽지 않는 이름·메타데이터 판별, 기존 Codex 폴더 우선 보존
    public static func detect(home: URL, fileManager: FileManager = .default) -> Self {
        if fileManager.fileExists(atPath: home.appendingPathComponent("auth.json").path) { return .codex }
        let name = home.lastPathComponent.lowercased()
        if name == ".claude" || name.hasPrefix(".claude-") { return .claude }
        if fileManager.fileExists(atPath: home.appendingPathComponent(".credentials.json").path) { return .claude }
        let settings = fileManager.fileExists(atPath: home.appendingPathComponent("settings.json").path)
        let projects = fileManager.fileExists(atPath: home.appendingPathComponent("projects").path)
        if settings && projects { return .claude }
        return .codex
    }
}
