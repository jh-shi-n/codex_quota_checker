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
    static var helperURL: URL? { helperResourceURL() }

    /// 설치 앱의 helper 고정 및 개발 빌드 리소스와의 버전 혼용 차단
    static func helperResourceURL(installedResources: URL? = Bundle.main.resourceURL,
                                  isApplication: Bool = Bundle.main.bundleURL.pathExtension == "app") -> URL? {
        if let resources = installedResources,
           let bundle = Bundle(url: resources.appendingPathComponent("CodexQuotaMonitor_CodexQuotaMonitorKit.bundle")),
           let helper = bundle.url(forResource: "app-update", withExtension: "sh") {
            return helper
        }
        guard !isApplication else { return nil }
        return Bundle.module.url(forResource: "app-update", withExtension: "sh")
    }

    /// GitHub 배포 파일 다운로드 후 메인 실행 흐름 밖에서 검증·압축 해제
    public static func prepare(_ release: AppRelease, installedVersion: String) async throws -> PreparedAppUpdate {
        guard let asset = release.asset, asset.size > 0, asset.size <= 200_000_000,
              GitHubAppReleaseClient.isRepositoryURL(asset.url, prefix: "/releases/download/") else { throw AppUpdateInstallError.missingAsset }
        guard validDigest(asset.digest) else { throw AppUpdateInstallError.invalidDigest }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodexQuotaChecker-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let archive = directory.appendingPathComponent("update.zip")
            try await download(asset.url, to: archive, maximumBytes: min(Int64(BoundedZipExtractor.maximumArchiveBytes), asset.size), expectedSize: asset.size)
            let signatureURL = URL(string: asset.url.absoluteString + ".sig")!
            let signatureFile = directory.appendingPathComponent("update.zip.sig")
            try await download(signatureURL, to: signatureFile, maximumBytes: 64, expectedSize: 64)
            let task = Task.detached {
                try validateDownload(archive, asset: asset)
                try verifyReleaseSignature(archive, signature: Data(contentsOf: signatureFile))
                return try unpack(archive, directory: directory, version: release.version, installedVersion: installedVersion)
            }
            return try await withTaskCancellationHandler {
                let result = try await task.value
                try Task.checkCancellation()
                return result
            } onCancel: { task.cancel() }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// 파일 크기와 GitHub 제공 SHA-256의 정확한 일치 검증
    public static func validateDownload(_ archive: URL, asset: AppReleaseAsset) throws {
        guard validDigest(asset.digest), let digest = asset.digest else { throw AppUpdateInstallError.invalidDigest }
        let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size <= BoundedZipExtractor.maximumArchiveBytes, Int64(size) == asset.size else { throw AppUpdateInstallError.invalidDownload }
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard "sha256:\(actual)" == digest.lowercased() else { throw AppUpdateInstallError.invalidDownload }
    }

    /// 압축 경로와 번들 구조·식별자·버전·서명 검증
    public static func unpack(_ archive: URL, directory: URL, version: String, installedVersion: String) throws -> PreparedAppUpdate {
        let extracted = directory.appendingPathComponent("extracted")
        try BoundedZipExtractor.extract(archive, to: extracted)
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
    public static func launch(_ prepared: PreparedAppUpdate, target: URL = Bundle.main.bundleURL) async throws {
        guard let resource = helperURL else { throw AppUpdateInstallError.helperMissing }
        try await launchPrepared(prepared, target: target, helper: resource, stateDirectory: AppUpdateState.directory)
    }

    /// helper 준비 완료 확인 이전 종료 방지 및 격리된 설치 경로 검증 경계
    static func launchPrepared(_ prepared: PreparedAppUpdate, target: URL, helper resource: URL, stateDirectory: URL) async throws {
        try Task.checkCancellation()
        let target = target.resolvingSymlinksInPath().standardizedFileURL
        guard target.lastPathComponent == appName, target.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else { throw AppUpdateInstallError.notWritable }
        let helper = prepared.directory.appendingPathComponent("app-update.sh")
        do { try FileManager.default.copyItem(at: resource, to: helper) }
        catch { throw AppOperationFailure(.updateHelperStart, "업데이트 설치 도구를 준비하지 못했습니다.", underlying: error) }
        let state: (nonce: String, log: URL)
        do { state = try AppUpdateState.begin(version: prepared.version, target: target, directory: stateDirectory) }
        catch { throw AppOperationFailure(.updateState, "업데이트 상태를 기록하지 못했습니다.", underlying: error) }
        let process = Process()
        var acknowledged = false
        defer {
            if !acknowledged {
                if process.isRunning { process.terminate() }
                AppUpdateState.cancelPending(nonce: state.nonce, directory: stateDirectory)
            }
        }
        let output: FileHandle
        do { output = try FileHandle(forWritingTo: state.log) }
        catch { throw AppOperationFailure(.updateState, "업데이트 로그를 열지 못했습니다.", underlying: error) }
        defer { try? output.close() }
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", helper.path, String(ProcessInfo.processInfo.processIdentifier), target.path,
                             prepared.app.path, prepared.directory.path, prepared.version, stateDirectory.path, state.nonce]
        process.standardOutput = output
        process.standardError = output
        do { try process.run() }
        catch { throw AppOperationFailure(.updateHelperStart, "업데이트 설치 도구를 실행하지 못했습니다.", underlying: error) }
        let acknowledgment = stateDirectory.appendingPathComponent("helper-\(state.nonce).ready")
        for _ in 0..<100 {
            try Task.checkCancellation()
            if (try? String(contentsOf: acknowledgment, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) == state.nonce {
                try Task.checkCancellation()
                acknowledged = true
                return
            }
            guard process.isRunning else { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AppOperationFailure(.updateHelperStart, "업데이트 설치 도구가 준비되지 않아 현재 앱을 유지합니다.")
    }

    /// SHA-256 표기 및 길이 검증
    private static func validDigest(_ digest: String?) -> Bool {
        guard let digest, digest.lowercased().hasPrefix("sha256:") else { return false }
        let hex = digest.dropFirst(7)
        return hex.count == 64 && hex.allSatisfy { $0.isASCII && $0.hexDigitValue != nil }
    }

    /// 고정 Ed25519 공개키로 ZIP SHA-256 raw32 메시지의 detached signature 검증
    static func verifyReleaseSignature(_ archive: URL, signature: Data, publicKey: Data? = nil) throws {
        let pinned = Data(base64Encoded: "eVqIIERnbh3hDEscyndQjUFkjhQqgtoHa6d/r6iF/1s=")!
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey ?? pinned)
        guard signature.count == 64 else { throw AppUpdateInstallError.invalidSignature }
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        var hash = SHA256()
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        guard key.isValidSignature(signature, for: Data(hash.finalize())) else { throw AppUpdateInstallError.invalidSignature }
    }

    /// 응답 선언값과 독립적인 실제 수신 바이트 상한·취소·총시간 제한
    static func download(_ url: URL, to destination: URL, maximumBytes: Int64, expectedSize: Int64, session injectedSession: URLSession? = nil) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 120
        configuration.timeoutIntervalForRequest = 30
        let session = injectedSession ?? URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength < 0 || response.expectedContentLength == expectedSize else { throw AppUpdateInstallError.invalidDownload }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw AppUpdateInstallError.invalidDownload
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var count: Int64 = 0
        var chunk = Data()
        chunk.reserveCapacity(65_536)
        let deadline = Date().addingTimeInterval(120)
        for try await byte in bytes {
            guard count < maximumBytes, Date() < deadline else { throw AppUpdateInstallError.invalidDownload }
            count += 1
            chunk.append(byte)
            if chunk.count == 65_536 {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        guard count == expectedSize else { throw AppUpdateInstallError.invalidDownload }
        if !chunk.isEmpty { try output.write(contentsOf: chunk) }
    }

    /// 서명 확인 도구의 제한시간·출력 상한·취소 전파
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 15) throws -> String {
        try Task.checkCancellation()
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let group = ProcessGroupTermination.group(of: process)
        try? output.fileHandleForWriting.close()
        defer {
            ProcessGroupTermination.terminate(process, group: group, until: Date().addingTimeInterval(0.5))
            try? output.fileHandleForReading.close()
        }
        var result = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            try Task.checkCancellation()
            guard Date() < deadline else { throw AppUpdateInstallError.invalidArchive }
            ProcessGroupTermination.drain(output.fileHandleForReading, limit: 1_048_576 - result.count) { result.append($0) }
            guard result.count < 1_048_576 else { throw AppUpdateInstallError.invalidArchive }
            Thread.sleep(forTimeInterval: 0.01)
        }
        ProcessGroupTermination.drain(output.fileHandleForReading, limit: 1_048_576 - result.count) { result.append($0) }
        guard process.terminationStatus == 0 else { throw AppUpdateInstallError.invalidArchive }
        return String(decoding: result, as: UTF8.self)
    }
}
