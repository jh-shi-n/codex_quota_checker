// 목적: Claude 공식 statusline 할당량의 계정별 안전한 스냅샷 보관
// 이용처: statusline 수집기와 앱의 제공자별 조회
// 사용방법: capture(input:home:cli:) 또는 state(for:)
// 실행 예시: await ClaudeQuotaService().state(for: account)
import Foundation
import CoreFoundation
import Darwin

/// 구간별 관측 시각·초기화 시각·사용률
public struct ClaudeQuotaWindow: Codable, Equatable, Sendable {
    public let usedPercentage: Double
    public let resetsAt: Date
    public let observedAt: Date
}

/// 대화·인증정보를 제외한 폴더별 계정 할당량
public struct ClaudeQuotaSnapshot: Codable, Equatable, Sendable {
    public let identity: String
    public var windows: [String: ClaudeQuotaWindow]

    /// 수집 파일을 선택 폴더 내부의 앱 전용 위치로 제한
    public static func directory(home: URL) -> URL { home.appendingPathComponent(".codex-quota-checker", isDirectory: true) }
    /// 폴더별 할당량 스냅샷 위치 반환
    public static func file(home: URL) -> URL { directory(home: home).appendingPathComponent("quota.json") }

    /// 파일 크기 제한 후 스냅샷 읽기
    public static func read(home: URL) throws -> Self? {
        let file = file(home: home)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        guard (size?.intValue ?? 0) <= 65_536 else { throw ClaudeQuotaError.invalidData }
        guard let snapshot = try? JSONDecoder().decode(Self.self, from: Data(contentsOf: file)) else { throw ClaudeQuotaError.invalidData }
        return snapshot
    }

    /// 독립 구간 누락 시 기존 미만료 값 보존, 잘못된 숫자·문맥 사용률 제외
    public static func merging(input: Data, identity: String, previous: Self?, now: Date = Date()) throws -> Self? {
        guard input.count <= 1_048_576,
              let payload = try JSONSerialization.jsonObject(with: input) as? [String: Any] else { throw ClaudeQuotaError.invalidData }
        guard let rates = payload["rate_limits"] as? [String: Any] else { return nil }
        var snapshot = Self(identity: identity, windows: previous?.identity == identity ? previous!.windows : [:])
        snapshot.windows = snapshot.windows.filter { $0.value.resetsAt > now }
        var received = false
        for key in ["five_hour", "seven_day"] {
            guard let value = rates[key] as? [String: Any] else { continue }
            guard let percent = value["used_percentage"] as? NSNumber,
                  CFGetTypeID(percent) != CFBooleanGetTypeID(),
                  let reset = value["resets_at"] as? NSNumber,
                  CFGetTypeID(reset) != CFBooleanGetTypeID(),
                  percent.doubleValue.isFinite, (0...100).contains(percent.doubleValue),
                  reset.doubleValue.isFinite, reset.doubleValue > now.timeIntervalSince1970,
                  reset.doubleValue < now.addingTimeInterval(8 * 86400).timeIntervalSince1970 else { continue }
            if let existing = snapshot.windows[key], existing.observedAt > now { continue }
            snapshot.windows[key] = ClaudeQuotaWindow(usedPercentage: percent.doubleValue,
                resetsAt: Date(timeIntervalSince1970: reset.doubleValue), observedAt: now)
            received = true
        }
        return received ? snapshot : nil
    }

