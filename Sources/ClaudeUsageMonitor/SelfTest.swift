import Foundation

/// Headless diagnostic: exercises the real data pipeline (keychain → usage endpoint →
/// decode → ccusage) and prints a summary. Run: `ClaudeUsageMonitor --selftest`.
/// Never prints the OAuth token.
enum SelfTest {
    static func run() -> Never {
        setbuf(stdout, nil)   // unbuffered so progress shows even when piped
        Task {
            var code: Int32 = 0

            // 1. Keychain
            do {
                let tok = try await Task.detached { try Keychain.claudeAccessToken() }.value
                print("✓ keychain token: \(tok.count) chars (redacted)")
            } catch {
                print("✗ keychain: \(error.localizedDescription)")
                exit(1)
            }

            // 2. Official usage endpoint
            do {
                let u = try await UsageAPI.fetch()
                print("✓ usage endpoint: \(u.limits.count) limit window(s)")
                for l in u.limits {
                    let bar = String(format: "%-22@ %5.0f%%  %@  [%@]",
                                     l.title as NSString, l.percent,
                                     Fmt.resetsIn(l.resetsAt), l.severity)
                    print("    \(bar)")
                }
                if let e = u.extraUsage {
                    print("    overage: enabled=\(e.isEnabled) used=\(e.usedCredits ?? 0)")
                }
                let label = MenuBarText.make(usage: u, hasError: false)
                print("• label: \"\(label.text)\" (driver: \(label.driver))")
            } catch {
                print("✗ usage endpoint: \(error.localizedDescription)")
                code = 1
            }

            // 3. Profile → plan badge (decoration — non-fatal)
            do {
                let org = try await ProfileAPI.fetch().organization
                if let badge = PlanBadge.text(for: org) {
                    print("✓ plan: \(badge) (\(org?.organizationType ?? "?"), \(org?.rateLimitTier ?? "?"))")
                } else {
                    print("• plan: profile has no plan fields")
                }
            } catch {
                print("• plan unavailable: \(error.localizedDescription)")
            }

            // 4. ccusage (detail — non-fatal)
            do {
                if let b = try await CCUsageSource.fetch() {
                    print("✓ ccusage: \(Fmt.compactCount(b.totalTokens ?? 0)) tok, "
                        + "\(Fmt.dollars(b.costUSD ?? 0)) API-equiv, "
                        + "burn \(Fmt.compactCount(b.burnRate?.tokensPerMinute ?? 0))/min")
                } else {
                    print("• ccusage: no active block")
                }
            } catch {
                print("• ccusage unavailable: \(error.localizedDescription)")
            }

            exit(code)
        }
        dispatchMain()   // park the main thread; the Task above owns termination via exit()
    }
}
