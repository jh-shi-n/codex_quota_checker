// 목적: 공유 Codex 홈의 로컬 데이터 귀속 계정 판별
// 이용처: 토큰 집계·세션 활동의 추가 소스 선택
// 사용방법: 매 조회마다 homes(for:accounts:) 호출
// 실행 예시: SharedCodexHomeResolver().homes(for: slot, accounts: slots)
import CryptoKit
import Foundation

/// 네트워크·토큰 노출 없이 두 가지 식별자의 유일한 일치만 허용하는 경계
public struct SharedCodexHomeResolver: Sendable {
    public let sharedHome: URL

    /// 기존 경로 정규화 도우미를 통한 기본 홈 또는 테스트 홈 설정
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        sharedHome = URL(fileURLWithPath: AccountConfig.normalizedPath("~/.codex", homeDirectory: homeDirectory))
    }

    /// 공유 홈의 직접 등록·중복 계정·불완전 인증을 제외한 추가 소스 반환
    public func homes(for account: AccountConfig, accounts: [AccountConfig]) -> [URL] {
        guard let home = account.configuredHome else { return [] }
        let own = [home]
        guard account.provider == .codex, identity(home: home) != nil,
              !accounts.contains(where: { $0.configuredHome?.resolvingSymlinksInPath() == sharedHome.resolvingSymlinksInPath() }),
              let shared = identity(home: sharedHome) else { return own }
        let matches = accounts.filter {
            $0.isConfigured && $0.provider == .codex && identity(home: $0.home).map { shared.matches($0) } == true
        }
        return matches.count == 1 && matches[0] == account ? own + [sharedHome] : own
    }

    /// 캐시의 인증·소스 변경 격리용 비가역 키 생성
    public func signature(for account: AccountConfig, accounts: [AccountConfig]) -> String {
        let sources = homes(for: account, accounts: accounts)
        let values = sources.map { home in
            [home.resolvingSymlinksInPath().path, identity(home: home)?.key ?? "missing"].joined(separator: "|")
        }.joined(separator: "\n")
        return SHA256.hash(data: Data(values.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 공유 소스 변경과 분리된 기본 홈 계정 식별자 생성
    func accountIdentity(for account: AccountConfig) -> String? {
        guard account.provider == .codex, let identity = identity(home: account.home) else { return nil }
        return SHA256.hash(data: Data(identity.key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 제한된 인증 파일에서 계정·이메일·안정 사용자 식별자만 추출
    private func identity(home: URL) -> Identity? {
        let file = home.appendingPathComponent("auth.json")
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_537), data.count <= 65_536,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let account = nonempty(tokens["account_id"]), let jwt = tokens["id_token"] as? String else { return nil }
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let decoded = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any] else { return nil }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let email = nonempty(claims["email"])?.lowercased()
        let user = nonempty(auth["chatgpt_user_id"]) ?? nonempty(auth["user_id"]) ?? nonempty(claims["sub"])
        guard email != nil || user != nil else { return nil }
        return Identity(account: account, email: email, user: user)
    }

    /// 빈 인증 식별자의 일치 방지
    private func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 토큰 원문을 보관하지 않는 인증 식별자
    private struct Identity {
        let account: String
        let email: String?
        let user: String?
        var key: String { [account, email ?? "", user ?? ""].joined(separator: "|") }

        /// 공통 사용자 식별자의 충돌 시 이메일 일치만으로 우회 금지
        func matches(_ other: Identity) -> Bool {
            guard account == other.account else { return false }
            if let email, let otherEmail = other.email, email != otherEmail { return false }
            if let user, let otherUser = other.user { return user == otherUser }
            return email != nil && email == other.email
        }
    }
}

/// 홈 간 세션 ID·실제 파일 식별자의 중복 읽기 방지
struct LocalSessionDeduplicator {
    private var files = Set<String>()
    private var sessions = Set<String>()

    /// 심볼릭 링크·하드 링크의 동일 파일 여부 확인
    mutating func insert(file: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.resolvingSymlinksInPath().path),
              let device = attributes[.systemNumber], let inode = attributes[.systemFileNumber] else {
            return files.insert(file.resolvingSymlinksInPath().path).inserted
        }
        return files.insert("\(device):\(inode)").inserted
    }

    /// 복사된 로그의 동일 세션 ID 여부 확인
    mutating func insert(sessionID: String?) -> Bool {
        guard let sessionID else { return true }
        return sessions.insert(sessionID).inserted
    }
}
