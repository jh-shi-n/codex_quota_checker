// 목적: 공개 릴리스 버전 비교·앱 자산 선택·조회 캐시 검증
// 이용처: 0.1.0의 GitHub Releases 기반 업데이트 확인 회귀 테스트
// 사용방법: swift test --filter AppReleaseUpdateTests
import XCTest
@testable import CodexQuotaMonitorKit

/// 사용자 인증이나 실제 API 없이 수행하는 업데이트 확인 검증
@MainActor
final class AppReleaseUpdateTests: XCTestCase {
    /// 문자열 순서와 다른 숫자 버전 및 선행 v 정규화 검증
    func testReleaseVersionsCompareNumerically() throws {
        XCTAssertGreaterThan(try XCTUnwrap(ReleaseVersion("v0.0.10")), try XCTUnwrap(ReleaseVersion("0.0.9")))
        XCTAssertGreaterThan(try XCTUnwrap(ReleaseVersion("0.1.0")), try XCTUnwrap(ReleaseVersion("0.0.99")))
        XCTAssertEqual(ReleaseVersion("v0.1.0"), ReleaseVersion("0.1.0"))
        for invalid in ["", "0.1", "-1.0.0", "0.1.0-beta", "0..1", "0.1.x"] {
            XCTAssertNil(ReleaseVersion(invalid))
        }
    }

    /// 소스 ZIP을 제외하고 정확한 버전·아키텍처의 앱 ZIP 선택 검증
    func testOnlyMatchingAppArchiveIsSelected() throws {
        let release = try GitHubAppReleaseClient.decode(payload(), architecture: "arm64")
        XCTAssertEqual(release.version, "0.1.0")
        XCTAssertEqual(release.asset?.name, "CodexQuotaChecker-0.1.0-macos-arm64.zip")
        XCTAssertNil(try GitHubAppReleaseClient.decode(payload(), architecture: "x86_64").asset)
    }

    /// 사전·비공개 릴리스와 외부 페이지 URL 차단 검증
    func testInvalidReleaseMetadataIsRejected() throws {
        for changes: [String: Any] in [["draft": true], ["prerelease": true],
                                      ["tag_name": "main"], ["html_url": "https://example.com/release"]] {
            XCTAssertThrowsError(try GitHubAppReleaseClient.decode(payload(changes)))
        }
    }

    /// 성공 결과 재실행 복원·자동 확인 24시간 제한·수동 확인 우회 검증
    func testDailyCachePersistsAndManualCheckBypassesIt() async throws {
        let suite = "CodexQuotaMonitorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let release = try GitHubAppReleaseClient.decode(payload())
        let source = ReleaseSource(release: release)
        let store = AppUpdateStore(currentVersion: "0.0.9", defaults: defaults, fetch: { try await source.read() })
        await store.check(force: false)?.value
        XCTAssertTrue(store.updateAvailable)
        XCTAssertNil(store.check(force: false))
        await store.check()?.value
        let calls = await source.calls
        XCTAssertEqual(calls, 2)
        let restored = AppUpdateStore(currentVersion: "0.1.0", defaults: defaults, fetch: { try await source.read() })
        XCTAssertNotNil(restored.lastCheckedAt)
        XCTAssertFalse(restored.updateAvailable)
        XCTAssertNil(restored.check(force: false))
    }

    /// 통신 실패를 최신 버전으로 오인하지 않고 기존 성공 결과 유지 검증
    func testFailedCheckRetainsPriorReleaseAndShowsFailure() async throws {
        let suite = "CodexQuotaMonitorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let release = try GitHubAppReleaseClient.decode(payload())
        let source = ReleaseSource(release: release)
        let store = AppUpdateStore(currentVersion: "0.0.9", defaults: defaults, fetch: { try await source.read() })
        await store.check()?.value
        await source.fail()
        await store.check()?.value
        XCTAssertTrue(store.checkFailed)
        XCTAssertEqual(store.latest, release)
        XCTAssertTrue(store.statusText.contains("실패"))
    }

    /// GitHub 응답과 같은 공개 메타데이터 fixture 생성
    private func payload(_ changes: [String: Any] = [:]) throws -> Data {
        let root = "https://github.com/jh-shi-n/codex_quota_checker"
        var object: [String: Any] = ["tag_name": "v0.1.0", "draft": false, "prerelease": false,
            "html_url": root + "/releases/tag/v0.1.0", "assets": [
                ["name": "CodexQuotaChecker-0.1.0-source.zip", "size": 12,
                 "browser_download_url": root + "/releases/download/v0.1.0/CodexQuotaChecker-0.1.0-source.zip"],
                ["name": "CodexQuotaChecker-0.1.0-macos-arm64.zip", "size": 34,
                 "browser_download_url": root + "/releases/download/v0.1.0/CodexQuotaChecker-0.1.0-macos-arm64.zip"]]]
        object.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

/// 공개 API 대신 성공·실패 응답과 호출 횟수 제공
private actor ReleaseSource {
    let release: AppRelease
    private(set) var calls = 0
    private var shouldFail = false

    /// 정상 공개 릴리스 fixture 지정
    init(release: AppRelease) { self.release = release }

    /// 이후 확인을 통신 실패로 전환
    func fail() { shouldFail = true }

    /// 호출 횟수 기록 후 지정 응답 반환
    func read() throws -> AppRelease {
        calls += 1
        if shouldFail { throw URLError(.notConnectedToInternet) }
        return release
    }
}
