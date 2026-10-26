// 목적: 배포 ZIP의 항목·경로·실제 압축 해제 바이트 상한 강제
// 이용처: 앱 업데이트의 서명 검증 이후 제한된 ZIP 추출
import Compression
import Foundation

/// ZIP64·암호화·심볼릭 링크를 허용하지 않는 앱 배포 전용 추출기
 enum BoundedZipExtractor {
    static let maximumArchiveBytes = 200_000_000
    static let maximumExtractedBytes = 500_000_000
    static let maximumEntries = 20_000

    /// ZIP 중앙 디렉터리의 검증된 단일 파일 메타데이터
    private struct Entry {
        let path: String
        let size: Int
        let compressedSize: Int
        let offset: Int
        let crc: UInt32
        let method: UInt16
        let executable: Bool
        let flags: UInt16
        let centralOffset: Int
    }

    /// 실제 전송 크기·항목 수·실제 출력 총량과 60초 제한을 적용한 추출
    static func extract(_ archive: URL, to destination: URL, maximumBytes: Int = maximumExtractedBytes,
                        maximumCount: Int = maximumEntries) throws {
        let length = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard length > 0, length <= maximumArchiveBytes else { throw AppUpdateInstallError.invalidArchive }
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        let entries = try entries(in: data, maximumBytes: maximumBytes, maximumCount: maximumCount)
        let deadline = Date().addingTimeInterval(60)
        var total = 0
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for entry in entries {
            try Task.checkCancellation()
            guard Date() < deadline else { throw AppUpdateInstallError.invalidArchive }
            let target = destination.appendingPathComponent(entry.path)
            if entry.path.hasSuffix("/") {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                continue
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard !FileManager.default.fileExists(atPath: target.path),
                  FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: entry.executable ? 0o700 : 0o600]) else {
                throw AppUpdateInstallError.invalidArchive
            }
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            let start = entry.offset
            guard start >= 0, start + 30 <= entry.centralOffset, data.u32(start) == 0x04034b50,
                  data.u16(start + 6) == entry.flags, data.u16(start + 8) == entry.method else { throw AppUpdateInstallError.invalidArchive }
            let payload = start + 30 + Int(data.u16(start + 26)) + Int(data.u16(start + 28))
            guard payload <= entry.centralOffset, entry.compressedSize <= entry.centralOffset - payload,
                  String(data: data.subdata(in: (start + 30)..<(start + 30 + Int(data.u16(start + 26)))) , encoding: .utf8) == entry.path else { throw AppUpdateInstallError.invalidArchive }
            if entry.flags & 8 == 0 {
                guard data.u32(start + 14) == entry.crc, Int(data.u32(start + 18)) == entry.compressedSize,
                      Int(data.u32(start + 22)) == entry.size else { throw AppUpdateInstallError.invalidArchive }
            }
            var written = 0
            var crc: UInt32 = 0xffffffff
            /// 출력 제한 확인 후 디스크 기록과 CRC 갱신
            func write(_ chunk: Data) throws {
                try Task.checkCancellation()
                guard Date() < deadline, chunk.count <= entry.size - written, chunk.count <= maximumBytes - total else {
                    throw AppUpdateInstallError.invalidArchive
                }
                written += chunk.count
                total += chunk.count
                for byte in chunk { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
                try handle.write(contentsOf: chunk)
            }
            if entry.method == 0 {
                guard entry.compressedSize == entry.size else { throw AppUpdateInstallError.invalidArchive }
                var position = payload
                while position < payload + entry.compressedSize {
                    let end = min(position + 65_536, payload + entry.compressedSize)
                    try write(data.subdata(in: position..<end))
                    position = end
                }
            } else {
                try inflate(data, range: payload..<(payload + entry.compressedSize), write: write)
            }
            guard written == entry.size, (crc ^ 0xffffffff) == entry.crc else { throw AppUpdateInstallError.invalidArchive }
        }
    }

    /// 압축 해제 스트림의 매 chunk를 제한 검사로 전달
    private static func inflate(_ data: Data, range: Range<Int>, write: (Data) throws -> Void) throws {
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: 65_536)
        defer { output.deallocate() }
        var stream = compression_stream(dst_ptr: output, dst_size: 0, src_ptr: UnsafePointer(output), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw AppUpdateInstallError.invalidArchive
        }
        defer { compression_stream_destroy(&stream) }
        try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            guard let base = source.baseAddress else { throw AppUpdateInstallError.invalidArchive }
            stream.src_ptr = base.advanced(by: range.lowerBound).assumingMemoryBound(to: UInt8.self)
            stream.src_size = range.count
            while true {
                stream.dst_ptr = output
                stream.dst_size = 65_536
                let before = stream.src_size
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let count = 65_536 - stream.dst_size
                if count > 0 { try write(Data(bytes: output, count: count)) }
                if status == COMPRESSION_STATUS_END {
                    guard stream.src_size == 0 else { throw AppUpdateInstallError.invalidArchive }
                    return
                }
                guard status == COMPRESSION_STATUS_OK, count > 0 || stream.src_size < before else { throw AppUpdateInstallError.invalidArchive }
            }
        }
    }

    /// ZIP64·중복 경로·외부 링크·암호화·총량 초과를 추출 전에 차단
    private static func entries(in data: Data, maximumBytes: Int, maximumCount: Int) throws -> [Entry] {
        guard data.count >= 22 else { throw AppUpdateInstallError.invalidArchive }
        let minimum = max(0, data.count - 65_557)
        guard let end = stride(from: data.count - 22, through: minimum, by: -1).first(where: {
            data.u32($0) == 0x06054b50 && $0 + 22 + Int(data.u16($0 + 20)) == data.count
        }), data.u16(end + 4) == 0, data.u16(end + 6) == 0,
              data.u16(end + 8) == data.u16(end + 10) else { throw AppUpdateInstallError.invalidArchive }
        let count = Int(data.u16(end + 10))
        let size = Int(data.u32(end + 12))
        let start = Int(data.u32(end + 16))
        guard count > 0, count <= maximumCount, size <= 8_000_000, start <= end, size == end - start else { throw AppUpdateInstallError.invalidArchive }
        var cursor = start
        var total = 0
        var seen = Set<String>()
        var result: [Entry] = []
        for _ in 0..<count {
            guard cursor + 46 <= end, data.u32(cursor) == 0x02014b50 else { throw AppUpdateInstallError.invalidArchive }
            let nameLength = Int(data.u16(cursor + 28))
            let next = cursor + 46 + nameLength + Int(data.u16(cursor + 30)) + Int(data.u16(cursor + 32))
            let method = data.u16(cursor + 10)
            let flags = data.u16(cursor + 8)
            let mode = data.u32(cursor + 38) >> 16
            let fileType = mode & 0xf000
            guard next <= end, nameLength > 0, flags & 1 == 0, method == 0 || method == 8,
                  data.u16(cursor + 34) == 0,
                  fileType == 0 || fileType == 0x8000 || fileType == 0x4000,
                  let path = String(data: data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength)), encoding: .utf8) else {
                throw AppUpdateInstallError.invalidArchive
            }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"), !parts.contains(".."), !parts.contains("."),
                  parts.first == Substring(AppUpdateInstaller.appName) || parts.first == "__MACOSX",
                  !parts.dropLast().contains(""), seen.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw AppUpdateInstallError.invalidArchive
            }
            guard (fileType == 0x4000) == path.hasSuffix("/") || fileType == 0 else { throw AppUpdateInstallError.invalidArchive }
            let expanded = Int(data.u32(cursor + 24))
            guard expanded <= maximumBytes - total else { throw AppUpdateInstallError.invalidArchive }
            total += expanded
            let offset = Int(data.u32(cursor + 42))
            let compressedSize = Int(data.u32(cursor + 20))
            guard offset + 30 <= start, compressedSize <= start - offset,
                  data.u32(offset) == 0x04034b50, data.u16(offset + 6) == flags, data.u16(offset + 8) == method else {
                throw AppUpdateInstallError.invalidArchive
            }
            let localNameEnd = offset + 30 + Int(data.u16(offset + 26))
            let localPayload = localNameEnd + Int(data.u16(offset + 28))
            guard localPayload <= start, compressedSize <= start - localPayload,
                  String(data: data.subdata(in: (offset + 30)..<localNameEnd), encoding: .utf8) == path else {
                throw AppUpdateInstallError.invalidArchive
            }
            result.append(Entry(path: path, size: expanded, compressedSize: compressedSize,
                offset: offset, crc: data.u32(cursor + 16), method: method, executable: mode & 0o111 != 0,
                flags: flags, centralOffset: start))
            cursor = next
        }
        guard cursor == end else { throw AppUpdateInstallError.invalidArchive }
        return result
    }

    /// 표준 ZIP CRC-32 다항식의 바이트 조회표
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        return crc
    }
}

private extension Data {
    /// 사전 검증 범위의 ZIP little-endian 16비트 값
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    /// 사전 검증 범위의 ZIP little-endian 32비트 값
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
}
