import Foundation
import os

/// Keeps the Claude Code OAuth token in the keychain fresh by asking the `claude` CLI to refresh it.
///
/// The access token lives ~8 h and only the CLI refreshes it, only when the CLI runs. The Desktop app keeps its
/// own credentials, so the keychain item goes stale while the owner works there. Running `claude plugin list`
/// makes the CLI refresh and write the rotated pair back itself (measured 2026-11-20, CLI 2.1.329: 1 s, no model
/// call). The monitor never touches the refresh token, so there is no rotation race with the CLI.
actor CLIRefresher {
    enum RunResult: Sendable, Equatable { case exited(Int32), timedOut, launchFailed }
    /// `notNeeded`: the CLI ran but kept a token that is still valid. It refreshes only near or past
    /// expiry, on its own threshold (2026-11-20: a token with 458 min left was left alone), so this is
    /// not a failure.
    enum Outcome: Sendable, Equatable { case refreshed, notNeeded }
    typealias Runner = @Sendable (_ command: String, _ timeout: TimeInterval) async -> RunResult

    static let defaultCommand = "claude plugin list"
    static let defaultTimeout: TimeInterval = 30
    /// After a failed refresh, don't respawn the CLI on every poll; surface the reauth message instead.
    static let defaultCooldown: TimeInterval = 300
    /// Refresh before a request when the token expires within this window (or already has).
    static let preflightMargin: TimeInterval = 600

    static let shared = CLIRefresher()

    private let command: String
    private let timeout: TimeInterval
    private let cooldown: TimeInterval
    private let runner: Runner
    private let expiry: @Sendable () -> Date?
    private let now: @Sendable () -> Date
    private let log = Logger(subsystem: "codes.bryant.ClaudeUsageMonitor", category: "auth")

    private var inFlight: Task<Outcome, Error>?
    private var lastFailure: (at: Date, reason: AppError.ReauthReason)?

    init(
        command: String = CLIRefresher.configuredCommand(),
        timeout: TimeInterval = CLIRefresher.defaultTimeout,
        cooldown: TimeInterval = CLIRefresher.defaultCooldown,
        runner: @escaping Runner = CLIRefresher.processRunner,
        expiry: @escaping @Sendable () -> Date? = { try? Keychain.claudeCredential().expiresAt },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.command = command
        self.timeout = timeout
        self.cooldown = cooldown
        self.runner = runner
        self.expiry = expiry
        self.now = now
    }

    /// True when the token is missing an expiry we can trust to be comfortably in the future.
    nonisolated static func needsPreflight(expiresAt: Date?, now: Date = Date()) -> Bool {
        guard let e = expiresAt else { return false }   // unknown expiry: let the 401 path decide
        return e.timeIntervalSince(now) < preflightMargin
    }

    /// Runs the CLI once; concurrent callers share the same run. Throws `.reauthRequired` on failure, and
    /// immediately (without running the CLI) while a previous failure's cooldown is active.
    @discardableResult
    func refresh() async throws -> Outcome {
        if let running = inFlight { return try await running.value }
        if let f = lastFailure, now().timeIntervalSince(f.at) < cooldown {
            throw AppError.reauthRequired(f.reason)
        }
        let task = Task { try await self.perform() }
        inFlight = task
        defer { inFlight = nil }
        do {
            let outcome = try await task.value
            lastFailure = nil
            return outcome
        } catch let AppError.reauthRequired(reason) {
            lastFailure = (now(), reason)
            throw AppError.reauthRequired(reason)
        }
    }

    private func perform() async throws -> Outcome {
        let before = expiry()
        log.info("refresh attempted")
        let result = await runner(command, timeout)
        switch result {
        case .launchFailed, .exited(127):
            log.error("refresh failed: cliNotFound (\(String(describing: result), privacy: .public))")
            throw AppError.reauthRequired(.cliNotFound)
        case .timedOut:
            log.error("refresh failed: timedOut after \(self.timeout, privacy: .public)s")
            throw AppError.reauthRequired(.timedOut)
        case .exited(let code):
            // Exit status alone is not success: only an expiry still in the future proves a usable token.
            guard let after = expiry(), after > now() else {
                log.error("refresh failed: tokenNotExtended (exit \(code, privacy: .public))")
                throw AppError.reauthRequired(.tokenNotExtended)
            }
            let minutes = Int(after.timeIntervalSince(now()) / 60)
            if after > (before ?? .distantPast) {
                log.info("refresh succeeded: token expires in \(minutes, privacy: .public)m (exit \(code, privacy: .public))")
                return .refreshed
            }
            log.info("refresh not needed: CLI kept a valid token, expires in \(minutes, privacy: .public)m")
            return .notNeeded
        }
    }

    // MARK: - Defaults

    static func configuredCommand() -> String {
        #if DEBUG
        // Debug-only hook so the error path can be driven against the real binary (CLI unresolvable).
        if let o = ProcessInfo.processInfo.environment["CUM_REFRESH_COMMAND"], !o.isEmpty { return o }
        #endif
        return defaultCommand
    }

    /// Runs `command` through a login shell (GUI apps get a minimal PATH). All output goes to the null device:
    /// an unread pipe blocks the child once it fills, and the CLI's output is never needed nor logged.
    static let processRunner: Runner = { command, timeout in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let proc = UncheckedBox(p)
        return await withCheckedContinuation { (cont: CheckedContinuation<RunResult, Never>) in
            let once = ResumeOnce(cont)
            p.terminationHandler = { once.resume(.exited($0.terminationStatus)) }
            do { try p.run() } catch { once.resume(.launchFailed); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if proc.value.isRunning {
                    proc.value.terminate()
                    once.resume(.timedOut)
                }
            }
        }
    }
}

/// Resumes a continuation at most once (termination handler vs. timeout race).
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Never>?
    init(_ c: CheckedContinuation<T, Never>) { cont = c }
    func resume(_ value: T) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(returning: value)
    }
}

/// `Process` is not Sendable; it is only read (`isRunning`) and terminated from the timeout closure.
private final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { value = v }
}
