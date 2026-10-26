// 목적: 해당 오류·작업에 한정한 복사용 진단 요약 생성
// 이용처: 오류 대화상자의 오류 정보 복사 버튼
// 사용방법: 오류 문맥 전달 후 make 호출, 일자 전체 로그 포함 금지
import Foundation

/// 오류코드·지원 식별자·버전과 직접 연결된 진단만 내보내는 경계
public enum AppErrorReport {
    /// 사용자 요청에 따른 오류 요약과 제한된 관련 기록 구성
    public static func make(message: String, failure: AppOperationFailure? = nil,
                            logger: DiagnosticLogger = .shared) async -> String {
        let version = AppVersion.current
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines = ["Codex Quota Checker 오류 정보", "앱 버전: \(version) (\(build))",
                     "macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", "", message]
        if let failure {
            lines += ["", "오류코드: \(failure.code.rawValue)", "발생 식별자: \(failure.occurrenceID.uuidString)"]
            if let operation = failure.operationID { lines.append("작업 식별자: \(operation.uuidString)") }
            if let domain = failure.systemDomain, let code = failure.systemCode { lines.append("시스템 원인: \(domain) / \(code)") }
            let records = await logger.relatedRecords(occurrenceID: failure.occurrenceID, operationID: failure.operationID)
            lines += ["", "관련 진단 (동일 오류·작업, 최대 50개):"]
            lines += records.isEmpty ? ["관련 진단 없음"] : records
        } else {
            lines += ["", "관련 진단 없음 (작업 식별자 미제공)"]
        }
        return lines.joined(separator: "\n")
    }
}
