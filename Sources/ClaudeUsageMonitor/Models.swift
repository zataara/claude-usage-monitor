import Foundation

// MARK: - Official usage endpoint (GET https://api.anthropic.com/api/oauth/usage)

/// Top-level response. We keep the raw `limits` array as the authoritative source
/// (render whatever comes back rather than hardcoding window kinds), and expose the
/// convenience `five_hour` / `seven_day` blocks for the compact menu-bar label.
struct UsageResponse: Decodable {
    let fiveHour: Window?
    let sevenDay: Window?
    let limits: [UsageLimit]
    let extraUsage: ExtraUsage?
    let spend: Spend?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case limits
        case extraUsage = "extra_usage"
        case spend
    }

    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: Date?
        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }
}

/// One rate-limit window. `group` is "session" | "weekly"; `kind` is the specific
/// window ("session", "weekly_all", "weekly_scoped"). `scope.model` names the model
/// for per-model weekly caps.
struct UsageLimit: Decodable, Identifiable {
    let kind: String
    let group: String
    let percent: Double
    let severity: String
    let resetsAt: Date?
    let scope: Scope?
    let isActive: Bool

    var id: String { kind + "/" + (scope?.model?.displayName ?? "") }

    enum CodingKeys: String, CodingKey {
        case kind, group, percent, severity
        case resetsAt = "resets_at"
        case scope
        case isActive = "is_active"
    }

    struct Scope: Decodable {
        let model: ModelRef?
        struct ModelRef: Decodable {
            let displayName: String?
            enum CodingKeys: String, CodingKey { case displayName = "display_name" }
        }
    }

    /// Human label for the bar. Weekly-scoped windows show the model name.
    var title: String {
        switch kind {
        case "session": return "5-hour session"
        case "weekly_all": return "Weekly (all models)"
        case "weekly_scoped":
            if let m = scope?.model?.displayName { return "Weekly · \(m)" }
            return "Weekly (scoped)"
        default:
            return kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Overage credit pool that covers you past plan limits.
struct ExtraUsage: Decodable {
    let isEnabled: Bool
    let monthlyLimit: Double?   // minor units? endpoint reports 10000 == $100.00
    let usedCredits: Double?
    let utilization: Double?
    let currency: String?
    let decimalPlaces: Int?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization, currency
        case decimalPlaces = "decimal_places"
    }
}

/// Credit spend against the overage cap (money in minor units).
struct Spend: Decodable {
    let used: Money?
    let limit: Money?
    let percent: Double?
    let enabled: Bool?

    struct Money: Decodable {
        let amountMinor: Int?
        let currency: String?
        let exponent: Int?
        enum CodingKeys: String, CodingKey {
            case amountMinor = "amount_minor"
            case currency, exponent
        }
        var dollars: Double {
            Double(amountMinor ?? 0) / pow(10.0, Double(exponent ?? 2))
        }
    }
}

// MARK: - Profile endpoint (GET https://api.anthropic.com/api/oauth/profile)

/// Only the plan fields are modeled. The response also carries account PII (name, email,
/// uuids) which we deliberately never decode or hold.
struct Profile: Decodable {
    let organization: Organization?

    struct Organization: Decodable {
        let planDisplayName: String?    // server-authored, e.g. "Ultra"
        let organizationType: String?   // e.g. "claude_max"
        let rateLimitTier: String?      // e.g. "default_claude_max_20x"
        let seatTier: String?           // Team/Enterprise seat level; nil for personal plans

        enum CodingKeys: String, CodingKey {
            case planDisplayName = "plan_display_name"
            case organizationType = "organization_type"
            case rateLimitTier = "rate_limit_tier"
            case seatTier = "seat_tier"
        }
    }
}

// MARK: - ccusage (npx ccusage blocks --active --json) — the rich detail layer

struct CCUsage: Decodable {
    let blocks: [Block]

    struct Block: Decodable {
        let isActive: Bool
        let startTime: Date?
        let endTime: Date?
        let totalTokens: Double?
        let costUSD: Double?
        let tokenCounts: Tokens?
        let burnRate: BurnRate?
        let projection: Projection?
    }

    struct Tokens: Decodable {
        let inputTokens: Double?
        let outputTokens: Double?
        let cacheCreationInputTokens: Double?
        let cacheReadInputTokens: Double?
    }

    struct BurnRate: Decodable {
        let tokensPerMinute: Double?
        let costPerHour: Double?
    }

    struct Projection: Decodable {
        let totalTokens: Double?
        let totalCost: Double?
        let remainingMinutes: Double?
    }

    var active: Block? { blocks.first(where: { $0.isActive }) ?? blocks.first }
}

// MARK: - Errors

enum AppError: LocalizedError {
    case keychain(String)
    case http(Int)
    case rateLimited(retryAfter: TimeInterval?)
    case ccusage(String)

    var errorDescription: String? {
        switch self {
        case .keychain(let m): return "Keychain: \(m)"
        case .http(401): return "Auth expired — open Claude Code to refresh, then retry."
        case .http(let c): return "Usage API returned HTTP \(c)."
        case .rateLimited: return "Rate-limited by the usage API — retrying shortly."
        case .ccusage(let m): return "ccusage: \(m)"
        }
    }
}

// MARK: - Shared JSON decoder (lenient ISO-8601 with fractional seconds + offset)

enum JSON {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let dt = parseISO(s) { return dt }
            throw DecodingError.dataCorrupted(.init(
                codingPath: dec.codingPath,
                debugDescription: "Unparseable date: \(s)"))
        }
        return d
    }()

    /// Lenient ISO-8601 parse: the usage endpoint emits 6-digit fractional seconds
    /// with a numeric offset. Formatters are built per call (decode is cold, a few
    /// dates per refresh) to avoid sharing non-Sendable ISO8601DateFormatter state.
    private static func parseISO(_ s: String) -> Date? {
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let dt = frac.date(from: s) { return dt }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}
