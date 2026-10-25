// 목적: 허용된 진단 이벤트의 로컬 JSONL 기록과 보관 관리
// 이용처: CodexQuotaMonitorKit 및 저장소 테스트
// 사용방법: DiagnosticLogger.shared.record(...) 호출 후 종료 시 flush() 호출
// 실행 예: DiagnosticLogger.shared.record(.appStarted); DiagnosticLogger.shared.flush()

import CoreFoundation
import Darwin
import Foundation
import OSLog

/// 동일 프로세스·동일 디렉터리의 로거를 파일 잠금 이전에 직렬화하는 공유 경계
private final class DiagnosticStorageLockPool: @unchecked Sendable {
    private let registryLock = NSLock()
    private var locks: [String: NSLock] = [:]

    /// 디렉터리별 잠금의 원자적 생성·재사용
    func lock(for path: String) -> NSLock {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locks[path] { return existing }
        let lock = NSLock()
        locks[path] = lock
        return lock
    }
}

/// - 목적: 진단 이벤트 기록·정리·동기화
/// - 보관: 사용자 로그 폴더의 현지 날짜별 7일·10MB 제한 JSONL 저장
public final class DiagnosticLogger: @unchecked Sendable {
    private static let processLocks = DiagnosticStorageLockPool()
    /// - 목적: 앱 운영용 로거, XCTest에서는 임시 저장소·비활성 운영 기능 사용
    public static let shared = makeShared()
    /// - 목적: 관리 대상 JSONL의 기본 총 바이트 상한
    public static let defaultMaximumBytes = 10_000_000
    /// - 목적: 진단 기록의 기본 보존 기간(초)
    public static let defaultMaximumAge: TimeInterval = 604_800

    private static let directoryMode: mode_t = 0o700
    private static let fileMode: mode_t = 0o600
    private static let lockFileName = ".diagnostic.lock"
    private static let timerInterval: TimeInterval = 60
    /// - 목적: 용량 정리 전 중단된 단일 행 추가의 여유 크기 포함
    private static let maximumReadableFileBytes = defaultMaximumBytes + 1_048_576

    private let directory: URL
    private let processStorageLock: NSLock
    private let now: @Sendable () -> Date
    private let maxBytes: Int
    private let maxAge: TimeInterval
    /// - 목적: 날짜별 파일명 산정에 사용하는 현지 시간대
    private let timeZone: TimeZone
    private let sessionID = UUID().uuidString.lowercased()
    private let storageQueue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let osLogEnabled: Bool
    private let osLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CodexQuotaMonitor", category: "DiagnosticLogger")
    private var dailyFileCache: [String: CachedDailyFile] = [:]
    private var timer: DispatchSourceTimer?

    /// - 목적: 테스트 프로세스의 실사용 로그 저장·OSLog·타이머 격리
    private static func makeShared() -> DiagnosticLogger {
        let arguments = ProcessInfo.processInfo.arguments
        let testArgument = arguments.contains {
            $0.hasSuffix(".xctest") || $0.hasSuffix(".xctest/") || $0.contains(".xctest/Contents/")
        }
        let testEnvironment = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"]?.isEmpty == false
        guard testArgument || testEnvironment else { return DiagnosticLogger() }
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexQuotaMonitor-tests-\(getpid())", isDirectory: true)
        return DiagnosticLogger(directory: testDirectory, osLogEnabled: false, timerEnabled: false)
    }

