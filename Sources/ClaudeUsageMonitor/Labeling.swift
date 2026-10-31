import Foundation

/// Menu-bar text selection, kept pure so it's unit-testable without the Store.
///
/// Why adaptive: some tiers (e.g. Ultra, since 2026-10) have no 5-hour session window at
/// all, while others still do. The endpoint is the authority — we never hardcode which
/// tier has which window — so the label shows the best window that actually came back.
enum MenuBarText {
    struct Result: Equatable {
        let text: String
        /// Which window drives the label ("session", "weekly_all", a limit kind,
        /// or "loading" / "error" / "none") — surfaced by --selftest.
        let driver: String
    }

    /// Head-of-label preference, best first. Anything else falls back to the highest %.
    static let priority = ["session", "weekly_all"]

    static func make(usage: UsageResponse?, hasError: Bool) -> Result {
        guard let usage else {
            return hasError ? Result(text: "!", driver: "error") : Result(text: "…", driver: "loading")
        }
        let weekly = percent(for: "weekly_all", in: usage)

        if let session = percent(for: "session", in: usage) {
            let head = fmt(session)
            return Result(text: weekly.map { "\(head) · \(fmt($0))" } ?? head, driver: "session")
        }
        if let weekly { return Result(text: fmt(weekly), driver: "weekly_all") }
        if let top = usage.limits.filter({ !priority.contains($0.kind) }).max(by: { $0.percent < $1.percent }) {
            return Result(text: fmt(top.percent), driver: top.kind)
        }
        return Result(text: "—", driver: "none")
    }

    /// `limits[]` is authoritative; the top-level `five_hour` / `seven_day` blocks are the
    /// fallback when an older/alternate response shape omits the matching limit.
    static func percent(for kind: String, in usage: UsageResponse) -> Double? {
        switch kind {
        case "session":
            return usage.limits.first { $0.group == "session" }?.percent ?? usage.fiveHour?.utilization
        case "weekly_all":
            return usage.limits.first { $0.kind == "weekly_all" }?.percent ?? usage.sevenDay?.utilization
        default:
            return usage.limits.first { $0.kind == kind }?.percent
        }
    }

    private static func fmt(_ p: Double) -> String { "\(Int(p.rounded()))%" }
}

/// Subscription plan badge text for the popover header.
enum PlanBadge {
    /// Fallback names when the server omits `plan_display_name`. Team/Enterprise/Pro raw
    /// strings are unverified (no such account to probe) — unknown values fall through
    /// to a title-cased raw string, so a wrong guess still renders something.
    static let typeNames: [String: String] = [
        "claude_max": "Max",
        "claude_pro": "Pro",
        "claude_team": "Team",
        "claude_enterprise": "Enterprise",
    ]

    static func text(for org: Profile.Organization?) -> String? {
        guard let org else { return nil }
        let base: String? = nonEmpty(org.planDisplayName)
            ?? nonEmpty(org.organizationType).map { typeNames[$0] ?? titleCase($0) }
        guard let base else { return nil }
        if let seat = nonEmpty(org.seatTier) { return "\(base) · \(titleCase(seat))" }
        return base
    }

    static func titleCase(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("claude_") { s.removeFirst("claude_".count) }
        return s.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }
}
