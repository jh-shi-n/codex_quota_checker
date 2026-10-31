// 목적: Claude 모델 fallback의 fixture 기반 동작·읽기 제한 검증
// 이용처: 활성 세션 모델 표시 회귀 방지
// 사용방법: 임시 홈에 레지스트리·모델 필드만 생성하여 검증
// 실행 예시: swift test --filter ClaudeTranscriptMetadataTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 실제 Claude 홈과 대화 내용 없이 메타데이터만 검증
@MainActor
final class ClaudeTranscriptMetadataTests: XCTestCase {
    private let id = "00000000-0000-0000-0000-000000000042"

    /// 레지스트리와 프로젝트 디렉터리 생성 및 종료 시 삭제
    private func withHome(_ body: (URL, URL) async throws -> Void) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent("sessions")
        let project = home.appendingPathComponent("projects/-fixture-project")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["pid": 42, "kind": "interactive", "entrypoint": "cli", "sessionId": id])
            .write(to: sessions.appendingPathComponent("42.json"))
        try await body(home, project.appendingPathComponent(id + ".jsonl"))
    }

    /// 모델 필드만 포함하는 JSONL fixture 생성
    private func assistant(_ model: String = "claude-opus-5-5", effort: String? = "medium") throws -> Data {
        var object: [String: Any] = ["type": "assistant", "message": ["model": model]]
        object["effort"] = effort
        return try JSONSerialization.data(withJSONObject: object) + Data([10])
    }

    /// 실제 프로세스 조회 없이 분리 작업을 통한 활성 세션 조회
    private func session(_ home: URL) async throws -> SessionActivityMainSession {
        let snapshot = await ClaudeSessionActivityProvider(isAlive: { _, _ in true }).snapshot(accountID: "C1", home: home)
        XCTAssertEqual(snapshot.state, .available)
        return try XCTUnwrap(snapshot.sessions.first)
    }

    /// 메타데이터 파일 없는 활성 세션의 모델·effort 추출
    func testModelAndEffort() async throws {
        try await withHome { home, file in
            try assistant().write(to: file)
            let value = try await session(home)
            XCTAssertEqual(value.model, "Claude-Opus-5-5")
            XCTAssertEqual(value.reasoningEffort, "medium")
        }
    }

    /// 모델 전환 후 최신 assistant의 모델·effort 선택
    func testLatestAssistantWins() async throws {
        try await withHome { home, file in
            try (assistant() + assistant("claude-sonnet-4-6", effort: "high")).write(to: file)
            let value = try await session(home)
            XCTAssertEqual(value.model, "Claude-Sonnet-4-6")
            XCTAssertEqual(value.reasoningEffort, "high")
        }
    }

    /// 도구 스키마 유형의 모델·effort 필드 무시
    func testToolSchemaLinesIgnored() async throws {
        try await withHome { home, file in
            var data = try assistant()
            for type in ["api-request", "api-request-start", "attachment"] {
                data += try JSONSerialization.data(withJSONObject: ["type": type, "message": ["model": "claude-sonnet-4-6"],
                    "model": "claude-sonnet-4-6", "effort": "high"])
                data += Data([10])
            }
            try data.write(to: file)
            let value = try await session(home)
            XCTAssertEqual(value.model, "Claude-Opus-5-5")
        }
    }

    /// synthetic·잘못된 식별자·불완전한 마지막 줄 무시
    func testInvalidAndIncompleteLinesIgnored() async throws {
        try await withHome { home, file in
            var data = try assistant() + assistant("<synthetic>") + assistant("invalid/model")
            data += Data("{invalid}\n".utf8)
            data += try assistant("claude-sonnet-4-6").dropLast()
            try data.write(to: file)
            let value = try await session(home)
            XCTAssertEqual(value.model, "Claude-Opus-5-5")
        }
    }

    /// 누락·잘못된 effort에서 이전 등급을 가져오지 않고 모델만 표시
    func testMissingOrInvalidEffort() async throws {
        for effort in [nil, "unsupported"] as [String?] {
            try await withHome { home, file in
                try (assistant() + assistant("claude-sonnet-4-6", effort: effort)).write(to: file)
                let value = try await session(home)
                XCTAssertEqual(value.model, "Claude-Sonnet-4-6")
                XCTAssertNil(value.reasoningEffort)
            }
        }
    }

    /// 문자열이 아닌 effort도 모델 표시를 방해하지 않는지 검증
    func testNonStringEffort() async throws {
        try await withHome { home, file in
            try (JSONSerialization.data(withJSONObject: ["type": "assistant", "message": ["model": "claude-opus-5-5"], "effort": 42])
                + Data([10])).write(to: file)
            let value = try await session(home)
            XCTAssertEqual(value.model, "Claude-Opus-5-5")
            XCTAssertNil(value.reasoningEffort)
        }
    }

    /// 대용량 파일의 앞부분 무시 및 끝부분 모델 추출
    func testOversizedFileReadsOnlyTail() async throws {
        try await withHome { home, file in
            let prefix = try assistant() + Data(repeating: 32, count: ClaudeTranscriptMetadata.maximumBytes + 100) + Data([10])
            try prefix.write(to: file)
            let value = try await session(home)
            XCTAssertNil(value.model)
            try (prefix + assistant("claude-sonnet-4-6")).write(to: file)
            let latest = try await session(home)
            XCTAssertEqual(latest.model, "Claude-Sonnet-4-6")
        }
    }

    /// 줄 수 상한보다 오래된 모델 제외
    func testLineLimit() async throws {
        try await withHome { home, file in
            try (assistant() + Data(repeating: 10, count: ClaudeTranscriptMetadata.maximumLines)).write(to: file)
            let value = try await session(home)
            XCTAssertNil(value.model)
        }
    }

    /// transcript 부재 시 모델 수신 대기 상태 유지
    func testMissingTranscript() async throws {
        try await withHome { home, _ in
            let value = try await session(home)
            XCTAssertNil(value.model)
        }
    }

    /// transcript 파일의 심볼릭 링크 건너뛰기
    func testSymlinkFileSkipped() async throws {
        try await withHome { home, file in
            let target = home.appendingPathComponent("fixture.jsonl")
            try assistant().write(to: target)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            let value = try await session(home)
            XCTAssertNil(value.model)
        }
    }

    /// 프로젝트 하위 폴더와 projects 루트의 심볼릭 링크 건너뛰기
    func testSymlinkDirectoriesSkipped() async throws {
        for root in [false, true] {
            try await withHome { home, file in
                try assistant().write(to: file)
                let source = root ? home.appendingPathComponent("projects") : file.deletingLastPathComponent()
                let target = home.appendingPathComponent("moved")
                try FileManager.default.moveItem(at: source, to: target)
                try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
                let value = try await session(home)
                XCTAssertNil(value.model)
            }
        }
    }

    /// 기존 statusline 메타데이터의 우선 사용 유지
    func testLegacyMetadataStillWins() async throws {
        try await withHome { home, file in
            try assistant().write(to: file)
            let directory = ClaudeQuotaSnapshot.directory(home: home)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode("fixture").write(to: directory.appendingPathComponent("session-" + id + ".json"))
            try ClaudeSessionMetadata.write(payload: ["model": ["id": "claude-sonnet-4-6"], "effort": ["level": "low"]],
                identity: "fixture", sessionID: id, home: home, now: Date())
            let value = try await session(home)
            XCTAssertEqual(value.model, "Claude-Sonnet-4-6")
            XCTAssertEqual(value.reasoningEffort, "low")
        }
    }
}
