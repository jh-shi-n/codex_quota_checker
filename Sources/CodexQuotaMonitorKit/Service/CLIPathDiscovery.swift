// 목적: 셸 PATH를 상속받지 못한 GUI 앱의 CLI·Node 설치 경로 탐색
// 이용처: CodexLocator·ClaudeCLI 탐색과 CodexProcess.childPath 보정
// 사용방법: CLIPathDiscovery.locate(name:pathEnvironment:candidatePaths:homeDirectory:loginShellPath:) 호출
// 실행 예시: CLIPathDiscovery.locate(name: "codex", pathEnvironment: path, candidatePaths: [], homeDirectory: home)
import Darwin
import Foundation

enum CLIPathDiscovery {
    private static let startMarker = "__LQC_PATH_START__"
    private static let endMarker = "__LQC_PATH_END__"
    private static let maximumShellOutput = 1_048_576
    private static let resolutionLock = NSLock()
    nonisolated(unsafe) private static var loginShellPathResolved = false

    /// 앱 실행당 1회만 읽는 로그인 셸 PATH
    private static let cachedLoginShellPath: String? = {
        let value = readLoginShellPath(
            shell: defaultShell(),
            environment: ProcessInfo.processInfo.environment,
            timeout: 5
        )
        resolutionLock.withLock { loginShellPathResolved = true }
        return value
    }()

    /// 메인 스레드 비차단 조건의 로그인 셸 PATH 조회, 미완료 시 백그라운드 준비 후 다음 탐색에서 반영
    @Sendable
    static func sharedLoginShellPath() -> String? {
        if Thread.isMainThread, !resolutionLock.withLock({ loginShellPathResolved }) {
            DispatchQueue.global(qos: .utility).async { _ = cachedLoginShellPath }
            return nil
        }
        return cachedLoginShellPath
    }

    /// PATH·고정 경로·버전 관리자·로그인 셸 PATH 순서의 실행 파일 탐색
    static func locate(
        name: String,
        pathEnvironment: String?,
        candidatePaths: [URL],
        homeDirectory: URL,
        loginShellPath: @Sendable () -> String? = CLIPathDiscovery.sharedLoginShellPath
    ) -> URL? {
        let direct = directories(inPath: pathEnvironment).map { $0.appendingPathComponent(name) }
            + candidatePaths
            + managedBinDirectories(homeDirectory: homeDirectory).map { $0.appendingPathComponent(name) }
        if let found = firstExecutable(in: direct) { return found }
        return firstExecutable(in: directories(inPath: loginShellPath()).map { $0.appendingPathComponent(name) })
    }

    /// 사용자 폴더의 Node 버전 관리자·npm 전역 설치 bin 폴더 목록
    static func managedBinDirectories(homeDirectory: URL) -> [URL] {
        nvmBinDirectories(homeDirectory: homeDirectory) + [
            ".local/share/fnm/aliases/default/bin",
            "Library/Application Support/fnm/aliases/default/bin",
            ".volta/bin",
            ".asdf/shims",
            ".npm-global/bin",
        ].map { homeDirectory.appendingPathComponent($0, isDirectory: true) }
    }

    /// 기본 별칭 일치 버전 우선, 이후 최신 버전 순서의 nvm bin 폴더 목록
    private static func nvmBinDirectories(homeDirectory: URL) -> [URL] {
        let root = homeDirectory.appendingPathComponent(".nvm", isDirectory: true)
        let versionsRoot = root.appendingPathComponent("versions/node", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: versionsRoot.path) else { return [] }
        let versions = names
            .compactMap { name in versionComponents(name).map { (name: name, components: $0) } }
            .sorted { $0.components.lexicographicallyPrecedes($1.components) }
            .reversed()
        let alias = (try? String(contentsOf: root.appendingPathComponent("alias/default"), encoding: .utf8))
            .flatMap(versionComponents)
        let selected = versions.filter { version in alias.map { version.components.starts(with: $0) } ?? false }
        let others = versions.filter { version in !(alias.map { version.components.starts(with: $0) } ?? false) }
        return (selected + others).map {
            versionsRoot.appendingPathComponent($0.name, isDirectory: true).appendingPathComponent("bin", isDirectory: true)
        }
    }

    /// `v22.3.0`·`22` 형식의 숫자 구성요소 변환, 그 외 별칭 제외
    private static func versionComponents(_ value: String) -> [Int]? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    /// 심볼릭 링크 원본·npm 패키지 접두 경로 중 Node가 있는 폴더 목록
    static func nodeDirectories(forExecutable executable: URL) -> [String] {
        var directories: [URL] = []
        var current = executable.standardizedFileURL
        for _ in 0..<16 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else { break }
            current = URL(fileURLWithPath: destination, relativeTo: current.deletingLastPathComponent()).standardizedFileURL
            directories.append(current.deletingLastPathComponent())
        }
        let resolved = executable.resolvingSymlinksInPath().path
        if let range = resolved.range(of: "/lib/node_modules/") {
            directories.append(URL(fileURLWithPath: String(resolved[..<range.lowerBound])).appendingPathComponent("bin", isDirectory: true))
        }
        return directories.map(\.path).filter(containsNode)
    }

    /// 실행 가능한 Node 포함 여부
    static func containsNode(_ directory: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: directory).appendingPathComponent("node").path)
    }

    /// 표준입력을 닫은 대화형 로그인 셸의 PATH 제한시간 조회, 설정 파일 출력 제외
    static func readLoginShellPath(shell: URL, environment: [String: String], timeout: TimeInterval) -> String? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("lqc-shell-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return nil }
        defer { try? FileManager.default.removeItem(at: output) }
        guard let handle = try? FileHandle(forWritingTo: output) else { return nil }
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = shell
        process.arguments = ["-ilc", "printf '%s' '\(startMarker)'; /usr/bin/printenv PATH; printf '%s' '\(endMarker)'"]
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let group = ProcessGroupTermination.group(of: process)

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        // 설정 파일이 남긴 백그라운드 자식까지 정리
        ProcessGroupTermination.terminate(process, group: group, until: Date().addingTimeInterval(0.5))

        guard let reader = try? FileHandle(forReadingFrom: output) else { return nil }
        defer { try? reader.close() }
        guard let data = try? reader.read(upToCount: maximumShellOutput) else { return nil }
        return parseMarkedPath(String(decoding: data, as: UTF8.self))
    }

    /// 표식 사이의 단일 행 PATH 값 추출
    private static func parseMarkedPath(_ text: String) -> String? {
        guard let end = text.range(of: endMarker, options: .backwards),
              let start = text.range(of: startMarker, options: .backwards, range: text.startIndex..<end.lowerBound) else { return nil }
        let value = text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.contains("\n") ? nil : value
    }

    /// 사용자 계정 기본 셸 조회, 실패 시 macOS 기본 셸 사용
    private static func defaultShell() -> URL {
        let candidates = [ProcessInfo.processInfo.environment["SHELL"], getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) }]
        let shell = candidates.compactMap { $0 }.first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
        return URL(fileURLWithPath: shell ?? "/bin/zsh")
    }

    private static func directories(inPath path: String?) -> [URL] {
        (path ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
    }

    private static func firstExecutable(in paths: [URL]) -> URL? {
        paths.lazy.map(\.standardizedFileURL).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
