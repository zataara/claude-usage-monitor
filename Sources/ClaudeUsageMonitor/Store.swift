import Foundation
import Observation

@MainActor
@Observable
final class Store {
    var usage: UsageResponse?
    var block: CCUsage.Block?
    var lastRefresh: Date?
    var usageError: String?
    var isRefreshing = false

    /// Background auto-refresh cadence in minutes (persisted).
    var intervalMinutes: Int {
        didSet {
            UserDefaults.standard.set(intervalMinutes, forKey: Self.intervalKey)
            scheduleTimer()
        }
    }

    private var timer: Timer?
    private var retryTimer: Timer?
    private static let intervalKey = "refreshIntervalMinutes"

    /// Bounds for honoring a 429 `Retry-After` (seconds): don't retry faster than
    /// this, don't wait absurdly long before the next attempt.
    private static let retryBounds: ClosedRange<TimeInterval> = 30...300

    init() {
        let saved = UserDefaults.standard.integer(forKey: Self.intervalKey)
        intervalMinutes = saved == 0 ? 5 : saved
        Task { await refresh() }
        scheduleTimer()
    }

    // MARK: Derived values for the compact menu-bar label

    var sessionPercent: Double? {
        usage?.limits.first { $0.group == "session" }?.percent ?? usage?.fiveHour?.utilization
    }

    var weeklyPercent: Double? {
        usage?.limits.first { $0.kind == "weekly_all" }?.percent ?? usage?.sevenDay?.utilization
    }

    /// Text beside the Claude mark in the menu bar. "66% · 21%" = 5-hour · weekly.
    var menuBarText: String {
        guard let s = sessionPercent else {
            return usageError == nil ? "…" : "!"
        }
        let head = "\(Int(s.rounded()))%"
        if let w = weeklyPercent { return "\(head) · \(Int(w.rounded()))%" }
        return head
    }

    /// Limits sorted for display: session first, then weekly windows.
    var sortedLimits: [UsageLimit] {
        (usage?.limits ?? []).sorted { a, b in
            func rank(_ l: UsageLimit) -> Int {
                switch l.kind {
                case "session": return 0
                case "weekly_all": return 1
                case "weekly_scoped": return 2
                default: return 3
                }
            }
            return rank(a) < rank(b)
        }
    }

    // MARK: Refresh

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Fetch both sources concurrently; ccusage is best-effort (detail only).
        async let usageResult = UsageAPI.fetch()
        async let blockResult = try? CCUsageSource.fetch()

        do {
            usage = try await usageResult
            usageError = nil
            retryTimer?.invalidate()   // recovered
        } catch let AppError.rateLimited(retryAfter) {
            // Transient: keep last-good data on screen. Only surface a message when we
            // have nothing to show yet. Either way, back off and retry once.
            if usage == nil {
                usageError = AppError.rateLimited(retryAfter: retryAfter).errorDescription
            }
            scheduleRetry(after: retryAfter)
        } catch {
            usageError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        block = await blockResult ?? block   // keep last good block on failure
        lastRefresh = Date()
    }

    /// One-shot retry after a 429, honoring `Retry-After` clamped to `retryBounds`.
    /// Separate from the repeating timer so it doesn't disturb the normal cadence.
    private func scheduleRetry(after retryAfter: TimeInterval?) {
        let delay = min(max(retryAfter ?? Self.retryBounds.lowerBound,
                            Self.retryBounds.lowerBound), Self.retryBounds.upperBound)
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let seconds = TimeInterval(max(1, intervalMinutes) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }
}
