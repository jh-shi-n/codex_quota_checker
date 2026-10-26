// 목적: 앱 실행·기능 오류의 안정적인 사용자 지원 코드 정의
// 이용처: 오류 안내·업데이트 helper 결과·진단 로그의 공통 식별자
// 사용방법: 오류 경계에서 code.message 호출, 시스템 원문 대신 domain·숫자 코드 기록
import Foundation

/// 사용자 문구를 해석하지 않고 오류 종류를 조회하는 공통 계약
public protocol AppErrorCodeProviding {
    var appErrorCode: AppErrorCode { get }
}

/// 기존 코드 재사용·재번호 부여 없이 추가하는 기능별 오류 목록
public enum AppErrorCode: String, CaseIterable, Codable, Sendable {
    case instanceLock = "APP-001"
    case updateReadiness = "APP-002"
    case startupResources = "APP-003"
    case startupMetadata = "APP-004"
    case unexpected = "APP-999"
    case settingsRead = "CFG-001"
    case settingsWrite = "CFG-002"
    case accountPathMissing = "ACC-001"
    case accountPathNotDirectory = "ACC-002"
    case accountPathUnreadable = "ACC-003"
    case accountNotConfigured = "ACC-004"
    case accountAuthentication = "ACC-005"
    case accountLimit = "ACC-006"
    case cliMissing = "CLI-001"
    case cliTimeout = "CLI-002"
    case cliCancelled = "CLI-003"
    case cliExited = "CLI-004"
    case cliResponse = "CLI-005"
    case cliProtocol = "CLI-006"
    case cliTransport = "CLI-007"
    case cliLaunch = "CLI-008"
    case cliWrite = "CLI-009"
    case cliRead = "CLI-010"
    case cliNotRunning = "CLI-011"
    case pingNotConfigured = "PNG-001"
    case pingMissingAuthentication = "PNG-002"
    case pingExecutable = "PNG-003"
    case pingAlreadyRunning = "PNG-004"
    case pingTimeout = "PNG-005"
    case pingConfiguration = "PNG-006"
    case pingLaunch = "PNG-007"
    case pingProcess = "PNG-008"
    case pingExit = "PNG-009"
    case pingModel = "PNG-010"
    case pingAuthentication = "PNG-011"
    case pingRateLimit = "PNG-012"
    case pingCommand = "PNG-013"
    case pingOutput = "PNG-014"
    case pingCancelled = "PNG-015"
    case tokenHome = "TOK-001"
    case tokenSessions = "TOK-002"
    case tokenStorage = "TOK-003"
    case tokenSuperseded = "TOK-004"
    case tokenFileLimit = "TOK-005"
    case tokenRead = "TOK-006"
    case tokenCancelled = "TOK-007"
    case tokenReadLimit = "TOK-008"
    case quotaCacheRead = "DB-001"
    case quotaCacheWrite = "DB-002"
    case tokenCacheRead = "DB-003"
    case tokenCacheWrite = "DB-004"
    case tokenHistory = "DB-005"
    case sessionRead = "SES-001"
    case serviceStatus = "NET-001"
    case loginItem = "LGN-001"
    case notificationDelivery = "NTF-001"
    case diagnosticStorage = "LOG-001"
    case updateRequest = "UPD-002"
    case updateShutdown = "UPD-003"
    case updateLaunch = "UPD-004"
    case updateReady = "UPD-005"
    case updateRestore = "UPD-006"
    case updateToolTimeout = "UPD-007"
    case updateStaging = "UPD-008"
    case updateCandidate = "UPD-009"
    case updateBackup = "UPD-010"
    case updatePromotion = "UPD-011"
    case updateRestoreLaunch = "UPD-012"
    case updateRestoreProcess = "UPD-013"
    case updateAsset = "UPD-101"
    case updateDigest = "UPD-102"
    case updateDownload = "UPD-103"
    case updateArchive = "UPD-104"
    case updateApp = "UPD-105"
    case updateVersion = "UPD-106"
    case updateSignature = "UPD-107"
    case updateOS = "UPD-108"
    case updatePermission = "UPD-109"
    case updateHelper = "UPD-110"
    case updateNetwork = "UPD-111"
    case updateState = "UPD-112"
    case updateHelperStart = "UPD-113"
    case updateCheck = "UPD-114"
    case updateUnexpected = "UPD-199"

    /// 사용자에게 전달하는 고정 코드 포함 안내
    public func message(_ summary: String) -> String {
        let suffix = " (오류코드: \(rawValue))"
        return summary.hasSuffix(suffix) ? summary : summary + suffix
    }

