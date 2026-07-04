import Foundation

// MARK: - Keychain (reuses the proven `security` CLI path)

/// Reads the current Claude Code OAuth access token from the login keychain.
/// We shell out to `/usr/bin/security` (the exact path that works interactively)
/// rather than SecItem so the app inherits the same ACL prompt/allow flow.
/// Read fresh on every poll — never cached — so Claude Code's own token refresh
/// keeps us valid.
enum Keychain {
    private struct Creds: Decodable {
        let claudeAiOauth: OAuth
        struct OAuth: Decodable { let accessToken: String }
    }

    static func claudeAccessToken() throws -> String {
        let out = try Shell.run(
            "/usr/bin/security",
            ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        )
        guard !out.isEmpty else {
            throw AppError.keychain("no Claude Code credentials found")
        }
        do {
            return try JSONDecoder().decode(Creds.self, from: Data(out.utf8)).claudeAiOauth.accessToken
        } catch {
            throw AppError.keychain("unexpected credential format")
        }
    }
}

// MARK: - Official usage endpoint

enum UsageAPI {
    private static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let beta = "oauth-2025-04-20"

    static func fetch() async throws -> UsageResponse {
        let token = try await Task.detached { try Keychain.claudeAccessToken() }.value

        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(beta, forHTTPHeaderField: "anthropic-beta")

        let (data, resp) = try await URLSession.shared.data(for: req)
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
        return try JSON.decoder.decode(UsageResponse.self, from: data)
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
