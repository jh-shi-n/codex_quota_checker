import Foundation

public typealias RefreshAction = @MainActor @Sendable () async -> Void
public typealias RefreshSleep = @Sendable (TimeInterval) async -> Void

/// Keeps refresh callback serialization and loop state outside the service
/// owner. The loop therefore cannot retain `RefreshService` through its task.
actor RefreshLoopGate {
    private let refreshAction: RefreshAction
    private let sleep: RefreshSleep
    private var activeGeneration = 0
    private var isRefreshing = false
    private var pendingManualRefresh = false
    private var refreshCompletionWaiters: [CheckedContinuation<Void, Never>] = []

    init(refreshAction: @escaping RefreshAction, sleep: @escaping RefreshSleep) {
        self.refreshAction = refreshAction
        self.sleep = sleep
    }

    /// Accepts a generation only when it is not older than the actor's
    /// current generation. The monotonic check protects a newer loop from
    /// delayed tasks created by an older start/stop cycle.
    func activate(generation: Int) -> Bool {
        guard generation >= activeGeneration else { return false }
        if generation > activeGeneration {
            activeGeneration = generation
            pendingManualRefresh = false
        }
        return true
    }

    /// Queues a manual refresh only for the current or a newer generation.
    /// A stale request is explicitly rejected and cannot rewind loop state.
    func requestManual(generation: Int) async -> Bool {
        guard activate(generation: generation) else { return false }
        pendingManualRefresh = true
        guard !isRefreshing else { return true }
        await drainManualRefreshes(generation: generation)
        return true
    }

    /// Marks a stop generation without allowing a delayed older stop to
    /// disable a newer loop.
    func stop(generation: Int) -> Bool {
        guard activate(generation: generation) else { return false }
        pendingManualRefresh = false
        return true
    }

    func run(generation: Int, intervalSeconds: TimeInterval, skipImmediate: Bool = false) async -> Bool {
        guard activate(generation: generation), activeGeneration == generation else {
            return false
        }
        if !skipImmediate { await performScheduledRefresh(generation: generation) }

        while !Task.isCancelled {
            await sleep(intervalSeconds)
            guard !Task.isCancelled, activeGeneration == generation else { return false }
            await performScheduledRefresh(generation: generation)
        }
        return false
    }

    private func performScheduledRefresh(generation: Int) async {
        guard activeGeneration == generation else { return }

        // A restart can activate this generation while the previous callback
        // is still in flight. Wait for that callback to finish instead of
        // entering the new interval sleep with the immediate refresh lost.
        while isRefreshing {
            await waitForRefreshCompletion()
            guard !Task.isCancelled, activeGeneration == generation else { return }
        }

        // The scheduled refresh is itself the immediate work requested by a
        // restart. Consume any manual request coalesced while waiting so the
        // handoff produces one callback rather than a duplicate pair.
        pendingManualRefresh = false
        isRefreshing = true
        await refreshAction()
        finishRefresh()
        if pendingManualRefresh, activeGeneration == generation {
            await drainManualRefreshes(generation: generation)
        }
    }

    private func waitForRefreshCompletion() async {
        await withCheckedContinuation { continuation in
            refreshCompletionWaiters.append(continuation)
        }
    }

    private func finishRefresh() {
        isRefreshing = false
        let waiters = refreshCompletionWaiters
        refreshCompletionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func drainManualRefreshes(generation: Int) async {
        while pendingManualRefresh && !isRefreshing && activeGeneration == generation {
            pendingManualRefresh = false
            isRefreshing = true
            await refreshAction()
            finishRefresh()
        }
    }
}

/// Owns exactly one cancellable automatic refresh loop.
@MainActor
public final class RefreshService {
    nonisolated public static let quickIntervalPresets = [1, 5, 10, 30]
    nonisolated public static let supportedIntervalMinutes = quickIntervalPresets
    nonisolated public static let minimumIntervalMinutes = 1
    nonisolated public static let maximumIntervalMinutes = 60
    nonisolated public static let defaultIntervalMinutes = 5
    nonisolated public static let allowedIntervals = quickIntervalPresets

    public private(set) var intervalMinutes: Int
    public private(set) var isRunning = false
    public var refreshIntervalMinutes: Int { intervalMinutes }

    private let loopGate: RefreshLoopGate
    private var loopTask: Task<Void, Never>?
    private var generation = 0

    public init(
        intervalMinutes: Int = 5,
        sleep: @escaping RefreshSleep = RefreshService.defaultSleep,
        refresh: @escaping RefreshAction
    ) {
        self.intervalMinutes = Self.normalizedIntervalMinutes(intervalMinutes)
        self.loopGate = RefreshLoopGate(refreshAction: refresh, sleep: sleep)
    }

    deinit {
        loopTask?.cancel()
    }

    nonisolated public static func normalizedIntervalMinutes(_ minutes: Int) -> Int {
        guard minutes > 0 else { return defaultIntervalMinutes }
        return min(max(minutes, minimumIntervalMinutes), maximumIntervalMinutes)
    }

    /// Starts a fresh loop and performs one immediate refresh.
    public func start(skipImmediate: Bool = false) {
        stop()
        generation += 1
        let currentGeneration = generation
        let intervalSeconds = TimeInterval(intervalMinutes * 60)
        let gate = loopGate
        isRunning = true
        loopTask = Task { [gate] in
            guard await gate.activate(generation: currentGeneration) else { return }
            _ = await gate.run(generation: currentGeneration, intervalSeconds: intervalSeconds, skipImmediate: skipImmediate)
        }
    }

    /// Cancels automatic refresh and prevents a cancelled loop from acting
    /// after a later restart.
    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        generation += 1
        let stopGeneration = generation
        let gate = loopGate
        Task { [gate] in
            _ = await gate.stop(generation: stopGeneration)
        }
        isRunning = false
    }

    /// Updates the interval and starts a new immediate-refresh loop.
    public func restart(intervalMinutes: Int? = nil) {
        if let intervalMinutes {
            self.intervalMinutes = Self.normalizedIntervalMinutes(intervalMinutes)
        }
        start()
    }

    /// 주기 조회 OFF 상태에서도 다음 시작에 적용할 간격 변경
    public func updateInterval(minutes: Int) {
        intervalMinutes = Self.normalizedIntervalMinutes(minutes)
    }

    /// Performs an immediate manual refresh. A request arriving during an
    /// in-flight refresh is coalesced and runs once after the current request;
    /// no refresh callbacks overlap.
    public func refreshNow() async {
        _ = await loopGate.requestManual(generation: generation)
    }

    public static func defaultSleep(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        let nanoseconds = UInt64(min(seconds, Double(UInt64.max) / 1_000_000_000) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}
