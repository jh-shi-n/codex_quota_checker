// 목적: Claude 실행 세션의 제한된 로컬 메타데이터 읽기
// 이용처: 계정 상세·노치 활동 감시의 제공자별 세션 분기
// 사용방법: snapshot(accountID:home:) 호출
// 실행 예시: await ProviderSessionActivityProvider().snapshot(accountID: "C1", home: folder)
import Darwin
import Foundation

/// 제한된 모델 메타데이터와 살아 있는 Claude CLI 프로세스만 투영
public struct ClaudeSessionActivityProvider: SessionActivityProvider {
    private let isAlive: @Sendable (Int32, String?) -> Bool

    /// 프로세스 생존·시작 시각 확인 경계의 주입
    public init(isAlive: @escaping @Sendable (Int32, String?) -> Bool = Self.isClaudeProcess) {
        self.isAlive = isAlive
    }

    /// 메인 스레드 밖에서 최대 256개 레지스트리 확인
    public func snapshot(accountID: String, home: URL) async -> SessionActivitySnapshot {
        await Task.detached { read(accountID: accountID, home: home) }.value
    }

    /// JSON 허용 필드·파일 크기·프로세스 생존·세션 ID 검증
    public func read(accountID: String, home: URL, now: Date = Date()) -> SessionActivitySnapshot {
        let directory = home.appendingPathComponent("sessions")
        guard FileManager.default.fileExists(atPath: directory.path) else { return .empty(accountID: accountID, source: .cli) }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])
                .filter { $0.pathExtension == "json" && Int32($0.deletingPathExtension().lastPathComponent) != nil }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(256)
            var sessions: [SessionActivityMainSession] = []
            var seen = Set<String>()
            for file in files {
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true, (values.fileSize ?? 0) <= 65_536,
                      let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                      object["kind"] as? String == "interactive", object["entrypoint"] as? String == "cli",
                      let pid = object["pid"] as? Int32, pid > 0,
                      String(pid) == file.deletingPathExtension().lastPathComponent,
                      isAlive(pid, object["procStart"] as? String),
                      let id = object["sessionId"] as? String, UUID(uuidString: id) != nil,
                      seen.insert(id).inserted else { continue }
                let status: SessionActivityStatus
                switch object["status"] as? String {
                case "busy": status = .working
                case "idle": status = .waiting
                default: status = .unknown
                }
                let updated = (object["updatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                let validUpdated = updated.flatMap { $0 <= now.addingTimeInterval(30) ? $0 : nil }
                let metadata = ClaudeSessionMetadata.read(home: home, sessionID: id, now: now)
                    .map { (model: $0.model, effort: $0.effort) }
                    ?? ClaudeTranscriptMetadata.read(home: home, sessionID: id)
                sessions.append(SessionActivityMainSession(threadID: id, source: .cli,
                    taskName: SessionActivityMetadataSanitizer.text(object["name"] as? String) ?? "Claude session",
                    status: status, agents: [], isActive: true, lastActivityAt: validUpdated,
                    model: metadata?.model, reasoningEffort: metadata?.effort))
            }
            return SessionActivitySnapshot(accountID: accountID, state: .available,
                sessions: SessionActivityMainSession.ordered(sessions), source: .cli)
        } catch { return .unavailable(accountID: accountID) }
    }

    /// PID 재사용·타 프로그램 혼입을 실행 경로와 시작 시각으로 차단
    public static func isClaudeProcess(_ pid: Int32, _ recordedStart: String?) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        let executable = String(cString: path)
        guard executable.hasSuffix("/claude") || executable.contains("/claude/versions/") else { return false }
        guard let recordedStart else { return false }
        var info = proc_bsdinfo()
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard count == MemoryLayout<proc_bsdinfo>.size else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        guard let start = formatter.date(from: recordedStart) else { return false }
        return abs(start.timeIntervalSince1970 - Double(info.pbi_start_tvsec)) < 1
    }
}

/// Codex 구현을 유지하는 폴더별 활동 제공자 라우팅
public struct ProviderSessionActivityProvider: SessionActivityProvider {
    private let codex = SQLiteSessionActivityProvider()
    private let claude = ClaudeSessionActivityProvider()

    /// 기존 감시기와 상세 화면의 공용 제공자 초기화
    public init() {}

    /// 선택 폴더의 제공자에 맞는 로컬 세션 조회
    public func snapshot(accountID: String, home: URL) async -> SessionActivitySnapshot {
        if AccountProvider.detect(home: home) == .claude {
            return await claude.snapshot(accountID: accountID, home: home)
        }
        return await codex.snapshot(accountID: accountID, home: home)
    }
}
