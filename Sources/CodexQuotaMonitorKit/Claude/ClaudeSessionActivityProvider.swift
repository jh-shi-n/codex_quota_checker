import Darwin
import Foundation

/// Reads Claude Code's small live session descriptors, never conversation JSONL or key files.
public actor ClaudeSessionActivityProvider: SessionActivityProvider {
    public static let maximumFileBytes = 64 * 1_024
    public static let maximumSessionCount = 64
    public static let recentActivityWindow: TimeInterval = 15 * 60

    private let now: @Sendable () -> Date
    private let isProcessAlive: @Sendable (Int32) -> Bool
    private var homes: [URL: [String: Record]] = [:]

    private struct Descriptor: Decodable {
        let pid: Int32
        let sessionId: String
        let name: String?
        let status: String?
        let startedAt: Double?
        let statusUpdatedAt: Double?
        let updatedAt: Double?
        let pidDomain: String?
    }

    private struct Record {
        let sessionID: String
        let pid: Int32
        let startedAt: Double?
        let title: String
        let rawStatus: String
        let status: SessionActivityStatus
        let turnID: String
        let eventAt: Date
        let lastActivityAt: Date
        let isProcessAlive: Bool
    }

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        isProcessAlive: @escaping @Sendable (Int32) -> Bool = { pid in
            guard pid > 0 else { return false }
            return kill(pid, 0) == 0 || errno == EPERM
        }
    ) {
        self.now = now
        self.isProcessAlive = isProcessAlive
    }

    public func snapshot(accountID: String, home: URL) async -> SessionActivitySnapshot {
        guard home.isFileURL, !Task.isCancelled else { return .unavailable(accountID: accountID) }
        let canonicalHome = home.standardizedFileURL.resolvingSymlinksInPath()
        let root = canonicalHome.appendingPathComponent("sessions").resolvingSymlinksInPath()
        let observedAt = now()
        let previous = homes[canonicalHome] ?? [:]
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])
                .filter { $0.pathExtension == "json" }
                .sorted {
                    let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return lhs == rhs ? $0.lastPathComponent < $1.lastPathComponent : lhs > rhs
                }
        } catch {
            // Missing metadata is not evidence that an in-progress response completed.
            return .unavailable(accountID: accountID)
        }
        var records: [String: Record] = [:]
        var unreadable = false
        for file in files.prefix(Self.maximumSessionCount) {
            guard !Task.isCancelled else { return .unavailable(accountID: accountID) }
            let resolved = file.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root.path + "/"),
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= Self.maximumFileBytes else { continue }
            do {
                let descriptorFD = open(resolved.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                guard descriptorFD >= 0 else { unreadable = true; continue }
                let handle = FileHandle(fileDescriptor: descriptorFD, closeOnDealloc: true)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
                guard data.count <= Self.maximumFileBytes else { continue }
                let descriptor = try JSONDecoder().decode(Descriptor.self, from: data)
                guard UUID(uuidString: descriptor.sessionId) != nil,
                      descriptor.pid > 0,
                      file.deletingPathExtension().lastPathComponent == String(descriptor.pid),
                      descriptor.pidDomain == nil || descriptor.pidDomain == "darwin" else { continue }
                let old = previous[descriptor.sessionId].flatMap {
                    $0.pid == descriptor.pid && $0.startedAt == descriptor.startedAt ? $0 : nil
                }
                let alive = isProcessAlive(descriptor.pid)
                // Stale files present at app startup must never become new completion events.
                guard alive || old != nil else { continue }
                let eventAt = Self.date(descriptor.statusUpdatedAt ?? descriptor.updatedAt)
                    ?? values.contentModificationDate ?? observedAt
                guard eventAt <= observedAt.addingTimeInterval(30) else { continue }
                let record = Self.project(descriptor, previous: old, alive: alive,
                                          eventAt: eventAt, observedAt: observedAt)
                records[descriptor.sessionId] = record
            } catch {
                unreadable = true
            }
        }
        // Preserve partial-write descriptors. Recovery must not replay a fabricated finish.
        if unreadable { return .unavailable(accountID: accountID) }
        let presentNames = Set(files.map(\.lastPathComponent))
        for (id, old) in previous where records[id] == nil {
            guard old.isProcessAlive || old.lastActivityAt.addingTimeInterval(Self.recentActivityWindow) > observedAt else { continue }
            if presentNames.contains("\(old.pid).json"), !records.values.contains(where: { $0.pid == old.pid }) {
                return .unavailable(accountID: accountID)
            }
            if old.isProcessAlive {
                // Disappearance is a session exit/interruption, not a successful model response.
                records[id] = Record(sessionID: id, pid: old.pid, startedAt: old.startedAt, title: old.title,
                                     rawStatus: "exited", status: .stopped, turnID: old.turnID,
                                     eventAt: observedAt, lastActivityAt: observedAt, isProcessAlive: false)
            } else {
                records[id] = old
            }
        }
        records = records.filter { $0.value.isProcessAlive || $0.value.lastActivityAt.addingTimeInterval(Self.recentActivityWindow) > observedAt }
        if records.count > Self.maximumSessionCount {
            let recent = records.values.sorted {
                if $0.isProcessAlive != $1.isProcessAlive { return $0.isProcessAlive }
                return $0.lastActivityAt > $1.lastActivityAt
            }.prefix(Self.maximumSessionCount)
            records = Dictionary(uniqueKeysWithValues: recent.map { ($0.sessionID, $0) })
        }
        if homes[canonicalHome] == nil, homes.count >= 8 { homes.removeAll() }
        homes[canonicalHome] = records
        let sessions = SessionActivityMainSession.ordered(records.values.map { record in
            SessionActivityMainSession(threadID: record.sessionID, source: .localActivity,
                                       taskName: record.title, status: record.status, agents: [],
                                       isActive: record.isProcessAlive && record.status != .unknown,
                                       lastActivityAt: record.lastActivityAt,
                                       turnID: record.turnID, turnEventAt: record.eventAt)
        })
        return SessionActivitySnapshot(accountID: accountID, state: .available, sessions: sessions)
    }

    private static func project(_ descriptor: Descriptor, previous: Record?, alive: Bool,
                                eventAt: Date, observedAt: Date) -> Record {
        let raw = descriptor.status?.lowercased() ?? "unknown"
        let title = SessionActivityMetadataSanitizer.text(descriptor.name) ?? previous?.title ?? "Claude session"
        var status: SessionActivityStatus
        var turnID = previous?.turnID ?? "\(descriptor.sessionId):\(eventAt.timeIntervalSince1970)"
        var effectiveEventAt = eventAt
        if !alive {
            status = previous?.isProcessAlive == true ? .stopped : (previous?.status ?? .unknown)
            effectiveEventAt = previous?.isProcessAlive == true ? observedAt : (previous?.eventAt ?? eventAt)
        } else {
            switch raw {
            case "busy", "working", "running":
                status = .working
                if previous == nil || previous?.rawStatus == "idle" || previous?.status.isOpen == false {
                    turnID = "\(descriptor.sessionId):\(eventAt.timeIntervalSince1970)"
                }
            case "idle":
                if let previous, previous.rawStatus != raw || eventAt > previous.eventAt {
                    status = .completed
                    if previous.rawStatus == "idle" { turnID = "\(descriptor.sessionId):\(eventAt.timeIntervalSince1970)" }
                } else {
                    status = previous?.status ?? .waiting
                }
            case "waiting", "waiting_for_input", "waiting_for_approval", "permission_required": status = .waiting
            case "completed", "done": status = .completed
            case "stopped", "interrupted", "exited": status = .stopped
            case "error", "failed": status = .error
            default: status = .unknown
            }
        }
        return Record(sessionID: descriptor.sessionId, pid: descriptor.pid, startedAt: descriptor.startedAt,
                      title: title, rawStatus: raw, status: status, turnID: turnID,
                      eventAt: effectiveEventAt, lastActivityAt: effectiveEventAt, isProcessAlive: alive)
    }

    private static func date(_ timestamp: Double?) -> Date? {
        guard let timestamp, timestamp.isFinite, timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp > 100_000_000_000 ? timestamp / 1_000 : timestamp)
    }
}