    /// 언어·사용자 안내 문구와 독립적인 Cocoa 오류 숫자
    public var numericCode: Int {
        let offsets = ["APP": 1000, "CFG": 2000, "ACC": 3000, "CLI": 4000,
                       "PNG": 5000, "TOK": 6000, "DB": 7000, "SES": 8000,
                       "NET": 9000, "LGN": 10000, "NTF": 11000, "LOG": 12000, "UPD": 13000]
        let parts = rawValue.split(separator: "-")
        return (offsets[String(parts[0])] ?? 0) + (Int(parts[1]) ?? 0)
    }

    /// 코드별 사용자 조치; 취소·변경 상태를 무조건 재시도하지 않는 정책
    public var recoverySuggestion: String {
        switch self {
        case .startupResources, .startupMetadata:
            "공식 배포 앱의 파일 구성을 확인해 주세요. 앱 번들 내부 파일을 직접 교체하지 마세요."
        case .accountAuthentication, .pingMissingAuthentication, .pingAuthentication:
            "Codex 로그인 상태를 확인한 뒤 다시 시도해 주세요."
        case .accountPathMissing, .accountPathNotDirectory, .accountPathUnreadable, .accountNotConfigured, .tokenHome:
            "설정에서 연결한 계정 폴더와 접근 권한을 확인해 주세요."
        case .cliMissing, .pingExecutable: "Codex CLI 설치와 실행 경로를 확인해 주세요."
        case .cliCancelled, .tokenCancelled, .tokenSuperseded: "필요할 때 작업을 다시 실행해 주세요."
        case .updateRestore, .updateRestoreLaunch, .updateRestoreProcess:
            "앱의 실행 상태를 확인해 주세요. 보존된 구버전이나 백업을 삭제하지 마세요."
        case .updateSignature, .updateDigest, .updateApp, .updateArchive:
            "검증을 우회하지 말고 공식 릴리스 파일로 다시 시도해 주세요."
        case .updateOS: "지원 macOS 버전을 확인해 주세요."
        case .updatePermission: "앱이 있는 폴더의 쓰기 권한을 확인해 주세요."
        case .loginItem: "macOS 로그인 항목의 승인 상태를 확인해 주세요."
        default: "다시 시도해 주세요. 반복되면 오류코드와 발생 식별자를 함께 전달해 주세요."
        }
    }

    /// 구버전 helper의 숫자 종료 코드와 신규 안정 코드의 일치 변환
    static func updateExit(_ status: Int) -> Self {
        Self(rawValue: String(format: "UPD-%03d", status)) ?? .updateUnexpected
    }
}

/// 원문 경로·인증정보를 포함하지 않는 앱 오류와 시스템 숫자 코드
public struct AppOperationFailure: Error, LocalizedError, CustomNSError, Equatable, Sendable {
    public let code: AppErrorCode
    public let summary: String
    public let systemCode: Int?
    public let systemDomain: String?
    public let occurrenceID: UUID
    public let operationID: UUID?
    public static let errorDomain = "com.shinjh.CodexQuotaChecker.ErrorDomain"

    /// 고정 안내·오류코드 및 선택적인 시스템 숫자 보관
    public init(_ code: AppErrorCode, _ summary: String, underlying: Error? = nil, occurrenceID: UUID = UUID(),
                operationID: UUID? = DiagnosticLogContext.operationID) {
        self.code = code
        self.summary = summary
        self.systemCode = underlying.map { ($0 as NSError).code }
        let knownDomains = [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, NSURLErrorDomain, Self.errorDomain]
        self.systemDomain = underlying.map { knownDomains.contains(($0 as NSError).domain) ? ($0 as NSError).domain : "OtherErrorDomain" }
        self.occurrenceID = occurrenceID
        self.operationID = operationID
    }

    public var errorDescription: String? {
        code.message(summary)
    }

    /// 사용자 안내·조치·지원 식별자를 분리한 표시용 본문
    public var userMessage: String {
        "\(code.message(summary))\n\(code.recoverySuggestion)\n발생 식별자: \(occurrenceID.uuidString)"
    }

    public var failureReason: String? { summary }
    public var recoverySuggestion: String? { code.recoverySuggestion }
    public var errorCode: Int { code.numericCode }
    public var errorUserInfo: [String: Any] {
        var info: [String: Any] = [NSLocalizedDescriptionKey: code.message(summary),
                                 NSLocalizedFailureReasonErrorKey: summary,
                                 NSLocalizedRecoverySuggestionErrorKey: code.recoverySuggestion,
                                 "appErrorCode": code.rawValue, "occurrenceID": occurrenceID.uuidString]
        if let systemCode, let systemDomain {
            info[NSUnderlyingErrorKey] = NSError(domain: systemDomain, code: systemCode)
        }
        return info
    }

    /// 사용자 문구·인증 원문 없이 코드·발생 식별자·시스템 원인만 기록
    public func record() {
        var fields: [DiagnosticField: DiagnosticValue] = [
            .appErrorCode: .identifier(code.rawValue), .requestID: .identifier(occurrenceID.uuidString),
        ]
        if let systemCode { fields[.errorCode] = .integer(systemCode) }
        if let systemDomain { fields[.errorDomain] = .identifier(systemDomain) }
        (DiagnosticLogContext.logger ?? .shared).record(.appFailure, level: .error, operationID: operationID, fields: fields)
    }

