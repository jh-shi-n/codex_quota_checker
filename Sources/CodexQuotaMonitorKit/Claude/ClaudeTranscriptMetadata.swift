// 목적: Claude transcript 끝부분의 모델·추론 등급만 제한적으로 추출
// 이용처: statusline 메타데이터가 없는 활성 세션의 모델 표시
// 사용방법: 분리 작업에서 read(home:sessionID:) 호출
// 실행 예시: ClaudeTranscriptMetadata.read(home: folder, sessionID: id)
import Darwin
import Foundation

/// 원문을 보관하지 않는 세션별 모델 fallback
enum ClaudeTranscriptMetadata {
    static let maximumBytes = 256 * 1024
    static let maximumLines = 2048
    static let maximumDirectories = 512

    /// 내용 필드를 디코딩 대상에서 제외한 assistant 메타데이터
    private struct Entry: Decodable {
        let type: String
        let message: Message?
        let effort: String?

        private enum CodingKeys: String, CodingKey { case type, message, effort }

        /// effort의 자료형 오류와 모델 유효성 판정 분리
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            type = try values.decode(String.self, forKey: .type)
            message = try values.decodeIfPresent(Message.self, forKey: .message)
            effort = try? values.decode(String.self, forKey: .effort)
        }

        /// 모델 식별자만 허용하는 메시지 투영
        struct Message: Decodable {
            let model: String?
        }
    }

    /// 심볼릭 링크를 제외한 최대 512개 프로젝트 경로 탐색
    static func read(home: URL, sessionID: String) -> (model: String, effort: String?)? {
        guard UUID(uuidString: sessionID) != nil else { return nil }
        let projects = home.appendingPathComponent("projects")
        guard isDirectory(projects),
              let enumerator = FileManager.default.enumerator(at: projects,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsSubdirectoryDescendants]) else { return nil }
        for case let directory as URL in enumerator.prefix(maximumDirectories) {
            guard isDirectory(directory) else { continue }
            if let value = readTail(directory.appendingPathComponent(sessionID + ".jsonl")) { return value }
        }
        return nil
    }

    /// 프로젝트 루트·하위 디렉터리의 링크 제외
    private static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    /// 일반 파일의 마지막 256 KiB·완성된 2048줄에서 최신 유효 모델 추출
    private static func readTail(_ file: URL) -> (model: String, effort: String?)? {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        do {
            let size = try handle.seekToEnd()
            let offset = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
            try handle.seek(toOffset: offset)
            guard var data = try handle.read(upToCount: maximumBytes),
                  let end = data.lastIndex(of: 10) else { return nil }
            data = Data(data[...end])
            if offset > 0 {
                guard let start = data.firstIndex(of: 10) else { return nil }
                data = Data(data[data.index(after: start)...])
            }
            let decoder = JSONDecoder()
            for line in data.split(separator: 10, omittingEmptySubsequences: false).dropLast().reversed().prefix(maximumLines) {
                guard let entry = try? decoder.decode(Entry.self, from: Data(line)), entry.type == "assistant",
                      let model = entry.message?.model,
                      SessionActivityMetadataSanitizer.modelIdentifier(model) != nil else { continue }
                return (model, SessionActivityMetadataSanitizer.reasoningEffort(entry.effort))
            }
        } catch { return nil }
        return nil
    }
}
