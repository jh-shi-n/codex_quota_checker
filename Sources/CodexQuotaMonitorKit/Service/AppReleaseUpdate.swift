// 목적: 공개 GitHub 릴리스와 설치 버전 비교
// 이용처: 앱 업데이트 확인·배포 파일 선택
// 사용방법: GitHubAppReleaseClient.fetch 후 ReleaseVersion 숫자 비교
import Foundation

/// 앱 번들과 소스 실행의 일관된 버전 표시
public enum AppVersion {
    public static let fallback = "0.3.4"
    public static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? fallback
    }
}

/// 안정 릴리스의 숫자 버전 비교와 선행 v 정규화
public struct ReleaseVersion: Comparable, Equatable, Sendable {
    public let text: String
    private let parts: [Int]

    /// 누락·음수·사전 릴리스·비정상 숫자 제외
    public init?(_ value: String) {
        let normalized = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3, components.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
        let numbers = components.compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        text = normalized
        parts = numbers
    }

    /// 문자열 순서와 독립적인 major·minor·patch 비교
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }

    /// 태그 표기 차이를 제외한 숫자 버전 동등성 비교
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.parts == rhs.parts }
}

/// 소스 ZIP과 구분되는 macOS 앱 배포 파일
public struct AppReleaseAsset: Codable, Equatable, Sendable {
    public let name: String
    public let url: URL
    public let size: Int64
    public let digest: String?
}

/// 공개 릴리스의 버전·안내 페이지·플랫폼별 앱 자산
public struct AppRelease: Codable, Equatable, Sendable {
    public let version: String
    public let pageURL: URL
    public let asset: AppReleaseAsset?
}

/// 인증·할당량·모델 실행과 무관한 공개 릴리스 전용 조회
public enum GitHubAppReleaseClient {
    public static let repository = "jh-shi-n/codex_quota_checker"
    public static let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    public static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    /// 시간 제한 10초의 최신 공개 안정 릴리스 조회
    public static func fetch() async throws -> AppRelease {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexQuotaChecker/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count <= 2_000_000 else {
            throw URLError(.badServerResponse)
        }
        return try decode(data)
    }

    /// 안정 태그 검증 및 실행 아키텍처에 맞는 앱 ZIP 선택
    public static func decode(_ data: Data, architecture: String = GitHubAppReleaseClient.architecture) throws -> AppRelease {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard !payload.draft, !payload.prerelease, let version = ReleaseVersion(payload.tag_name),
              let page = URL(string: payload.html_url), isRepositoryURL(page, prefix: "/releases/tag/") else {
            throw URLError(.cannotParseResponse)
        }
        let expected = "CodexQuotaChecker-\(version.text)-macos-\(architecture).zip"
        let candidate = payload.assets.first { $0.name == expected && $0.size > 0 }
        let asset: AppReleaseAsset?
        if let candidate, let url = URL(string: candidate.browser_download_url), isRepositoryURL(url, prefix: "/releases/download/") {
            asset = AppReleaseAsset(name: candidate.name, url: url, size: candidate.size, digest: candidate.digest)
        } else { asset = nil }
        return AppRelease(version: version.text, pageURL: page, asset: asset)
    }

    /// 배포 안내·다운로드 경로의 저장소 범위 제한
    public static func isRepositoryURL(_ url: URL, prefix: String) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.path.hasPrefix("/\(repository)\(prefix)")
            && url.user == nil && url.password == nil
    }

    /// GitHub 공개 릴리스 응답의 필요한 필드만 복원
    private struct Payload: Decodable {
        let tag_name: String
        let html_url: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    /// API의 배포 자산 이름·URL·무결성 정보
    private struct Asset: Decodable {
        let name: String
        let browser_download_url: String
        let size: Int64
        let digest: String?
    }
}
