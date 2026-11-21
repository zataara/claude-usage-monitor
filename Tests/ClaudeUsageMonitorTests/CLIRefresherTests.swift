import Foundation
import Testing
@testable import ClaudeUsageMonitor

/// Thread-safe mutable cell for stubs shared across concurrent tasks.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&_value); lock.unlock() }
}

/// A fake CLI: counts runs, and on success moves the fake keychain expiry forward 8 h.
struct FakeCLI {
    let runs = Locked(0)
    let expiry: Locked<Date?>
    init(expiry: Date?) { self.expiry = Locked(expiry) }

    func runner(result: CLIRefresher.RunResult = .exited(0), extends: Bool = true,
                delay: Duration = .zero) -> CLIRefresher.Runner {
        { [runs, expiry] _, _ in
            runs.mutate { $0 += 1 }
            if delay != .zero { try? await Task.sleep(for: delay) }
            if extends, case .exited(0) = result { expiry.mutate { $0 = Date().addingTimeInterval(8 * 3600) } }
            return result
        }
    }

    func refresher(result: CLIRefresher.RunResult = .exited(0), extends: Bool = true,
                   delay: Duration = .zero, cooldown: TimeInterval = 300) -> CLIRefresher {
        CLIRefresher(command: "fake", timeout: 30, cooldown: cooldown,
                     runner: runner(result: result, extends: extends, delay: delay),
                     expiry: { [expiry] in expiry.value })
    }
}

private func reason(_ e: Error) -> AppError.ReauthReason? {
    if case let AppError.reauthRequired(r)? = e as? AppError { return r }
    return nil
}

@Suite struct CLIRefresherTests {
    @Test func successExtendsExpiry() async throws {
        let cli = FakeCLI(expiry: Date().addingTimeInterval(-60))
        try await cli.refresher().refresh()
        #expect(cli.runs.value == 1)
        #expect(cli.expiry.value! > Date().addingTimeInterval(7 * 3600))
    }

    // Criterion 6
    @Test func exit127IsCliNotFound() async {
        let cli = FakeCLI(expiry: Date())
        await #expect { try await cli.refresher(result: .exited(127)).refresh() } throws: { reason($0) == .cliNotFound }
    }

    @Test func launchFailureIsCliNotFound() async {
        let cli = FakeCLI(expiry: Date())
        await #expect { try await cli.refresher(result: .launchFailed).refresh() } throws: { reason($0) == .cliNotFound }
    }

    // Criterion 7 (mapping half; the real timeout is processRunnerTimesOut)
    @Test func timeoutIsTimedOut() async {
        let cli = FakeCLI(expiry: Date())
        await #expect { try await cli.refresher(result: .timedOut).refresh() } throws: { reason($0) == .timedOut }
    }

    @Test func zeroExitWithoutNewExpiryIsTokenNotExtended() async {
        let cli = FakeCLI(expiry: Date().addingTimeInterval(-60))
        await #expect { try await cli.refresher(extends: false).refresh() } throws: { reason($0) == .tokenNotExtended }
    }

    // Criterion 8
    @Test func cooldownBlocksImmediateRetry() async {
        let cli = FakeCLI(expiry: Date())
        let r = cli.refresher(result: .exited(127))
        await #expect { try await r.refresh() } throws: { reason($0) == .cliNotFound }
        await #expect { try await r.refresh() } throws: { reason($0) == .cliNotFound }
        #expect(cli.runs.value == 1)
    }

    @Test func cooldownExpiresThenRetries() async {
        let cli = FakeCLI(expiry: Date())
        let r = cli.refresher(result: .exited(127), cooldown: 0)
        _ = try? await r.refresh()
        _ = try? await r.refresh()
        #expect(cli.runs.value == 2)
    }

    // Criterion 9
    @Test func concurrentCallersShareOneRun() async throws {
        let cli = FakeCLI(expiry: Date().addingTimeInterval(-60))
        let r = cli.refresher(delay: .milliseconds(200))
        try await withThrowingTaskGroup(of: Void.self) { g in
            for _ in 0..<10 { g.addTask { try await r.refresh() } }
            try await g.waitForAll()
        }
        #expect(cli.runs.value == 1)
    }

    @Test func preflightWindow() {
        let now = Date()
        #expect(CLIRefresher.needsPreflight(expiresAt: now.addingTimeInterval(300), now: now))
        #expect(CLIRefresher.needsPreflight(expiresAt: now.addingTimeInterval(-60), now: now))
        #expect(!CLIRefresher.needsPreflight(expiresAt: now.addingTimeInterval(3600), now: now))
        #expect(!CLIRefresher.needsPreflight(expiresAt: nil, now: now))
    }

    // The real process runner: exit codes, a missing command, and the timeout.
    @Test func processRunnerReportsExitCode() async {
        #expect(await CLIRefresher.processRunner("exit 3", 10) == .exited(3))
    }

    @Test func processRunnerMissingCommandIs127() async {
        #expect(await CLIRefresher.processRunner("definitely-not-a-command-tls0126", 10) == .exited(127))
    }

    @Test func processRunnerTimesOut() async {
        let t0 = Date()
        #expect(await CLIRefresher.processRunner("sleep 5", 0.2) == .timedOut)
        #expect(Date().timeIntervalSince(t0) < 3)
    }
}
