import AppKit
import SwiftUI

/// Main-actor loader supplied by the host. The section does not know how an
/// account home is resolved and therefore cannot cross account boundaries.
public typealias SessionActivityLoader = @MainActor (AccountState) async -> SessionActivitySnapshot
public typealias SessionActivitySnapshotSink = @MainActor @Sendable (SessionActivitySnapshot) async -> Void

/// Popover content for one account's local CLI/Codex App activity.
public struct CLIActivitySection: View {
    public static let loadingText = "활성 세션을 불러오는 중입니다…"
    public static let emptyText = "최근 15분간 활성 세션이 없습니다."
    public static let unavailableText = AppErrorCode.sessionRead.message("활성 세션을 불러올 수 없습니다.")
    /// Bounded refresh cadence while the account popover remains mounted.
    /// Loads are sequential, so a slow provider read cannot overlap another.
    public static let activityRefreshInterval: TimeInterval = 5
    /// Keep a busy account popover usable when many sessions are active.
    public static let cardListMaxHeight: CGFloat = 440
    public static let cardListAxis: Axis.Set = .vertical

    public let account: AccountState
    public let loadSessionActivity: SessionActivityLoader

    @State private var snapshot: SessionActivitySnapshot?
    @State private var isLoading = true
    @State private var collapsedSessionIDs: Set<String> = []
    @StateObject private var presentationModel: SessionActivityPresentationModel

    public init(
        account: AccountState,
        loadSessionActivity: @escaping SessionActivityLoader = { account in
            .unavailable(accountID: account.id)
        }
    ) {
        self.account = account
        self.loadSessionActivity = loadSessionActivity
        _presentationModel = StateObject(wrappedValue: SessionActivityPresentationModel())
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoading {
                activityContainer {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(Self.loadingText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let snapshot {
                snapshotContent(snapshot)
            }
        }
        .task(id: account.id) {
            isLoading = true
            snapshot = nil
            collapsedSessionIDs.removeAll()
            presentationModel.reset()

            await Self.refreshSnapshots(
                account: account,
                interval: Self.activityRefreshInterval,
                loader: loadSessionActivity,
                onSnapshot: { loaded in
                    guard !Task.isCancelled else { return }
                    snapshot = loaded
                    presentationModel.update(snapshot: loaded)
                    isLoading = false
                }
            )
        }
        .onReceive(presentationModel.$sessions) { sessions in
            let retainedIDs = Set(sessions.map(\.id))
            collapsedSessionIDs.formIntersection(retainedIDs)
        }
    }

    /// Keeps the full value available for copy while exposing only a short
    /// value in the popover. Raw session IDs are never rendered elsewhere.
    public static func shortSessionID(_ sessionID: String?) -> String {
        guard let sessionID, !sessionID.isEmpty else { return "—" }
        let prefix = String(sessionID.prefix(8))
        return sessionID.count > prefix.count ? "\(prefix)..." : prefix
    }

    public static func copyValue(for snapshot: SessionActivitySnapshot) -> String? {
        snapshot.sessionID
    }

    /// A recent root is considered active by the bounded provider even when
    /// no descendant edge supplies a status. Keep that contract visible as
    /// Working without claiming an external live-process heartbeat.
    public static func mainStatus(
        for item: SessionActivityPresentationItem
    ) -> SessionActivityStatus {
        if item.session.isActive, item.status == .unknown {
            return .working
        }
        return item.status
    }

    public static func mainStatusText(for item: SessionActivityPresentationItem) -> String {
        mainStatus(for: item).displayText
    }

    /// Formats only an observed activity timestamp. Missing metadata remains
    /// absent instead of being replaced with a fabricated time.
    public static func activityTimeText(
        for date: Date?,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("Hm")
        return formatter.string(from: date)
    }

    public static func shouldRenderRetainedSessions(
        snapshot: SessionActivitySnapshot,
        retainedSessionCount: Int
    ) -> Bool {
        guard retainedSessionCount > 0 else { return false }
        switch snapshot.state {
        case .available, .empty, .unavailable:
            return true
        }
    }

    public static func sessionRowLabel(for source: SessionActivitySource) -> String {
        source == .lastKnown ? "마지막 확인 세션" : "최근 세션"
    }

    public static func displayName(for agent: SessionActivityAgent) -> String {
        let normalized = agent.displayName
            .unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty || normalized == "Agent" ? "에이전트" : String(normalized.prefix(80))
    }

    /// 안전한 모델·추론 등급만 이름 옆 표시 문자열로 구성
    public static func modelMetadataText(model: String?, reasoningEffort: String?) -> String? {
        let model = SessionActivityMetadataSanitizer.modelIdentifier(model)
        let effort = SessionActivityMetadataSanitizer.reasoningEffort(reasoningEffort)
        let values = [model, effort].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: " ")
    }

    /// Small async seam used by tests with fake snapshots. SwiftUI's `.task`
    /// supplies cancellation when the popover disappears.
    public static func loadSnapshot(
        account: AccountState,
        loader: @escaping SessionActivityLoader
    ) async -> SessionActivitySnapshot {
        await loader(account)
    }

    /// Loads the initial snapshot and then refreshes sequentially until the
    /// host task is cancelled or the injected sleeper stops. The sink is
    /// called on the main actor for SwiftUI state updates.
    public static func refreshSnapshots(
        account: AccountState,
        interval: TimeInterval = activityRefreshInterval,
        loader: @escaping SessionActivityLoader,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        onSnapshot: @escaping SessionActivitySnapshotSink
    ) async {
        guard !Task.isCancelled else { return }

        let initial = await loader(account)
        guard !Task.isCancelled else { return }
        await onSnapshot(initial)

        while !Task.isCancelled {
            do {
                try await sleep(max(0, interval))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            let next = await loader(account)
            guard !Task.isCancelled else { return }
            await onSnapshot(next)
        }
    }

    @ViewBuilder
    private func activityContainer<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            }
    }

