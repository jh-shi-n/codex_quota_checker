// 목적: 앱 SQLite 디렉터리·DB·sidecar의 사용자 전용 권한 보장
// 이용처: 토큰 이력·할당량·서버 사용량 캐시의 공통 파일 정책
import Darwin
import Foundation

/// 기존 파일 보정과 신규 DB 생성의 공통 권한 정책
 enum PrivateSQLiteFiles {
    /// 앱 디렉터리 0700 및 DB 0600 생성·보정
    static func prepare(_ database: URL) throws {
        let manager = FileManager.default
        let directory = database.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let shared = [manager.temporaryDirectory, manager.homeDirectoryForCurrentUser] + manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        if !shared.contains(where: { $0.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path }) {
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        let descriptor = Darwin.open(database.path, O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { Darwin.close(descriptor) }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        try secureExisting(database)
    }

    /// SQLite가 생성한 WAL·SHM·journal 및 기존 DB의 0600 권한 보정
    static func secureExisting(_ database: URL) throws {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let path = database.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
            let result = fchmod(descriptor, mode_t(0o600))
            Darwin.close(descriptor)
            guard result == 0 else { throw CocoaError(.fileWriteNoPermission) }
        }
    }
}
