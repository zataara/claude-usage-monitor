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

    /// Subscription plan badge ("Ultra", "Team · Premium"); nil until a profile fetch succeeds.
    var plan: String?
    var planError: String?
    private var planFetchedAt: Date?
    /// Plan metadata changes rarely; refetch at most this often outside manual refresh.
    private static let planMaxAge: TimeInterval = 6 * 3600

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

    /// `autostart: false` gives tests a Store with no network fetch and no timers.
    init(autostart: Bool = true) {
        let saved = UserDefaults.standard.integer(forKey: Self.intervalKey)
        intervalMinutes = saved == 0 ? 5 : saved
        guard autostart else { return }
        Task { await refresh() }
        scheduleTimer()
    }

    // MARK: Derived values for the compact menu-bar label

    /// Text beside the Claude mark in the menu bar — see `MenuBarText` for the rules.
    var menuBarText: String {
        MenuBarText.make(usage: usage, hasError: usageError != nil).text
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

    /// `manual` (the popover button / first launch) also refetches the plan badge;
    /// timer ticks refetch it only once it's older than `planMaxAge`.
    func refresh(manual: Bool = true) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Fetch both sources concurrently; ccusage is best-effort (detail only).
        async let usageResult = UsageAPI.fetch()
        async let blockResult = try? CCUsageSource.fetch()
        let wantPlan = manual || planFetchedAt.map { Date().timeIntervalSince($0) > Self.planMaxAge } ?? true
        async let planResult: Result<Profile, Error>? = wantPlan ? Self.fetchPlan() : nil

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
        if let r = await planResult { applyPlan(r) }
        lastRefresh = Date()
    }

    private nonisolated static func fetchPlan() async -> Result<Profile, Error> {
        do { return .success(try await ProfileAPI.fetch()) } catch { return .failure(error) }
    }

    /// Plan failures never touch `usageError`: the badge is decoration, usage is the job.
    /// Keep the last good badge on failure; record why for --selftest / debugging.
    func applyPlan(_ result: Result<Profile, Error>) {
        switch result {
        case .success(let profile):
            plan = PlanBadge.text(for: profile.organization)
            planError = plan == nil ? "profile has no plan fields" : nil
            planFetchedAt = Date()
        case .failure(let error):
            planError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// One-shot retry after a 429, honoring `Retry-After` clamped to `retryBounds`.
    /// Separate from the repeating timer so it doesn't disturb the normal cadence.
    private func scheduleRetry(after retryAfter: TimeInterval?) {
        let delay = min(max(retryAfter ?? Self.retryBounds.lowerBound,
                            Self.retryBounds.lowerBound), Self.retryBounds.upperBound)
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.refresh(manual: false) }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let seconds = TimeInterval(max(1, intervalMinutes) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(manual: false) }
        }
    }
}