    @ViewBuilder
    private func snapshotContent(_ snapshot: SessionActivitySnapshot) -> some View {
        activityContainer {
            if Self.shouldRenderRetainedSessions(
                snapshot: snapshot,
                retainedSessionCount: presentationModel.sessions.count
            ) {
                ScrollView(Self.cardListAxis, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(
                            Array(presentationModel.sessions.enumerated()),
                            id: \.element.id
                        ) { index, item in
                            sessionContent(
                                item,
                                isLast: index == presentationModel.sessions.count - 1
                            )
                        }
                    }
                }
                .frame(maxHeight: Self.cardListMaxHeight)
            } else {
                switch snapshot.state {
                case .available, .empty:
                    Text(Self.emptyText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .unavailable:
                    Text(Self.unavailableText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func sessionContent(
        _ item: SessionActivityPresentationItem,
        isLast: Bool
    ) -> some View {
        let expanded = isSessionExpanded(item)

        VStack(alignment: .leading, spacing: 0) {
            sessionHeader(item, isExpanded: expanded)

            if let planStep = item.planStep {
                metadataRow(label: "진행 단계", value: planStep)
            }

            if let activeOperation = item.activeOperation {
                metadataRow(label: "현재 작업", value: Self.operationText(activeOperation))
            }

            if expanded && !item.agents.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(
                        Array(item.agents.enumerated()),
                        id: \.element.id
                    ) { index, agent in
                        agentContent(
                            agent,
                            isLast: index == item.agents.count - 1
                        )
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            if !isLast {
                Divider()
                    .padding(.leading, 24)
            }
        }
        .opacity(item.opacity)
        .animation(.easeOut(duration: 0.2), value: item.isDeparting)
        .animation(.easeOut(duration: 0.16), value: expanded)
    }

    private func sessionHeader(
        _ item: SessionActivityPresentationItem,
        isExpanded: Bool
    ) -> some View {
        let metadata = Self.modelMetadataText(model: item.session.model, reasoningEffort: item.session.reasoningEffort)
        return Button {
            toggleSession(item.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                    .accessibilityHidden(true)

                Circle()
                    .fill(Self.statusColor(for: Self.mainStatus(for: item)))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(Self.sessionTitle(item.title))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let metadata {
                            Text("(\(metadata))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: 4) {
                        Text(Self.shortSessionID(item.session.threadID))
                            .font(.caption2.monospaced())
                            .help(item.session.threadID)
                        Spacer(minLength: 4)
                        Text(Self.mainStatusText(for: item))
                        if let time = Self.activityTimeText(for: item.lastActivityAt) {
                            Text("·").foregroundStyle(.secondary)
                            Text(time)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.appDisclosure)
        .contextMenu {
            Button("세션 번호 복사") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.session.threadID, forType: .string)
            }
        }
        .help(sessionAccessibilityLabel(for: item))
        .accessibilityLabel(sessionAccessibilityLabel(for: item))
        .accessibilityValue(isExpanded ? "펼쳐짐" : "접힘")
        .accessibilityHint(item.agents.isEmpty ? "하위 에이전트 없음" : "하위 에이전트 펼치기 또는 접기")
    }

    @ViewBuilder
    private func agentContent(
        _ agent: SessionActivityAgent,
        isLast: Bool
    ) -> some View {
        let displayName = Self.displayName(for: agent)
        let taskName = Self.taskName(for: agent)
        let metadata = Self.modelMetadataText(model: agent.model, reasoningEffort: agent.reasoningEffort)
        let accessibilityLabels = [displayName] + (metadata.map { [$0] } ?? []) + [taskName]

        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(Self.statusColor(for: agent.status))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(displayName)
                        .font(.caption.weight(.semibold))
                    if let metadata {
                        Text("(\(metadata))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

                if taskName != displayName {
                    Text(taskName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 4)

            Text(agent.status.displayText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.leading, 24)
        .padding(.vertical, 4)
        .overlay(alignment: .leading) {
            SessionTreeConnector(isLast: isLast)
                .frame(width: 18)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabels.joined(separator: ", "))
        .accessibilityValue(agent.status.displayText)
    }

    private func isSessionExpanded(_ item: SessionActivityPresentationItem) -> Bool {
        !collapsedSessionIDs.contains(item.id)
    }

    private func toggleSession(_ id: String) {
        if collapsedSessionIDs.contains(id) {
            collapsedSessionIDs.remove(id)
        } else {
            collapsedSessionIDs.insert(id)
        }
    }

    private func sessionAccessibilityLabel(for item: SessionActivityPresentationItem) -> String {
        var values = [Self.sessionTitle(item.title)]
        if let metadata = Self.modelMetadataText(model: item.session.model, reasoningEffort: item.session.reasoningEffort) {
            values.append(metadata)
        }
        values.append(Self.shortSessionID(item.session.threadID))
        values.append(Self.mainStatusText(for: item))
        if let time = Self.activityTimeText(for: item.lastActivityAt) {
            values.append(time)
        }
        return values.joined(separator: ", ")
    }

    @ViewBuilder
    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.leading, 8)
    }

    public static func taskName(for agent: SessionActivityAgent) -> String {
        let normalized = agent.taskName
            .unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty || normalized == "Agent" ? "작업 정보 없음" : String(normalized.prefix(80))
    }

    /// 사용자 지정 제목을 보존하고 기본 세션 이름만 한국어로 표시
    private static func sessionTitle(_ title: String) -> String {
        title == "Codex session" ? "이름 없는 세션" : title
    }

    /// 내부 작업 종류의 화면 표시 문구 변환
    private static func operationText(_ operation: String) -> String {
        switch operation {
        case "Command": return "명령 실행"
        case "File change": return "파일 수정"
        case "Tool": return "도구 사용"
        case "Review": return "검토"
        case "Agent": return "에이전트 작업"
        default: return operation
        }
    }

    private static func statusColor(for status: SessionActivityStatus) -> Color {
        switch status {
        case .working:
            return Color(red: 0.30, green: 0.78, blue: 0.28)
        case .waiting:
            return Color(red: 1.00, green: 0.67, blue: 0.20)
        case .inactive, .unknown:
            return Color.secondary
        case .completed:
            return Color(red: 0.32, green: 0.78, blue: 0.38)
        case .stopped:
            return Color(red: 1.00, green: 0.58, blue: 0.18)
        case .error:
            return Color(red: 1.00, green: 0.28, blue: 0.26)
        }
    }
}

private struct SessionTreeConnector: View {
    let isLast: Bool

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let x = min(8, proxy.size.width / 2)
                let middle = proxy.size.height / 2

                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(
                    to: CGPoint(
                        x: x,
                        y: isLast ? middle : proxy.size.height
                    )
                )
                path.move(to: CGPoint(x: x, y: middle))
                path.addLine(to: CGPoint(x: proxy.size.width, y: middle))
            }
            .stroke(
                Color.secondary.opacity(0.34),
                style: StrokeStyle(lineWidth: 1, lineCap: .round)
            )
        }
        .frame(width: 18)
    }
}
