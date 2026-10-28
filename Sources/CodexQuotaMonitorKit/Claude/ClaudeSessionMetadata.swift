// 목적: 공식 statusline 모델·추론 등급의 세션별 수집
// 이용처: Claude 활성 세션 카드의 사용 모델 표시
// 사용방법: capture 과정에서 write 호출, 세션 조회에서 read 호출
// 실행 예시: ClaudeSessionMetadata.read(home: folder, sessionID: id)
import Foundation

/// 대화 기록 없이 공식 CLI가 전달한 모델 정보만 보관
public struct ClaudeSessionMetadata: Codable, Equatable, Sendable {
    public let identity: String
    public let model: String
    public let effort: String?
    public let observedAt: Date

    /// UUID 세션만 파일명으로 허용하는 모델 스냅샷 경로
    private static func file(home: URL, sessionID: String) -> URL? {
        guard UUID(uuidString: sessionID) != nil else { return nil }
        return ClaudeQuotaSnapshot.directory(home: home).appendingPathComponent("model-" + sessionID + ".json")
    }

    /// 공식 model.id와 effort.level의 허용 문자열만 원자적으로 저장
    static func write(payload: [String: Any], identity: String, sessionID: String, home: URL, now: Date) throws {
        guard let raw = (payload["model"] as? [String: Any])?["id"] as? String,
              SessionActivityMetadataSanitizer.modelIdentifier(raw) != nil,
              let file = file(home: home, sessionID: sessionID) else { return }
        let effort = SessionActivityMetadataSanitizer.reasoningEffort((payload["effort"] as? [String: Any])?["level"] as? String)
        let value = Self(identity: identity, model: raw, effort: effort, observedAt: now)
        try JSONEncoder().encode(value).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// 미래 시각·계정 바인딩 불일치·잘못된 모델 식별자 제외
    public static func read(home: URL, sessionID: String, now: Date = Date()) -> Self? {
        guard let file = file(home: home, sessionID: sessionID),
              let data = try? Data(contentsOf: file), data.count <= 4096,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.observedAt <= now.addingTimeInterval(30),
              SessionActivityMetadataSanitizer.modelIdentifier(value.model) != nil,
              let binding = try? Data(contentsOf: ClaudeQuotaSnapshot.directory(home: home).appendingPathComponent("session-" + sessionID + ".json")),
              let identity = try? JSONDecoder().decode(String.self, from: binding), identity == value.identity else { return nil }
        return value
    }
}
