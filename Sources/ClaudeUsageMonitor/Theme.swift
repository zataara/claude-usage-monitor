import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Claude-flavored palette, resolved for the current color scheme.
struct Palette {
    let scheme: ColorScheme

    // Brand
    var clay: Color { Color(hex: 0xD97757) }       // Claude coral/clay — primary fill
    var amber: Color { Color(hex: 0xE0A458) }      // caution
    var red: Color { Color(hex: 0xC4453C) }        // critical / throttle imminent
    var green: Color { Color(hex: 0x5FA36F) }      // "on pace / on target" (fuller = better)

    // Surfaces & text (warm neutrals, scheme-aware)
    var text: Color { scheme == .dark ? Color(hex: 0xF5F1EB) : Color(hex: 0x2B2622) }
    var subtle: Color { text.opacity(0.55) }
    var track: Color { scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08) }
    var card: Color { scheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.035) }
    var hairline: Color { scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06) }

    /// Fill color for a limit bar.
    /// - Session (5h): filling is fine, but the one bad outcome is hitting the wall
    ///   mid-task, so escalate by severity/percent.
    /// - Weekly: the *goal* is to fill it — color by whether you're on pace to reach
    ///   100% before reset (green = on/ahead of pace, clay = behind, "use more").
    func fill(for limit: UsageLimit) -> Color {
        switch limit.severity.lowercased() {
        case "critical", "exceeded", "blocked": return red
        case "warning", "warn", "high": return amber
        default: break
        }
        if limit.group == "weekly" {
            return onPace(limit) ? green : clay
        }
        // session, normal severity
        return limit.percent >= 90 ? amber : clay
    }

    /// True when weekly utilization is at least as far along as the elapsed fraction
    /// of the 7-day window (i.e. you're tracking toward full consumption).
    func onPace(_ limit: UsageLimit) -> Bool {
        guard limit.group == "weekly", let reset = limit.resetsAt else { return false }
        let start = reset.addingTimeInterval(-7 * 24 * 3600)
        let elapsed = Date().timeIntervalSince(start)
        let frac = max(0, min(1, elapsed / (7 * 24 * 3600)))
        return limit.percent >= frac * 100
    }
}

// MARK: - Formatting helpers

enum Fmt {
    static func compactCount(_ n: Double) -> String {
        let v = abs(n)
        switch v {
        case 1_000_000...: return String(format: "%.1fM", n / 1_000_000)
        case 1_000...: return String(format: "%.1fk", n / 1_000)
        default: return String(format: "%.0f", n)
        }
    }

    static func dollars(_ n: Double) -> String { String(format: "$%.2f", n) }

    /// "1h 17m", "8m", "0m"
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func resetsIn(_ date: Date?) -> String {
        guard let date else { return "—" }
        let dt = date.timeIntervalSinceNow
        return dt <= 0 ? "resetting…" : "resets in \(duration(dt))"
    }

    static func agoShort(_ date: Date?) -> String {
        guard let date else { return "never" }
        let s = -date.timeIntervalSinceNow
        if s < 60 { return "just now" }
        return "\(Int(s / 60))m ago"
    }
}