    /// - 목적: 저장 경로·시계·시간대·보관 한도·운영 기능 주입
    /// - 매개변수: directory — 기본 로그 디렉터리, now — 주입 시계, timeZone — 일별 파일 기준 시간대
    /// - 매개변수: maxBytes/maxAge — 보관 상한, osLogEnabled/timerEnabled — 운영 기능 전환
    public init(
        directory: URL? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        maxBytes: Int = DiagnosticLogger.defaultMaximumBytes,
        maxAge: TimeInterval = DiagnosticLogger.defaultMaximumAge,
        timeZone: TimeZone = .autoupdatingCurrent,
        osLogEnabled: Bool = true,
        timerEnabled: Bool = true
    ) {
        let resolvedDirectory = (directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CodexQuotaMonitor", isDirectory: true)).standardizedFileURL
        self.directory = resolvedDirectory
        self.processStorageLock = Self.processLocks.lock(for: resolvedDirectory.path)
        self.now = now
        self.maxBytes = min(Self.defaultMaximumBytes, max(1, maxBytes))
        self.maxAge = maxAge.isFinite
            ? min(Self.defaultMaximumAge, max(0, maxAge))
            : Self.defaultMaximumAge
        self.timeZone = timeZone
        self.osLogEnabled = osLogEnabled
        storageQueue = DispatchQueue(label: "CodexQuotaMonitor.DiagnosticLogger.storage", qos: .utility)
        storageQueue.setSpecific(key: queueKey, value: 1)

        storageQueue.async { [weak self] in
            self?.maintainStorage()
        }
        if timerEnabled {
            let source = DispatchSource.makeTimerSource(queue: storageQueue)
            source.schedule(deadline: .now() + Self.timerInterval, repeating: Self.timerInterval, leeway: .seconds(10))
            source.setEventHandler { [weak self] in
                self?.maintainStorage()
            }
            source.resume()
            timer = source
        }
    }

    /// - 목적: 제한된 진단 이벤트의 비동기 기록과 OSLog 병행
    /// - 매개변수: event — 고정 이벤트, level — 기록 수준, operationID — 제어된 작업 식별자
    /// - 매개변수: accountID — C1–C4 슬롯, fields — 허용된 진단 필드
    public func record(
        _ event: DiagnosticEvent,
        level: DiagnosticLevel = .notice,
        operationID: UUID? = nil,
        accountID: String? = nil,
        fields: [DiagnosticField: DiagnosticValue] = [:]
    ) {
        let timestamp = now()
        guard Self.validTimestamp(timestamp) else { return }
        let safeOperationID = operationID?.uuidString.lowercased()
        let safeAccountID = accountID.flatMap { Self.validAccountID($0) ? $0 : nil }
        let safeFields = Self.sanitizedFields(fields)
        let line = Self.encodeLine(
            timestamp: timestamp,
            sessionID: sessionID,
            event: event,
            level: level,
            operationID: safeOperationID,
            accountID: safeAccountID,
            fields: safeFields
        )

        storageQueue.async { [weak self] in
            guard let self else { return }
            self.mirrorToOSLog(event: event, level: level, line: line)
            guard let line else {
                self.reportStorageFailure()
                return
            }
            self.withStorageLock { directoryFD in
                let maintenance = self.maintainLocked(directoryFD: directoryFD, at: self.now())
                var files = self.enforceCapacity(files: maintenance.files, directoryFD: directoryFD)
                guard timestamp >= self.now().addingTimeInterval(-self.maxAge) else { return }
                guard let appended = self.append(line, timestamp: timestamp, files: files, directoryFD: directoryFD) else {
                    self.reportStorageFailure()
                    return
                }
                files = appended
                _ = self.enforceCapacity(files: files, directoryFD: directoryFD)
            }
        }
    }

    /// - 목적: 비동기 보관 정책 정리 요청
    public func maintain() {
        storageQueue.async { [weak self] in
            self?.maintainStorage()
        }
    }

    /// - 목적: 대기 중인 기록·정리 작업을 제한 시간 내 배출
    /// - 매개변수: timeout — 대기 초, 기본 2초·허용 범위 0–60초
    /// - 반환: 완료 여부, 시간 초과 후에도 기존 큐 작업 지속
    @discardableResult
    public func flush(timeout: TimeInterval = 2) -> Bool {
        guard DispatchQueue.getSpecific(key: queueKey) == nil else { return true }
        let completion = DispatchSemaphore(value: 0)
        storageQueue.async { completion.signal() }
        let seconds = timeout.isFinite ? min(60, max(0, timeout)) : 2
        return completion.wait(timeout: .now() + seconds) == .success
    }

    /// - 목적: 로거 해제 시 주기 타이머 종료
    deinit {
        timer?.cancel()
    }

    /// - 목적: 저장소 잠금 아래 만료·손상·용량 정책 적용
    private func maintainStorage() {
        withStorageLock { directoryFD in
            let date = now()
            let maintenance = maintainLocked(directoryFD: directoryFD, at: date)
            _ = enforceCapacity(files: maintenance.files, directoryFD: directoryFD)
        }
    }

    /// - 목적: 저장 디렉터리 검증 및 프로세스 간 배타 잠금
    /// - 반환: 안전한 디렉터리 파일 디스크립터를 전달한 작업 결과
    private func withStorageLock(_ body: (Int32) -> Void) {
        processStorageLock.lock()
        defer { processStorageLock.unlock() }
        guard let directoryFD = openDirectory() else {
            reportStorageFailure()
            return
        }
        defer { _ = close(directoryFD) }

        let lockFD = openat(directoryFD, Self.lockFileName, O_RDWR | O_CREAT | O_NOFOLLOW, Self.fileMode)
        guard lockFD >= 0 else {
            reportStorageFailure()
            return
        }
        defer { _ = close(lockFD) }

        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0,
              Self.isOwnedRegularFile(lockInfo),
              fchmod(lockFD, Self.fileMode) == 0,
              acquireStorageLock(lockFD) else {
            reportStorageFailure()
            return
        }
        defer { _ = flock(lockFD, LOCK_UN) }
        body(directoryFD)
    }

    /// - 목적: 비차단 재시도와 단조 시계로 프로세스 간 잠금 대기를 250ms 이내 제한
    private func acquireStorageLock(_ fileDescriptor: Int32) -> Bool {
        let deadline = DispatchTime.now() + .milliseconds(250)
        repeat {
            if flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 { return true }
            guard errno == EWOULDBLOCK || errno == EINTR else { return false }
            guard DispatchTime.now() < deadline else { return false }
            usleep(10_000)
        } while DispatchTime.now() < deadline
        return false
    }

    /// - 목적: 디렉터리 생성·소유권·형식·권한 검증
    /// - 반환: 심볼릭 링크가 아닌 전용 디렉터리 파일 디스크립터
    private func openDirectory() -> Int32? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            var existing = stat()
            guard lstat(directory.path, &existing) == 0 else { return nil }
        }

        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == geteuid() else { return nil }

        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { return nil }
        var openedInfo = stat()
        guard fstat(directoryFD, &openedInfo) == 0,
              (openedInfo.st_mode & S_IFMT) == S_IFDIR,
              openedInfo.st_uid == geteuid(),
              fchmod(directoryFD, Self.directoryMode) == 0 else {
            _ = close(directoryFD)
            return nil
        }
        return directoryFD
    }

    /// - 목적: 레거시 이관·만료 행 정리·임시 파일 정리 적용
    private func maintainLocked(directoryFD: Int32, at date: Date) -> (files: [DailyFile], migrationSucceeded: Bool) {
        removeOrphanTemporaryFiles(directoryFD: directoryFD)
        let migrationSucceeded = migrateLegacyFiles(directoryFD: directoryFD, at: date)
        if !migrationSucceeded { reportStorageFailure() }

        let cutoff = date.addingTimeInterval(-maxAge)
        var normalized: [DailyFile] = []
        for file in readDailyFiles(directoryFD: directoryFD) {
            let retained = file.rows.filter { $0.timestamp >= cutoff }
            let retainedBytes = retained.reduce(0) { $0 + $1.data.count + 1 }
            guard retainedBytes != file.originalByteCount else {
                normalized.append(file)
                continue
            }
            if let rewritten = rewrite(file: file, rows: retained, directoryFD: directoryFD) {
                normalized.append(rewritten)
            }
        }
        return (normalized, migrationSucceeded)
    }

    /// - 목적: 중단된 원자 교체의 소유 임시 파일 정리
    private func removeOrphanTemporaryFiles(directoryFD: Int32) {
        let prefix = ".diagnostic-tmp-"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            guard name.hasPrefix(prefix), !name.contains("/"),
                  let info = fileInfo(name: name, directoryFD: directoryFD) else { continue }
            let identifier = String(name.dropFirst(prefix.count))
            guard identifier.count == 36,
                  UUID(uuidString: identifier)?.uuidString.lowercased() == identifier else { continue }

            var currentInfo = stat()
            guard fstatat(directoryFD, name, &currentInfo, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.isOwnedRegularFile(currentInfo), Self.sameFile(info, currentInfo) else { continue }
            if unlinkat(directoryFD, name, 0) != 0 { reportStorageFailure() }
        }
    }

    /// - 목적: 기존 UUID 파일의 유효·미만료 행을 현지 날짜 파일로 통합
    /// - 반환: 모든 대상 기록 완료 후 원본 삭제 성공 여부
    private func migrateLegacyFiles(directoryFD: Int32, at date: Date) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return false }
        let legacyNames = names.filter(Self.isLegacyFileName)
        guard !legacyNames.isEmpty else { return true }

        let cutoff = date.addingTimeInterval(-maxAge)
        var sources: [(name: String, info: stat)] = []
        var rowsByTarget: [String: [ParsedRow]] = [:]
        for name in legacyNames {
            guard let sourceInfo = fileInfo(name: name, directoryFD: directoryFD) else { continue }
            guard let source = readOwnedRows(name: name, expectedInfo: sourceInfo, directoryFD: directoryFD) else {
                quarantineLegacyFile(name, expectedInfo: sourceInfo, directoryFD: directoryFD)
                reportStorageFailure()
                continue
            }
            sources.append((name, source.info))
            for row in source.rows where row.timestamp >= cutoff {
                let target = Self.dailyFileName(timestamp: row.timestamp, timeZone: timeZone)
                rowsByTarget[target, default: []].append(row)
            }
        }

        for (name, legacyRows) in rowsByTarget {
            var mergedRows: [ParsedRow] = []
            var seenRows = Set<Data>()
            var targetInfo = stat()
            if fstatat(directoryFD, name, &targetInfo, AT_SYMLINK_NOFOLLOW) == 0 {
                guard let ownedInfo = fileInfo(name: name, directoryFD: directoryFD),
                      let target = readOwnedRows(name: name, expectedInfo: ownedInfo, directoryFD: directoryFD) else {
                    return false
                }
                for row in target.rows where row.timestamp >= cutoff && seenRows.insert(row.data).inserted {
                    mergedRows.append(row)
                }
            } else if errno != ENOENT {
                return false
            }
            for row in legacyRows where seenRows.insert(row.data).inserted {
                mergedRows.append(row)
            }
            mergedRows = Self.stableChronologicalOrder(mergedRows)
            guard atomicWrite(name: name, rows: mergedRows, directoryFD: directoryFD) else { return false }
        }

        for source in sources {
            guard removeLegacyFile(source.name, expectedInfo: source.info, directoryFD: directoryFD) else { return false }
        }
        return true
    }

    /// - 목적: 읽기 실패 원본을 삭제 없이 격리하여 정상 파일의 이관 지속
    /// - 보관: 격리 파일은 자동 정리 대상에서 제외하여 수동 복구용 원본 보존
    private func quarantineLegacyFile(_ name: String, expectedInfo: stat, directoryFD: Int32) {
        guard Self.isLegacyFileName(name),
              let info = fileInfo(name: name, directoryFD: directoryFD),
              Self.sameFile(expectedInfo, info) else { return }
        let quarantineName = ".diagnostic-quarantine-\(UUID().uuidString.lowercased())"
        if renameatx_np(directoryFD, name, directoryFD, quarantineName, UInt32(RENAME_EXCL)) != 0 {
            reportStorageFailure()
        }
    }

    /// - 목적: 현지 날짜 파일에서 검증된 완전 행 로드
    private func readDailyFiles(directoryFD: Int32) -> [DailyFile] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var validNames = Set<String>()
        let files = names.compactMap { name -> DailyFile? in
            guard Self.isDailyFileName(name) else { return nil }
            guard let info = fileInfo(name: name, directoryFD: directoryFD) else {
                dailyFileCache.removeValue(forKey: name)
                return nil
            }
            validNames.insert(name)
            if let cached = dailyFileCache[name], cached.matches(info) { return cached.file }
            guard let contents = readOwnedRows(name: name, expectedInfo: info, directoryFD: directoryFD) else {
                reportStorageFailure()
                return nil
            }
            let file = Self.makeDailyFile(name: name, rows: contents.rows, byteCount: Int(contents.info.st_size))
            dailyFileCache[name] = CachedDailyFile(file: file, info: contents.info)
            return file
        }
        dailyFileCache = dailyFileCache.filter { validNames.contains($0.key) }
        return files
    }

    /// - 목적: 안전한 소유 파일에서 검증된 JSON 행 로드
    private func readOwnedRows(name: String, expectedInfo: stat, directoryFD: Int32) -> (rows: [ParsedRow], info: stat)? {
        guard expectedInfo.st_size <= off_t(Self.maximumReadableFileBytes) else { return nil }
        let fileFD = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW)
        guard fileFD >= 0 else { return nil }
        defer { _ = close(fileFD) }
        var openedInfo = stat()
        guard fstat(fileFD, &openedInfo) == 0, Self.isOwnedRegularFile(openedInfo),
              Self.sameFile(expectedInfo, openedInfo), fchmod(fileFD, Self.fileMode) == 0,
              fstat(fileFD, &openedInfo) == 0,
              let data = Self.readAll(fileFD, maximumBytes: Self.maximumReadableFileBytes) else { return nil }
        let rows = Self.parseRows(data).compactMap { rawRow -> ParsedRow? in
            guard let timestamp = Self.parseRow(rawRow) else { return nil }
            return ParsedRow(data: rawRow, timestamp: timestamp)
        }
        return (rows, openedInfo)
    }

    /// - 목적: 날짜 파일 교체 또는 빈 날짜 파일 제거
    private func rewrite(file: DailyFile, rows: [ParsedRow], directoryFD: Int32) -> DailyFile? {
        if rows.isEmpty {
            guard removeDailyFile(file.name, directoryFD: directoryFD) else {
                reportStorageFailure()
                return file
            }
            return nil
        }
        guard atomicWrite(name: file.name, rows: rows, directoryFD: directoryFD),
              let info = fileInfo(name: file.name, directoryFD: directoryFD) else {
            reportStorageFailure()
            return file
        }
        let updated = Self.makeDailyFile(name: file.name, rows: rows, byteCount: Self.data(for: rows).count)
        dailyFileCache[file.name] = CachedDailyFile(file: updated, info: info)
        return updated
    }

    /// - 목적: 시각 역전과 무관하게 해당 현지 날짜 파일에 행 추가
    private func append(_ line: Data, timestamp: Date, files: [DailyFile], directoryFD: Int32) -> [DailyFile]? {
        let name = Self.dailyFileName(timestamp: timestamp, timeZone: timeZone)
        let row = ParsedRow(data: line, timestamp: timestamp)
        if let index = files.firstIndex(where: { $0.name == name }) {
            let file = files[index]
            guard append(line, to: name, directoryFD: directoryFD),
                  let info = fileInfo(name: name, directoryFD: directoryFD) else { return nil }
            let updated = Self.makeDailyFile(
                name: name,
                rows: file.rows + [row],
                byteCount: file.byteCount + line.count + 1
            )
            dailyFileCache[name] = CachedDailyFile(file: updated, info: info)
            var result = files
            result[index] = updated
            return result
        }

        let fileFD = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, Self.fileMode)
        guard fileFD >= 0 else { return nil }
        var info = stat()
        let valid = fstat(fileFD, &info) == 0 && Self.isOwnedRegularFile(info) && fchmod(fileFD, Self.fileMode) == 0
        var bytes = line
        bytes.append(0x0A)
        let succeeded = valid && Self.writeAll(bytes, to: fileFD)
        _ = close(fileFD)
        guard succeeded, let createdInfo = fileInfo(name: name, directoryFD: directoryFD) else {
            _ = unlinkat(directoryFD, name, 0)
            return nil
        }
        let created = Self.makeDailyFile(name: name, rows: [row], byteCount: bytes.count)
        dailyFileCache[name] = CachedDailyFile(file: created, info: createdInfo)
        return files + [created]
    }

    /// - 목적: 날짜 파일에 줄바꿈 포함 행 추가
    private func append(_ line: Data, to name: String, directoryFD: Int32) -> Bool {
        guard let before = fileInfo(name: name, directoryFD: directoryFD) else { return false }
        let fileFD = openat(directoryFD, name, O_WRONLY | O_APPEND | O_NOFOLLOW)
        guard fileFD >= 0 else { return false }
        defer { _ = close(fileFD) }
        var info = stat()
        guard fstat(fileFD, &info) == 0, Self.isOwnedRegularFile(info), info.st_ino == before.st_ino,
              fchmod(fileFD, Self.fileMode) == 0 else { return false }
        var bytes = line
        bytes.append(0x0A)
        return Self.writeAll(bytes, to: fileFD)
    }

    /// - 목적: 날짜 파일의 안전한 원자 교체
    private func atomicWrite(name: String, rows: [ParsedRow], directoryFD: Int32) -> Bool {
        guard Self.isDailyFileName(name) else { return false }
        let data = Self.data(for: rows)
        var originalInfo = stat()
        let exists = fstatat(directoryFD, name, &originalInfo, AT_SYMLINK_NOFOLLOW) == 0
        if exists {
            guard Self.isOwnedRegularFile(originalInfo) else { return false }
        } else if errno != ENOENT {
            return false
        }

        let temporaryName = ".diagnostic-tmp-\(UUID().uuidString.lowercased())"
        let temporaryFD = openat(directoryFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, Self.fileMode)
        guard temporaryFD >= 0 else { return false }
        var tempInfo = stat()
        let written = fstat(temporaryFD, &tempInfo) == 0 && Self.isOwnedRegularFile(tempInfo) &&
            fchmod(temporaryFD, Self.fileMode) == 0 && Self.writeAll(data, to: temporaryFD)
        _ = close(temporaryFD)
        guard written else {
            _ = unlinkat(directoryFD, temporaryName, 0)
            return false
        }

        var latestInfo = stat()
        if exists {
            guard fstatat(directoryFD, name, &latestInfo, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.isOwnedRegularFile(latestInfo), Self.sameFile(originalInfo, latestInfo) else {
                _ = unlinkat(directoryFD, temporaryName, 0)
                return false
            }
        } else if fstatat(directoryFD, name, &latestInfo, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT {
            _ = unlinkat(directoryFD, temporaryName, 0)
            return false
        }
        guard renameat(directoryFD, temporaryName, directoryFD, name) == 0 else {
            _ = unlinkat(directoryFD, temporaryName, 0)
            return false
        }
        dailyFileCache.removeValue(forKey: name)
        return true
    }

    /// - 목적: 상한 초과 시 오래된 행을 묶어 제거하여 반복 정렬·파일 교체 억제
    /// - 정책: 총 용량의 10% 여유 확보, 상한 내 단일 최신 행 보존
    private func enforceCapacity(files input: [DailyFile], directoryFD: Int32) -> [DailyFile] {
        let totalBytes = input.reduce(0) { $0 + $1.byteCount }
        guard totalBytes > maxBytes else { return input }
        var candidates: [(name: String, index: Int, timestamp: Date, byteCount: Int)] = []
        for file in input {
            for (index, row) in file.rows.enumerated() {
                candidates.append((file.name, index, row.timestamp, row.data.count + 1))
            }
        }
        candidates.sort {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.index < $1.index
        }

        let newestRowBytes = candidates.last?.byteCount ?? 0
        let targetBytes = max(maxBytes - max(1, maxBytes / 10), min(maxBytes, newestRowBytes))
        var total = totalBytes
        var removedRows: [String: Set<Int>] = [:]
        for candidate in candidates {
            guard total > targetBytes else { break }
            removedRows[candidate.name, default: []].insert(candidate.index)
            total -= candidate.byteCount
        }

        var retainedFiles: [DailyFile] = []
        for file in input {
            guard let removed = removedRows[file.name], !removed.isEmpty else {
                retainedFiles.append(file)
                continue
            }
            let rows = file.rows.enumerated().compactMap { removed.contains($0.offset) ? nil : $0.element }
            if let updated = rewrite(file: file, rows: rows, directoryFD: directoryFD) {
                retainedFiles.append(updated)
            }
        }
        return retainedFiles
    }

    /// - 목적: 소유한 일별 파일만 안전하게 제거
    private func removeDailyFile(_ name: String, directoryFD: Int32) -> Bool {
        guard Self.isDailyFileName(name) else { return false }
        var info = stat()
        guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            let absent = errno == ENOENT
            if absent { dailyFileCache.removeValue(forKey: name) }
            return absent
        }
        guard Self.isOwnedRegularFile(info), unlinkat(directoryFD, name, 0) == 0 else { return false }
        dailyFileCache.removeValue(forKey: name)
        return true
    }

    /// - 목적: 동일 inode·형식이 유지된 레거시 원본 제거
    private func removeLegacyFile(_ name: String, expectedInfo: stat, directoryFD: Int32) -> Bool {
        guard Self.isLegacyFileName(name) else { return false }
        guard let info = fileInfo(name: name, directoryFD: directoryFD) else {
            var currentInfo = stat()
            return fstatat(directoryFD, name, &currentInfo, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT
        }
        guard Self.sameFile(expectedInfo, info), unlinkat(directoryFD, name, 0) == 0 else { return false }
        return true
    }

    /// - 목적: 파일 디스크립터 기준 파일 속성 확인
    /// - 반환: 일반·현재 사용자 소유의 링크되지 않은 파일 속성
    private func fileInfo(name: String, directoryFD: Int32) -> stat? {
        var info = stat()
        guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              Self.isOwnedRegularFile(info) else { return nil }
        return info
    }

    /// - 목적: 고정 이벤트와 허용 필드만 OSLog에 기록
    private func mirrorToOSLog(event: DiagnosticEvent, level: DiagnosticLevel, line: Data?) {
        guard osLogEnabled else { return }
        let safeRecord = line.flatMap { String(data: $0, encoding: .utf8) } ?? event.rawValue
        switch level {
        case .notice: osLogger.notice("diagnostic record: \(safeRecord, privacy: .public)")
        case .error: osLogger.error("diagnostic record: \(safeRecord, privacy: .public)")
        case .debug: osLogger.debug("diagnostic record: \(safeRecord, privacy: .public)")
        }
    }

    /// - 목적: 원문 오류 없이 고정 저장 실패 이벤트 출력
    private func reportStorageFailure() {
        guard osLogEnabled else { return }
        osLogger.error("diagnostic storage unavailable")
    }

    /// - 목적: 유효 식별자만 필드 맵에 반영
    private static func sanitizedFields(_ fields: [DiagnosticField: DiagnosticValue]) -> [DiagnosticField: DiagnosticValue] {
        fields.reduce(into: [:]) { result, item in
            switch item.value {
            case .integer, .boolean:
                result[item.key] = item.value
            case .timestamp(let date) where validTimestamp(date):
                result[item.key] = item.value
            case .identifier(let value) where validIdentifier(value):
                result[item.key] = item.value
            default:
                break
            }
        }
    }

    /// - 목적: 식별자 필드의 ASCII 허용 문자·길이 검증
    private static func validIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 80 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) ||
                (byte >= 97 && byte <= 122) || byte == 95 || byte == 46 || byte == 45
        }
    }

    /// - 목적: 계정 슬롯 식별자를 C1–C4로 제한
    private static func validAccountID(_ value: String) -> Bool {
        ["C1", "C2", "C3", "C4"].contains(value)
    }

    /// - 목적: ISO 8601 및 파일명 표현이 가능한 시각 범위 확인
    private static func validTimestamp(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && seconds >= -62_135_596_800 && seconds <= 253_402_300_799
    }

    /// - 목적: 진단 행을 정렬 키 JSONL 데이터로 인코딩
    private static func encodeLine(
        timestamp: Date,
        sessionID: String,
        event: DiagnosticEvent,
        level: DiagnosticLevel,
        operationID: String?,
        accountID: String?,
        fields: [DiagnosticField: DiagnosticValue]
    ) -> Data? {
        var object: [String: Any] = [
            "timestamp": format(timestamp),
            "sessionID": sessionID,
            "event": event.rawValue,
            "level": level.rawValue,
            "fields": fields.reduce(into: [String: Any]()) { result, pair in
                result[pair.key.rawValue] = encode(pair.value)
            }
        ]
        if let operationID { object["operationID"] = operationID }
        if let accountID { object["accountID"] = accountID }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// - 목적: 필드 값의 형식 정보를 포함한 JSON 표현 생성
    private static func encode(_ value: DiagnosticValue) -> [String: Any] {
        switch value {
        case .integer(let value): ["type": "integer", "value": value]
        case .boolean(let value): ["type": "boolean", "value": value]
        case .timestamp(let value): ["type": "timestamp", "value": format(value)]
        case .identifier(let value): ["type": "identifier", "value": value]
        }
    }

    /// - 목적: JSONL 한 행의 필수 구조·식별자·시간 검증
    /// - 반환: 파싱된 시각 또는 잘못된 행 표시
    private static func parseRow(_ data: Data) -> Date? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = object["timestamp"] as? String,
              let date = parseDate(timestamp), validTimestamp(date),
              let sessionID = object["sessionID"] as? String, validIdentifier(sessionID),
              let event = object["event"] as? String, DiagnosticEvent(rawValue: event) != nil,
              let level = object["level"] as? String, DiagnosticLevel(rawValue: level) != nil,
              object["operationID"].map({ ($0 as? String).map(validIdentifier) ?? false }) ?? true,
              object["accountID"].map({ ($0 as? String).map(validAccountID) ?? false }) ?? true,
              let fields = object["fields"] as? [String: Any],
              fields.allSatisfy({ validField($0.key, value: $0.value) }) else { return nil }
        return date
    }

    /// - 목적: 저장 필드 이름과 명시된 값 형식 검증
    private static func validField(_ name: String, value: Any) -> Bool {
        guard DiagnosticField(rawValue: name) != nil,
              let typed = value as? [String: Any],
              let type = typed["type"] as? String,
              let rawValue = typed["value"] else { return false }
        switch type {
        case "integer":
            guard let number = rawValue as? NSNumber else { return false }
            return CFGetTypeID(number) != CFBooleanGetTypeID()
        case "boolean":
            guard let number = rawValue as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        case "timestamp":
            return (rawValue as? String).flatMap(parseDate) != nil
        case "identifier":
            return (rawValue as? String).map(validIdentifier) ?? false
        default:
            return false
        }
    }

    /// - 목적: 완전한 줄바꿈 행만 JSONL 후보로 분리
    private static func parseRows(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        var rows: [Data] = []
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 0x0A) {
            if newline > start { rows.append(data.subdata(in: start..<newline)) }
            start = data.index(after: newline)
        }
        return rows
    }

    /// - 목적: JSONL 행 묶음의 줄바꿈 포함 데이터 생성
    private static func data(for rows: [ParsedRow]) -> Data {
        var data = Data()
        for row in rows {
            data.append(row.data)
            data.append(0x0A)
        }
        return data
    }

    /// - 목적: 주입 시간대 기준 날짜별 로그 파일명 생성
    private static func dailyFileName(timestamp: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return "diagnostic-\(formatter.string(from: timestamp)).jsonl"
    }

    /// - 목적: 유효한 현지 날짜 파일명 확인
    private static func isDailyFileName(_ name: String) -> Bool {
        guard name.hasPrefix("diagnostic-"), name.hasSuffix(".jsonl"), !name.contains("/") else { return false }
        let value = String(name.dropFirst("diagnostic-".count).dropLast(".jsonl".count))
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ [4, 7].contains($0.offset) || (48...57).contains($0.element) }) else {
            return false
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    /// - 목적: 이전 UUID 기반 로그 파일명 확인
    private static func isLegacyFileName(_ name: String) -> Bool {
        guard name.hasPrefix("diagnostic-"), name.hasSuffix(".jsonl"), !isDailyFileName(name), !name.contains("/") else {
            return false
        }
        let body = String(name.dropFirst("diagnostic-".count).dropLast(".jsonl".count))
        guard body.count > 37 else { return false }
        let uuidStart = body.index(body.endIndex, offsetBy: -36)
        let separator = body.index(before: uuidStart)
        let uuidString = String(body[uuidStart...])
        let timestampString = String(body[..<separator])
        return body[separator] == "-" && Int64(timestampString) != nil &&
            UUID(uuidString: uuidString)?.uuidString.lowercased() == uuidString
    }

    /// - 목적: 중복 행 제거 후 원래 순서를 유지하며 시각순 정렬
    private static func stableChronologicalOrder(_ rows: [ParsedRow]) -> [ParsedRow] {
        rows.enumerated().sorted {
            if $0.element.timestamp != $1.element.timestamp { return $0.element.timestamp < $1.element.timestamp }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    /// - 목적: 파일 속성의 일반 파일·현재 사용자 소유·단일 링크 확인
    private static func isOwnedRegularFile(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == geteuid() && info.st_nlink == 1
    }

    /// - 목적: UTC ISO 8601 시각 표현 생성
    private static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// - 목적: ISO 8601 시각을 보존 시각으로 변환
    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    /// - 목적: 잠금 파일에서 전체 데이터를 읽기
    private static func readAll(_ fileDescriptor: Int32, maximumBytes: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard data.count + count <= maximumBytes else { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    /// - 목적: 파일 속성을 일별 로그 모델로 변환
    private static func makeDailyFile(name: String, rows: [ParsedRow], byteCount: Int) -> DailyFile {
        return DailyFile(
            name: name,
            rows: rows,
            byteCount: byteCount,
            originalByteCount: byteCount
        )
    }

    /// - 목적: 파일명·크기·inode·수정 시각 일치 확인
    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    /// - 목적: 전체 데이터를 파일 디스크립터에 기록
    private static func writeAll(_ data: Data, to fileDescriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fileDescriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if count == 0 { return false }
                offset += count
            }
            return true
        }
    }

    /// - 목적: 검증된 JSONL 행과 기록 시각 보유
    private struct ParsedRow {
        let data: Data
        let timestamp: Date
    }

    /// - 목적: 일별 파일 메타데이터와 파싱 결과 보유
    private struct DailyFile {
        let name: String
        let rows: [ParsedRow]
        let byteCount: Int
        let originalByteCount: Int
    }

    /// - 목적: 변경되지 않은 날짜 파일의 파싱 결과 재사용
    private struct CachedDailyFile {
        let file: DailyFile
        let inode: ino_t
        let size: off_t
        let mode: mode_t
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64

        /// - 목적: 현재 파일 메타데이터와 캐시 키 일치 확인
        func matches(_ info: stat) -> Bool {
            inode == info.st_ino && size == info.st_size && mode == (info.st_mode & 0o777) &&
                modifiedSeconds == Int64(info.st_mtimespec.tv_sec) &&
                modifiedNanoseconds == Int64(info.st_mtimespec.tv_nsec)
        }

        /// - 목적: 파일 속성에서 캐시 항목 생성
        init(file: DailyFile, info: stat) {
            self.file = file
            inode = info.st_ino
            size = info.st_size
            mode = info.st_mode & 0o777
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        }
    }
}

/// - 목적: 고정 진단 이벤트 목록
public enum DiagnosticEvent: String, CaseIterable, Sendable {
    case appStarted
    case appTerminating
    case appWoke
    case launchAtLoginStatusRead
    case launchAtLoginChanged
    case cliDetected
    case probeRequested
    case probeRejected
    case probeStarted
    case probeFinished
    case probeResultApplied
    case probeResultDiscarded
    case probeCancelled
    case catalogStarted
    case catalogFinished
    case processStarted
    case processFinished
    case quotaRefreshStarted
    case quotaRefreshFinished
    case quotaResultApplied
    case quotaResultDiscarded
    case accountReconfigured
    case resetCreditRequested
    case resetCreditRejected
    case resetCreditFinished
    case automaticResetPingDetected
    case automaticResetPingSkipped
    case automaticResetPingAttempt
    case automaticResetPingFinished
    case quotaResetDetected
    case resetObservationUpdated
    case resetConfirmationUpdated
}

/// - 목적: OSLog·파일 진단 수준
public enum DiagnosticLevel: String, Sendable {
    case notice
    case error
    case debug
}

/// - 목적: 저장을 허용한 진단 필드 목록
public enum DiagnosticField: String, CaseIterable, Sendable {
    case generation
    case durationMS
    case exitCode
    case failure
    case errorDomain
    case errorCode
    case status
    case model
    case version
    case build
    case cliVersion
    case forceFresh
    case applied
    case primaryResetBefore
    case primaryResetAfter
    case secondaryResetBefore
    case secondaryResetAfter
    case inputTokens
    case outputTokens
    case requestID
    case reason
    case attempt
    case window
    case cause
    case observation
    case segmentID
}

/// - 목적: 진단 JSONL에 저장할 값 형식
public enum DiagnosticValue: Sendable {
    case integer(Int)
    case boolean(Bool)
    case timestamp(Date)
    case identifier(String)
}
