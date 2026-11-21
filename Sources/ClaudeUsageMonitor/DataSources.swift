import Foundation

// MARK: - Keychain (reuses the proven `security` CLI path)

/// Reads the current Claude Code OAuth access token from the login keychain.
/// We shell out to `/usr/bin/security` (the exact path that works interactively)
/// rather than SecItem so the app inherits the same ACL prompt/allow flow.
/// Read fresh on every poll — never cached — so the CLI's token refresh (which
/// `CLIRefresher` triggers) is picked up on the next read.
struct Credential: Sendable {
    let accessToken: String
    /// `claudeAiOauth.expiresAt` (epoch ms); nil when the item doesn't carry it.
    let expiresAt: Date?
}

enum Keychain {
    private struct Creds: Decodable {
        let claudeAiOauth: OAuth
        struct OAuth: Decodable { let accessToken: String; let expiresAt: Double? }
    }

    static func claudeCredential() throws -> Credential {
        let out = try Shell.run(
            "/usr/bin/security",
            ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        )
        guard !out.isEmpty else {
            throw AppError.keychain("no Claude Code credentials found")
        }
        do {
            let o = try JSONDecoder().decode(Creds.self, from: Data(out.utf8)).claudeAiOauth
            return Credential(accessToken: o.accessToken,
                              expiresAt: o.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) })
        } catch {
            throw AppError.keychain("unexpected credential format")
        }
    }
}

// MARK: - Official OAuth endpoints (usage + profile)

/// Shared authenticated GET against api.anthropic.com's OAuth surface. The token is read
/// fresh per call and only ever placed in this request's header.
enum OAuthAPI {
    static let base = URL(string: "https://api.anthropic.com/api/oauth/")!
    private static let beta = "oauth-2025-04-20"

    /// `session` / `credential` / `refresher` are injectable so tests can stub the network, the keychain
    /// and the CLI; production always uses the defaults.
    ///
    /// Auth: refresh first when the token is near expiry, and once more on a 401. When that refresh doesn't
    /// throw (`.refreshed` or `.notNeeded`), the request is re-sent once with a re-read token. A 401 that
    /// survives the retry is `.reauthRequired(.tokenNotExtended)`.
    static func get<T: Decodable>(
        _ path: String,
        as: T.Type,
        session: URLSession = .shared,
        credential: @Sendable @escaping () throws -> Credential = { try Keychain.claudeCredential() },
        refresher: CLIRefresher = .shared
    ) async throws -> T {
        let read = { try await Task.detached { try credential() }.value }
        var cred = try await read()
        if CLIRefresher.needsPreflight(expiresAt: cred.expiresAt) {
            try await refresher.refresh()
            cred = try await read()
        }
        do {
            return try await send(path, as: T.self, session: session, token: cred.accessToken)
        } catch AppError.http(401) {
            try await refresher.refresh()
            cred = try await read()
            do {
                return try await send(path, as: T.self, session: session, token: cred.accessToken)
            } catch AppError.http(401) {
                throw AppError.reauthRequired(.tokenNotExtended)
            }
        }
    }

    /// Token-only overload kept for tests that don't exercise refresh: a credential with no expiry and a
    /// refresher whose CLI run never extends it.
    static func get<T: Decodable>(
        _ path: String,
        as: T.Type,
        session: URLSession = .shared,
        token tokenProvider: @Sendable @escaping () throws -> String
    ) async throws -> T {
        try await get(path, as: T.self, session: session,
                      credential: { Credential(accessToken: try tokenProvider(), expiresAt: nil) },
                      refresher: CLIRefresher(runner: { _, _ in .exited(0) }, expiry: { nil }))
    }

    private static func send<T: Decodable>(
        _ path: String, as: T.Type, session: URLSession, token: String
    ) async throws -> T {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(beta, forHTTPHeaderField: "anthropic-beta")

        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? -1
        guard code == 200 else {
            // 429 is transient (shared rolling limit across OAuth clients; common on
            // wake). Surface the server's Retry-After so we back off instead of hammering.
            if code == 429 {
                let ra = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                throw AppError.rateLimited(retryAfter: ra)
            }
            throw AppError.http(code)
        }
        return try JSON.decoder.decode(T.self, from: data)
    }
}

enum UsageAPI {
    static func fetch() async throws -> UsageResponse {
        try await OAuthAPI.get("usage", as: UsageResponse.self)
    }
}

/// Plan/tier metadata. Changes rarely, so the Store polls it on a slow cadence.
enum ProfileAPI {
    static func fetch() async throws -> Profile {
        try await OAuthAPI.get("profile", as: Profile.self)
    }
}

// MARK: - ccusage (detail layer)

enum CCUsageSource {
    /// Runs through a login shell so the GUI app resolves the same PATH as the
    /// terminal (ccusage + node live in /opt/homebrew/bin). stdout is clean JSON;
    /// ccusage's informational lines go to stderr and are discarded.
    static func fetch() async throws -> CCUsage.Block? {
        let out = try await Task.detached {
            try Shell.run("/bin/zsh", ["-lc", "ccusage blocks --active --json"])
        }.value
        guard let data = out.data(using: .utf8), !data.isEmpty else {
            throw AppError.ccusage("no output")
        }
        return try JSON.decoder.decode(CCUsage.self, from: data).active
    }
}

// MARK: - Process helper

enum Shell {
    /// Runs a command, returns stdout as UTF-8. Throws on non-zero exit.
    static func run(_ launchPath: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()   // discard
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw AppError.ccusage("exit \(p.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
