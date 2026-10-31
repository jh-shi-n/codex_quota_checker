// 목적: 앱 서비스 초기화 이전 설치 메타데이터·필수 리소스 확인
// 이용처: 빌드 폴더가 없는 배포 앱의 실행 진입점
// 사용방법: 설치 앱에서 validate 호출, SwiftPM 개발 실행은 검사 제외
import Foundation

/// 리소스 누락으로 인한 비구조적 충돌 이전 오류코드 반환
public enum AppStartupValidator {
    /// 현재 앱 또는 격리된 앱 번들의 메타데이터와 읽기 가능한 리소스 검사
    public static func validate(bundle: Bundle = .main) throws {
        guard bundle.bundleURL.pathExtension == "app" else { return }
        guard bundle.bundleIdentifier == AppUpdateInstaller.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "CodexQuotaMonitor",
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              ReleaseVersion(version) != nil else {
            throw AppOperationFailure(.startupMetadata, "앱의 식별 정보 또는 버전이 올바르지 않습니다.")
        }
        let resources = bundle.resourceURL?.appendingPathComponent("CodexQuotaMonitor_CodexQuotaMonitorKit.bundle")
        let required = ["app-update.sh", "token-history-schema.sql", "menu-bar-template.svg",
                        "probe-airplane.svg", "service-status-smile.svg", "service-status-sad.svg",
                        "settings-tab-general.svg", "settings-tab-accounts.svg",
                        "settings-tab-display.svg", "settings-tab-notifications.svg"]
        guard let resources, required.allSatisfy({ FileManager.default.isReadableFile(atPath: resources.appendingPathComponent($0).path) }) else {
            throw AppOperationFailure(.startupResources, "앱 실행에 필요한 리소스가 없거나 읽을 수 없습니다.")
        }
    }
}