    /// 업데이트 준비 오류를 공통 코드와 안전한 안내로 변환
    public static func update(_ error: Error) -> Self {
        if let failure = error as? Self { return failure }
        if let error = error as? AppUpdateInstallError {
            return Self(error.appErrorCode, error.errorDescription ?? "설치를 준비하지 못했습니다.")
        }
        let code: AppErrorCode = (error as NSError).domain == NSURLErrorDomain ? .updateNetwork : .updateUnexpected
        return Self(code, "업데이트를 준비하지 못했습니다. 다시 시도해 주세요.", underlying: error)
    }
}

extension CodexQuotaServiceError: AppErrorCodeProviding {
    /// 할당량 조회·리셋권 요청 오류의 공통 코드
    public var appErrorCode: AppErrorCode {
        switch self {
        case .notConfigured: .accountNotConfigured
        case .loginRequired: .accountAuthentication
        case .codexNotFound: .cliMissing
        case .timeout: .cliTimeout
        case .cancelled: .cliCancelled
        case .processCrashed: .cliExited
        case .malformedResponse: .cliResponse
        case .protocolError: .cliProtocol
        case .transport: .cliTransport
        }
    }
}

extension CodexProcessError: AppErrorCodeProviding {
    /// CLI 하위 프로세스의 실행·입출력·수명 오류 구분
    public var appErrorCode: AppErrorCode {
        switch self {
        case .notRunning: .cliNotRunning
        case .launchFailed: .cliLaunch
        case .writeFailed: .cliWrite
        case .readFailed: .cliRead
        case .processExited: .cliExited
        case .timeout: .cliTimeout
        case .cancelled: .cliCancelled
        }
    }
}

extension UsageWindowProbeFailureCategory: AppErrorCodeProviding {
    /// 민감한 CLI 원문을 사용하지 않는 Ping 실패 코드
    public var appErrorCode: AppErrorCode {
        switch self {
        case .notConfigured: .pingNotConfigured
        case .missingAuthentication: .pingMissingAuthentication
        case .executableUnavailable: .pingExecutable
        case .alreadyRunning: .pingAlreadyRunning
        case .timeout: .pingTimeout
        case .configurationFailure: .pingConfiguration
        case .launchFailure: .pingLaunch
        case .processFailure: .pingProcess
        case .nonZeroExit: .pingExit
        case .unsupportedModel: .pingModel
        case .authenticationFailure: .pingAuthentication
        case .rateLimited: .pingRateLimit
        case .commandFailure: .pingCommand
        case .malformedOutput: .pingOutput
        }
    }
}

extension TokenUsageSnapshotError: AppErrorCodeProviding {
    /// 토큰 집계·저장 제한과 취소의 코드 구분
    public var appErrorCode: AppErrorCode {
        switch self {
        case .invalidHome: .tokenHome
        case .sessionsDirectoryUnavailable: .tokenSessions
        case .storageUnavailable: .tokenStorage
        case .superseded: .tokenSuperseded
        case .fileLimitExceeded: .tokenFileLimit
        case .rolloutReadFailed: .tokenRead
        case .cancelled: .tokenCancelled
        case .readLimitExceeded: .tokenReadLimit
        }
    }
}

extension AppUpdateInstallError: AppErrorCodeProviding {
    /// 배포 검증 오류의 문자열 코드 변환
    public var appErrorCode: AppErrorCode {
        switch self {
        case .missingAsset: .updateAsset
        case .invalidDigest: .updateDigest
        case .invalidDownload: .updateDownload
        case .invalidArchive: .updateArchive
        case .invalidApp: .updateApp
        case .invalidVersion: .updateVersion
        case .invalidSignature: .updateSignature
        case .incompatibleOS: .updateOS
        case .notWritable: .updatePermission
        case .helperMissing: .updateHelper
        }
    }
}

extension UsageWindowProbeProcessError: AppErrorCodeProviding {
    /// Ping 실행기 오류를 동일 기능의 사용자 지원 코드로 연결
    public var appErrorCode: AppErrorCode {
        switch self {
        case .timeout: .pingTimeout
        case .configurationFailure: .pingConfiguration
        case .launchFailure: .pingLaunch
        case .processFailure: .pingProcess
        case .cancelled: .pingCancelled
        }
    }
}

extension CodexLineDecoderError: AppErrorCodeProviding {
    /// CLI 수신 상한 초과의 응답 해석 오류 분류
    public var appErrorCode: AppErrorCode { .cliResponse }
}

extension LaunchAtLoginError: AppErrorCodeProviding {
    /// macOS 로그인 항목 변경 실패 코드
    public var appErrorCode: AppErrorCode { .loginItem }
}