    /// 파이프의 부분 읽기와 최대 크기를 처리하는 표준입력 수신
    public static func readInput(_ handle: FileHandle) throws -> Data {
        var data = Data()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= 1_048_576 else { throw ClaudeQuotaError.invalidData }
        }
        return data
    }

    /// 인증을 확인한 수집값만 0600·원자적 교체로 저장, 빈 초기 응답은 쓰기 생략
    public static func capture(input: Data, home: URL, cli: ClaudeCLI = ClaudeCLI(), now: Date = Date()) throws {
        guard input.count <= 1_048_576, let payload = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              let rates = payload["rate_limits"] as? [String: Any], !rates.isEmpty else { return }
        let directory = directory(home: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = Darwin.open(directory.appendingPathComponent("capture.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw ClaudeQuotaError.invalidData }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { flock(lock, LOCK_UN) }
        let authentication = try cli.authentication(home: home)
        guard authentication.supportsQuota else { throw ClaudeQuotaError.unsupportedAccount }
        guard let sessionID = payload["session_id"] as? String, UUID(uuidString: sessionID) != nil else { throw ClaudeQuotaError.invalidData }
        let binding = directory.appendingPathComponent("session-" + sessionID + ".json")
        if FileManager.default.fileExists(atPath: binding.path) {
            guard let bound = try? JSONDecoder().decode(String.self, from: Data(contentsOf: binding)), bound == authentication.identity else { return }
        } else {
            try JSONEncoder().encode(authentication.identity).write(to: binding, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: binding.path)
        }
        let previous = try? read(home: home)
        guard let snapshot = try merging(input: input, identity: authentication.identity, previous: previous, now: now) else { return }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: file(home: home), options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(home: home).path)
    }
}

/// 인증 조회와 스냅샷 읽기만 수행하는 Claude 전용 서비스
public struct ClaudeQuotaService: Sendable {
    public let cli: ClaudeCLI

    /// CLI 실행 경계의 주입
    public init(cli: ClaudeCLI = ClaudeCLI()) { self.cli = cli }

    /// 메인 스레드 밖에서 인증·스냅샷 확인, 추론 요청 없음
    public func state(for config: AccountConfig) async -> AccountState {
        await Task.detached { stateSync(for: config) }.value
    }

    /// 현재 계정 지문과 일치하는 미만료 구간만 기존 화면 상태로 변환
    public func stateSync(for config: AccountConfig, now: Date = Date()) -> AccountState {
        guard config.isConfigured else { return .notConfigured(id: config.id) }
        var state = AccountState(id: config.id, status: .normal, provider: .claude)
        do {
            let authentication = try cli.authentication(home: config.home)
            state.email = authentication.email
            state.planType = authentication.subscriptionType
            guard authentication.supportsQuota else { throw ClaudeQuotaError.unsupportedAccount }
            guard let snapshot = try ClaudeQuotaSnapshot.read(home: config.home), snapshot.identity == authentication.identity else {
                state.errorMessage = "로그인을 확인했습니다. ‘Claude 수집 연결’ 후 Claude CLI에서 대화하면 사용량이 갱신됩니다."
                return state
            }
            let windows = snapshot.windows.filter {
                $0.value.resetsAt > now && $0.value.observedAt <= now.addingTimeInterval(30)
                && $0.value.usedPercentage.isFinite && (0...100).contains($0.value.usedPercentage)
            }
            let primary = windows["five_hour"]
            let secondary = windows["seven_day"]
            state.primaryUsedPercent = primary?.usedPercentage
            state.primaryResetAt = primary?.resetsAt
            state.secondaryUsedPercent = secondary?.usedPercentage
            state.secondaryResetAt = secondary?.resetsAt
            state.lastUpdated = windows.values.map(\.observedAt).min()
            if windows.isEmpty {
                state.errorMessage = "초기화 이후 새 사용량을 기다리는 중입니다. Claude CLI에서 대화한 뒤 다시 확인해 주세요."
            } else if windows.values.contains(where: { now.timeIntervalSince($0.observedAt) > 900 }) {
                state.errorMessage = "마지막으로 수신한 사용량입니다. Claude CLI 사용 시 갱신되며 웹·앱 사용이 아직 반영되지 않았을 수 있습니다."
            } else {
                state.errorMessage = "Claude CLI에서 수신한 계정 전체 사용량입니다. 새로고침은 마지막 수신값을 다시 읽습니다."
            }
            state.primaryResetObservation = primary == nil ? .checking : .stableObserved
            state.secondaryResetObservation = secondary == nil ? .checking : .stableObserved
        } catch {
            switch error as? ClaudeQuotaError {
            case .loginRequired: state.status = .loginRequired
            case .cliMissing: state.status = .codexNotFound
            case .timeout: state.status = .timeout
            default: state.status = .error
            }
            state.errorMessage = (error as? ClaudeQuotaError)?.errorDescription ?? "Claude CLI의 연결 상태를 확인하지 못했습니다."
        }
        return state
    }
}
