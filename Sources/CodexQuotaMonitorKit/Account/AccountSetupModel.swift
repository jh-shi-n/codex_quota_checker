// 목적: 최초 계정 폴더의 검증·연결 확인·등록 가능 상태 관리
// 이용처: 경로 미등록 상태의 초기 연결 가이드
// 사용방법: 경로 입력 후 checkConnection 호출, 성공 시 registrationPath로 등록값 취득
import Combine
import Foundation

public typealias AccountSetupChecker = @Sendable (AccountConfig) async -> AccountState

/// 실제 경로 저장과 분리된 단일 계정 연결 초안
@MainActor
public final class AccountSetupModel: ObservableObject {
    /// 입력 전·확인 중·성공·실패의 화면 상태
    public enum Phase: Equatable, Sendable {
        case idle, checking, connected, failed
    }

    @Published public var path: String = "" {
        didSet {
            if path != oldValue {
                discoveryMessage = nil
                cancelCheck()
            }
        }
    }
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var message: String?
    @Published public private(set) var registrationError: String?
    @Published public private(set) var connectedAccount: AccountState?
    @Published public private(set) var discoveryMessage: String?
    @Published public private(set) var isRegistering = false
    public let isRecovery: Bool

    public var canCheck: Bool { !validator.normalizedPath(path).isEmpty && phase != .checking && !isRegistering }
    public var canFinish: Bool { phase == .connected && verifiedPath == validator.normalizedPath(path) && !isRegistering }
    private let validator: AccountPathValidator
    private let checker: AccountSetupChecker
    private var verifiedPath: String?
    private var revision = 0
    private var operation: Task<AccountState, Never>?
    private var didAttemptDiscovery = false

    /// 경로 검증 정책과 실제 또는 테스트용 한도 조회 연결
    public init(
        validator: AccountPathValidator = .live,
        isRecovery: Bool = false,
        checker: @escaping AccountSetupChecker = { await CodexQuotaService().state(for: $0) }
    ) {
        self.validator = validator
        self.isRecovery = isRecovery
        self.checker = checker
    }

    /// 최초 표시에서만 기본 폴더 확인 및 사용자 입력·취소 이후 재탐색 방지
    public func discoverDefaultAccount() async {
        guard !didAttemptDiscovery, revision == 0, path.isEmpty, phase == .idle else { return }
        didAttemptDiscovery = true
        let candidate = validator.homeDirectory.appendingPathComponent(".codex").path
        guard validator.validate(candidate) == .valid else {
            discoveryMessage = "기본 계정을 찾지 못했습니다. Codex에서 경로를 확인하거나 폴더를 선택해 주세요."
            return
        }
        path = candidate
        discoveryMessage = "기본 폴더를 확인합니다. 다른 계정을 사용하려면 경로를 변경해 주세요."
        let expectedRevision = revision + 1
        await checkConnection()
        guard revision == expectedRevision, path == candidate, !Task.isCancelled else { return }
        if phase == .connected {
            discoveryMessage = "기본 계정을 찾았습니다. 연결할 계정을 확인한 뒤 ‘이 계정 연결’을 눌러 주세요."
        } else if phase == .failed {
            discoveryMessage = "기본 폴더의 계정을 확인하지 못했습니다. 로그인 상태를 확인하거나 다른 경로를 입력해 주세요."
        }
    }

    /// 기본 폴더 탐색·사용자 요청의 연결 조회 및 변경·취소된 경로의 늦은 성공 제외
    public func checkConnection() async {
        guard !isRegistering else { return }
        cancelCheck()
        let normalized = validator.normalizedPath(path)
        let validation = validator.validate(normalized)
        guard validation == .valid else {
            phase = .failed
            message = validation.userMessage ?? "계정 폴더를 선택해 주세요."
            return
        }
        let current = revision
        phase = .checking
        let config = AccountConfig(id: "C1", home: URL(fileURLWithPath: normalized), position: .left)
        let checker = self.checker
        let task = Task { await checker(config) }
        operation = task
        let account = await task.value
        guard revision == current, normalized == validator.normalizedPath(path), !Task.isCancelled else { return }
        operation = nil
        guard account.status == .normal else {
            phase = .failed
            message = account.errorMessage ?? Self.failureMessage(for: account.status)
            return
        }
        verifiedPath = normalized
        connectedAccount = account
        message = account.email.map { "\($0) 계정의 연결을 확인했습니다." } ?? "계정 연결을 확인했습니다."
        phase = .connected
    }

    /// 등록 직전 폴더 존재 여부 재확인; 저장은 앱 호스트에서만 수행
    public func registrationPath() -> String? {
        guard canFinish, let verifiedPath else { return nil }
        let validation = validator.validate(verifiedPath)
        guard validation == .valid else {
            cancelCheck()
            phase = .failed
            message = validation.userMessage ?? "계정 폴더를 다시 선택해 주세요."
            return nil
        }
        return verifiedPath
    }

    /// 저장·화면 반영 완료 전 중복 등록 및 연결 확인 차단
    public func beginRegistration() -> String? {
        guard let path = registrationPath() else { return nil }
        isRegistering = true
        return path
    }

    /// 저장 실패 안내와 검증된 경로·재시도 가능 초안 유지
    public func reportRegistrationFailure(_ message: String) {
        isRegistering = false
        self.registrationError = message
    }

    /// 입력 변경·창 닫기 시 실행 취소와 성공 상태 폐기
    public func cancelCheck() {
        revision += 1
        operation?.cancel()
        operation = nil
        verifiedPath = nil
        connectedAccount = nil
        message = nil
        registrationError = nil
        isRegistering = false
        phase = .idle
    }

    /// 인증·설치·네트워크 실패의 사용자 안내 변환
    private static func failureMessage(for status: AccountStatus) -> String {
        switch status {
        case .loginRequired: return AppErrorCode.accountAuthentication.message("선택한 폴더의 Codex 계정에 로그인한 뒤 다시 확인해 주세요.")
        case .codexNotFound: return AppErrorCode.cliMissing.message("Codex CLI를 찾지 못했습니다. 설치한 뒤 다시 확인해 주세요.")
        case .timeout: return AppErrorCode.cliTimeout.message("연결 확인 시간이 초과되었습니다. 네트워크 상태를 확인하고 다시 시도해 주세요.")
        default: return AppErrorCode.cliTransport.message("할당량을 확인하지 못했습니다. 계정 폴더와 로그인 상태를 확인해 주세요.")
        }
    }
}
