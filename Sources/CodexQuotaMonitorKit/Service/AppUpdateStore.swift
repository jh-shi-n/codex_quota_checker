// 목적: 최신 릴리스 확인 상태·일일 캐시·중복 요청 관리
// 이용처: 설정의 앱 업데이트 확인과 앱 시작 자동 확인
// 사용방법: 시작 시 check(force: false), 수동 확인 시 check 호출
import Combine
import Foundation
import AppKit

public typealias AppReleaseFetch = @Sendable () async throws -> AppRelease

/// 계정 조회와 분리한 앱 업데이트 확인 상태
@MainActor
public final class AppUpdateStore: ObservableObject {
    @Published public private(set) var latest: AppRelease?
    @Published public private(set) var lastCheckedAt: Date?
    @Published public private(set) var isChecking = false
    @Published public private(set) var checkFailed = false
    @Published public private(set) var isInstalling = false
    @Published public private(set) var installationError: String?
    public let currentVersion: String
    private let defaults: UserDefaults
    private let fetch: AppReleaseFetch
    private let now: () -> Date
    private var task: Task<Void, Never>?
    private var operationID: UUID?
    private var installationTask: Task<Void, Never>?
    private var installationID: UUID?
    private var failureObservation: Task<Void, Never>?
    private var pendingFailureAlert: String?
    private let presentFailure: @MainActor (String, AppOperationFailure?) -> Void
    private var failureContext: AppOperationFailure?
    private static let cacheKey = "CodexQuotaMonitor.appUpdateCache"

    /// 설치 버전과 저장된 공개 릴리스 캐시 복원
    public init(currentVersion: String = AppVersion.current, defaults: UserDefaults = .standard,
                fetch: @escaping AppReleaseFetch = GitHubAppReleaseClient.fetch,
                now: @escaping () -> Date = { Date() },
                presentFailure: @escaping @MainActor (String, AppOperationFailure?) -> Void = {
                    AppErrorPresenter.present(title: "업데이트 실패했습니다", message: $0, failure: $1)
                }) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.fetch = fetch
        self.now = now
        self.presentFailure = presentFailure
        if defaults === UserDefaults.standard, let notice = AppUpdateState.takeFailure() {
            notice.failure.record()
            installationError = notice.message
            failureContext = notice.failure
            if notice.shouldAlert { pendingFailureAlert = notice.message }
        }
        if let data = defaults.data(forKey: Self.cacheKey),
           let cache = try? JSONDecoder().decode(Cache.self, from: data),
           ReleaseVersion(cache.release.version) != nil,
           GitHubAppReleaseClient.isRepositoryURL(cache.release.pageURL, prefix: "/releases/tag/") {
            latest = cache.release
            lastCheckedAt = cache.checkedAt
        }
    }

    public var updateAvailable: Bool {
        guard let latest, let installed = ReleaseVersion(currentVersion), let released = ReleaseVersion(latest.version) else { return false }
        return released > installed
    }

    public var statusText: String {
        if isChecking { return "업데이트 확인 중" }
        if checkFailed { return AppErrorCode.updateCheck.message("업데이트 확인 실패 · 다시 시도해주세요") }
        guard latest != nil else { return "업데이트 확인 전" }
        return updateAvailable ? "새 버전을 사용할 수 있습니다" : "사용 가능한 새 버전이 없습니다"
    }

    /// 수동 확인은 즉시 실행, 자동 확인은 마지막 성공 이후 24시간 간격 적용
    @discardableResult
    public func check(force: Bool = true) -> Task<Void, Never>? {
        if let task { return task }
        if !force, let lastCheckedAt, latest != nil {
            let elapsed = now().timeIntervalSince(lastCheckedAt)
            if elapsed >= 0 && elapsed < 86_400 { return nil }
        }
        let id = UUID()
        operationID = id
        isChecking = true
        checkFailed = false
        let task = Task { [weak self, fetch] in
            do {
                let release = try await fetch()
                guard !Task.isCancelled, let self, self.operationID == id else { return }
                guard ReleaseVersion(release.version) != nil else { throw URLError(.cannotParseResponse) }
                let checkedAt = self.now()
                self.latest = release
                self.lastCheckedAt = checkedAt
                if let data = try? JSONEncoder().encode(Cache(release: release, checkedAt: checkedAt)) {
                    self.defaults.set(data, forKey: Self.cacheKey)
                }
            } catch {
                guard !Task.isCancelled, let self, self.operationID == id else { return }
                self.checkFailed = true
            }
            guard let self, self.operationID == id else { return }
            self.isChecking = false
            self.task = nil
        }
        self.task = task
        return task
    }

    /// 종료 시 공개 API 요청 취소 및 뒤늦은 응답 반영 방지
    public func cancel() {
        failureObservation?.cancel()
        failureObservation = nil
        operationID = nil
        task?.cancel()
        task = nil
        isChecking = false
        installationID = nil
        installationTask?.cancel()
        installationTask = nil
        isInstalling = false
    }

    /// 사용자 선택 시 검증된 배포 파일 준비·교체 도구 실행 후 현재 앱 종료
    public func install() {
        guard updateAvailable, let latest, !isInstalling, !isChecking else { return }
        let id = UUID()
        installationID = id
        isInstalling = true
        installationError = nil
        installationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await AppUpdateInstaller.prepare(latest, installedVersion: self.currentVersion)
                guard !Task.isCancelled, self.installationID == id else {
                    try? FileManager.default.removeItem(at: prepared.directory)
                    return
                }
                do { try await AppUpdateInstaller.launch(prepared) }
                catch {
                    try? FileManager.default.removeItem(at: prepared.directory)
                    throw error
                }
                guard !Task.isCancelled, self.installationID == id else { return }
                NSApplication.shared.terminate(nil)
            } catch {
                guard !Task.isCancelled, self.installationID == id else { return }
                let failure = AppOperationFailure.update(error)
                failure.record()
                let message = "업데이트 실패했습니다.\n" + failure.userMessage
                self.installationError = message
                self.failureContext = failure
                self.isInstalling = false
                self.installationTask = nil
                self.presentFailure(message, failure)
            }
        }
    }

    /// 이전 helper 결과 알림과 복원 앱 시작 이후 확정되는 최종 결과 관찰
    public func observeInstallationFailure() {
        AppUpdateState.registerFailureObserver()
        if let message = pendingFailureAlert {
            pendingFailureAlert = nil
            presentFailure(message, failureContext)
        }
        guard failureObservation == nil else { return }
        failureObservation = Task { [weak self] in
            for _ in 0..<240 {
                guard !Task.isCancelled else { return }
                if let notice = AppUpdateState.takeFailure() {
                    notice.failure.record()
                    self?.installationError = notice.message
                    self?.failureContext = notice.failure
                    if notice.shouldAlert { self?.presentFailure(notice.message, notice.failure) }
                }
                let pending = AppUpdateState.directory.appendingPathComponent("pending.json")
                let result = AppUpdateState.directory.appendingPathComponent("result.json")
                if !FileManager.default.fileExists(atPath: pending.path),
                   !FileManager.default.fileExists(atPath: result.path) { break }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            self?.failureObservation = nil
        }
    }

    /// 인증·계정 정보 없는 마지막 성공 결과 저장
    private struct Cache: Codable {
        let release: AppRelease
        let checkedAt: Date
    }
}
