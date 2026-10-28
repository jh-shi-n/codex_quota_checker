// 목적: 제공자 판별·저장 호환성·계정 격리 검증
// 이용처: Claude 연결 기능의 Codex 회귀 검증
// 사용방법: swift test --filter AccountProviderTests
// 실행 예시: swift test --filter AccountProviderTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 폴더 내용과 직렬화의 제공자 경계 검증
final class AccountProviderTests: XCTestCase {
    /// 기본 Claude 이름·커스텀 폴더·Codex 인증 파일 우선순위 검증
    func testFolderDetectionPreservesCodexAndFindsClaude() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        XCTAssertEqual(AccountProvider.detect(home: claude), .claude)
        try Data("{}".utf8).write(to: claude.appendingPathComponent("auth.json"))
        XCTAssertEqual(AccountProvider.detect(home: claude), .codex)
        let custom = root.appendingPathComponent("custom")
        try FileManager.default.createDirectory(at: custom.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: custom.appendingPathComponent("settings.json"))
        XCTAssertEqual(AccountProvider.detect(home: custom), .claude)
        XCTAssertEqual(AccountProvider.detect(home: root.appendingPathComponent(".codex-1")), .codex)
        XCTAssertEqual(AccountConfig.unconfigured(id: "C1", position: .left).provider, .codex)
    }

    /// 신규 Claude 상태 왕복·기존 저장값의 Codex 기본값·제공자 간 식별 분리 검증
    func testStateRoundTripAndLegacyDefault() throws {
        let state = AccountState(id: "C1", email: "a@example.test", status: .normal, provider: .claude)
        let encoded = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(AccountState.self, from: encoded).provider, .claude)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "provider")
        let old = try JSONDecoder().decode(AccountState.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(old.provider, .codex)
        XCTAssertFalse(state.acceptsIdentity(of: old))
    }
}
