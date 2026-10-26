// 목적: 릴리스 ZIP 무결성·앱 검증 및 종료 후 교체 보조 프로세스 실행
// 이용처: 사용자가 선택한 앱 업데이트 설치
// 사용방법: prepare 후 launch 호출, 성공한 보조 프로세스 실행 이후 앱 종료
import CryptoKit
import Foundation

/// 설치 준비 중 사용자에게 전달할 제한된 오류
public enum AppUpdateInstallError: Error, LocalizedError {
    case missingAsset, invalidDigest, invalidDownload, invalidArchive, invalidApp, invalidVersion, invalidSignature, incompatibleOS, notWritable, helperMissing
    public var errorDescription: String? {
        switch self {
        case .missingAsset: "이 Mac에 맞는 배포 파일이 없습니다."
        case .invalidDigest: "배포 파일 검증 정보가 없습니다. 릴리스 페이지를 확인해주세요."
        case .invalidDownload: "배포 파일 다운로드 또는 무결성 검증에 실패했습니다."
        case .invalidArchive: "배포 파일의 압축 구조가 올바르지 않습니다."
        case .invalidApp: "설치할 앱의 식별 정보가 올바르지 않습니다."
        case .invalidVersion: "설치할 앱의 버전이 올바르지 않습니다."
        case .invalidSignature: "설치할 앱의 서명 검증에 실패했습니다."
        case .incompatibleOS: "새 버전은 더 최신 macOS가 필요합니다."
        case .notWritable: "현재 앱 위치에 쓸 수 없습니다. 릴리스 페이지에서 직접 설치해주세요."
        case .helperMissing: "업데이트 설치 도구를 찾을 수 없습니다."
        }
    }
}

/// 검증 완료된 임시 앱과 해당 작업 전용 경로
public struct PreparedAppUpdate: Sendable {
    public let directory: URL
    public let app: URL
    public let version: String
}

/// 인증 정보와 사용자 데이터에 접근하지 않는 앱 번들 전용 업데이트
public enum AppUpdateInstaller {
    public static let bundleIdentifier = "com.example.codexquotamonitor"
    public static let appName = "CodexQuotaChecker.app"
    static var helperURL: URL? { Bundle.module.url(forResource: "app-update", withExtension: "sh") }

    /// GitHub 배포 파일 다운로드 후 메인 실행 흐름 밖에서 검증·압축 해제
    public static func prepare(_ release: AppRelease, installedVersion: String) async throws -> PreparedAppUpdate {
        guard let asset = release.asset, asset.size > 0, asset.size <= 200_000_000,
              GitHubAppReleaseClient.isRepositoryURL(asset.url, prefix: "/releases/download/") else { throw AppUpdateInstallError.missingAsset }
        guard validDigest(asset.digest) else { throw AppUpdateInstallError.invalidDigest }
        let request = URLRequest(url: asset.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        let (download, response) = try await URLSession.shared.download(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw AppUpdateInstallError.invalidDownload }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodexQuotaChecker-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let archive = directory.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: download, to: archive)
            return try await Task.detached {
                try validateDownload(archive, asset: asset)
                return try unpack(archive, directory: directory, version: release.version, installedVersion: installedVersion)
            }.value
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// 파일 크기와 GitHub 제공 SHA-256의 정확한 일치 검증
    public static func validateDownload(_ archive: URL, asset: AppReleaseAsset) throws {
        guard validDigest(asset.digest), let digest = asset.digest else { throw AppUpdateInstallError.invalidDigest }
        let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size.map(Int64.init) == asset.size else { throw AppUpdateInstallError.invalidDownload }
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard "sha256:\(actual)" == digest.lowercased() else { throw AppUpdateInstallError.invalidDownload }
    }

    /// 압축 경로와 번들 구조·식별자·버전·서명 검증
    public static func unpack(_ archive: URL, directory: URL, version: String, installedVersion: String) throws -> PreparedAppUpdate {
        let list = try run("/usr/bin/zipinfo", ["-1", archive.path])
        guard !list.isEmpty, list.split(separator: "\n").allSatisfy({ entry in
            let parts = entry.split(separator: "/", omittingEmptySubsequences: true)
            return !entry.hasPrefix("/") && !entry.contains("\\") && !parts.contains("..")
                && (parts.first == Substring(appName) || parts.first == "__MACOSX")
        }) else { throw AppUpdateInstallError.invalidArchive }
        let extracted = directory.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
        _ = try run("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path])
        let app = extracted.appendingPathComponent(appName)
        try validateApp(app, expectedVersion: version, installedVersion: installedVersion)
        return PreparedAppUpdate(directory: directory, app: app, version: version)
    }

    /// 배포 버전 상승과 번들 외부를 가리키는 심볼릭 링크 차단
    public static func validateApp(_ app: URL, expectedVersion: String, installedVersion: String) throws {
        let root = app.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard try app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              let enumerator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { throw AppUpdateInstallError.invalidApp }
        for case let file as URL in enumerator {
            guard file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { throw AppUpdateInstallError.invalidApp }
        }
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleIdentifier,
              info["CFBundleExecutable"] as? String == "CodexQuotaMonitor",
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/CodexQuotaMonitor").path) else { throw AppUpdateInstallError.invalidApp }
        guard let candidate = (info["CFBundleShortVersionString"] as? String).flatMap(ReleaseVersion.init),
              let expected = ReleaseVersion(expectedVersion), let installed = ReleaseVersion(installedVersion),
              candidate == expected, candidate > installed else { throw AppUpdateInstallError.invalidVersion }
        if let minimum = info["LSMinimumSystemVersion"] as? String {
            let parts = minimum.split(separator: ".", omittingEmptySubsequences: false)
            let numbers = parts.compactMap { Int($0) }
            guard (2...3).contains(numbers.count), numbers.count == parts.count, numbers.allSatisfy({ $0 >= 0 }) else { throw AppUpdateInstallError.invalidApp }
            guard ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: numbers[0], minorVersion: numbers[1],
                patchVersion: numbers.count == 3 ? numbers[2] : 0)) else { throw AppUpdateInstallError.incompatibleOS }
        }
        do { _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) }
        catch { throw AppUpdateInstallError.invalidSignature }
    }

    /// 설치 경로 검증 후 앱 종료를 기다리는 별도 도구 실행
    public static func launch(_ prepared: PreparedAppUpdate, target: URL = Bundle.main.bundleURL) throws {
        guard target.lastPathComponent == appName, target.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else { throw AppUpdateInstallError.notWritable }
        guard let resource = helperURL else { throw AppUpdateInstallError.helperMissing }
        let helper = prepared.directory.appendingPathComponent("app-update.sh")
        try FileManager.default.copyItem(at: resource, to: helper)
        let log = prepared.directory.appendingPathComponent("install.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", helper.path, String(ProcessInfo.processInfo.processIdentifier), target.path,
                             prepared.app.path, prepared.directory.path, prepared.version]
        process.standardOutput = output
        process.standardError = output
        try process.run()
    }

    /// SHA-256 표기 및 길이 검증
    private static func validDigest(_ digest: String?) -> Bool {
        guard let digest, digest.lowercased().hasPrefix("sha256:") else { return false }
        let hex = digest.dropFirst(7)
        return hex.count == 64 && hex.allSatisfy { $0.isASCII && $0.hexDigitValue != nil }
    }

    /// 제한된 시스템 도구 실행과 실패의 구조화된 전달
    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AppUpdateInstallError.invalidArchive }
        return String(decoding: data, as: UTF8.self)
    }
}
