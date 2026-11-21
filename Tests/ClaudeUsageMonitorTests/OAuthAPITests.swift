import Foundation
import Testing
@testable import ClaudeUsageMonitor

/// Stubs the network via URLProtocol so `OAuthAPI.get`'s status mapping is tested hermetically.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, headers, body) = Self.responder!(request)
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct OAuthAPITests {
    private func session(_ code: Int, _ headers: [String: String] = [:], _ body: String = "{}") -> URLSession {
        StubProtocol.responder = { req in
            // Contract: bearer + beta header, URL under api.anthropic.com/api/oauth/.
            precondition(req.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            precondition(req.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
            precondition(req.url?.host == "api.anthropic.com")
            return (code, headers, Data(body.utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: cfg)
    }

    private let token: @Sendable () throws -> String = { "test-token" }

    @Test func ok200Decodes() async throws {
        let p = try await OAuthAPI.get("profile", as: Profile.self,
            session: session(200, [:], #"{"organization":{"plan_display_name":"Ultra"}}"#), token: token)
        #expect(p.organization?.planDisplayName == "Ultra")
    }

    // Criterion 10: a 401 the refresh can't fix is a reauth prompt, not a bare HTTP code.
    @Test func unauthorized401() async {
        await #expect {
            _ = try await OAuthAPI.get("usage", as: UsageResponse.self, session: session(401), token: token)
        } throws: { ($0 as? AppError).map { if case .reauthRequired(.tokenNotExtended) = $0 { true } else { false } } ?? false }
    }

    // MARK: refresh paths — the fake keychain's token is "t<runs>", so the bearer shows which credential was sent.

    private let profileBody = #"{"organization":{"plan_display_name":"Ultra"}}"#

    /// Replies with `codes` in order (last one repeats) and records each request's bearer token.
    private func sequence(_ codes: [Int], seen: Locked<[String]>) -> URLSession {
        let body = profileBody
        StubProtocol.responder = { req in
            let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
            var n = 0
            seen.mutate { $0.append(String(auth.dropFirst("Bearer ".count))); n = $0.count }
            return (codes[min(n, codes.count) - 1], [:], Data(body.utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func credential(_ cli: FakeCLI) -> @Sendable () throws -> Credential {
        { [runs = cli.runs, expiry = cli.expiry] in Credential(accessToken: "t\(runs.value)", expiresAt: expiry.value) }
    }

    // Criterion 1
    @Test func freshTokenNeverRefreshes() async throws {
        let cli = FakeCLI(expiry: Date().addingTimeInterval(3600)), seen = Locked<[String]>([])
        _ = try await OAuthAPI.get("profile", as: Profile.self, session: sequence([200], seen: seen),
                                   credential: credential(cli), refresher: cli.refresher())
        #expect(cli.runs.value == 0)
        #expect(seen.value == ["t0"])
    }

    // Criterion 2
    @Test func nearExpiryRefreshesBeforeRequest() async throws {
        let cli = FakeCLI(expiry: Date().addingTimeInterval(300)), seen = Locked<[String]>([])
        _ = try await OAuthAPI.get("profile", as: Profile.self, session: sequence([200], seen: seen),
                                   credential: credential(cli), refresher: cli.refresher())
        #expect(cli.runs.value == 1)
        #expect(seen.value == ["t1"])
    }

    // Criterion 3
    @Test func unauthorizedThenRefreshRetriesOnce() async throws {
        let cli = FakeCLI(expiry: Date().addingTimeInterval(3600)), seen = Locked<[String]>([])
        let p = try await OAuthAPI.get("profile", as: Profile.self, session: sequence([401, 200], seen: seen),
                                       credential: credential(cli), refresher: cli.refresher())
        #expect(p.organization?.planDisplayName == "Ultra")
        #expect(cli.runs.value == 1)
        #expect(seen.value == ["t0", "t1"])
    }

    // Criterion 4a: expired token the CLI doesn't renew → reauth before any request is sent.
    @Test func expiredTokenNotExtendedIsReauthWithoutRequest() async {
        let cli = FakeCLI(expiry: Date().addingTimeInterval(-60)), seen = Locked<[String]>([])
        await #expect {
            _ = try await OAuthAPI.get("profile", as: Profile.self, session: self.sequence([200], seen: seen),
                                       credential: self.credential(cli), refresher: cli.refresher(extends: false))
        } throws: { ($0 as? AppError).map { if case .reauthRequired(.tokenNotExtended) = $0 { true } else { false } } ?? false }
        #expect(seen.value.isEmpty)
        #expect(cli.runs.value == 1)
    }

    // Criterion 4b: 401 on a still-valid token the CLI keeps (notNeeded) → exactly one retry, same token.
    @Test func unauthorizedValidTokenKeptRetriesOnceWithSameToken() async throws {
        let cli = FakeCLI(expiry: Date().addingTimeInterval(3600)), seen = Locked<[String]>([])
        _ = try await OAuthAPI.get("profile", as: Profile.self, session: sequence([401, 200], seen: seen),
                                   credential: credential(cli), refresher: cli.refresher(extends: false))
        #expect(seen.value == ["t0", "t1"])   // t<runs>: the CLI ran once; the keychain token text is the stub's
        #expect(cli.runs.value == 1)
    }

    // Criterion 5
    @Test func unauthorizedAfterRefreshIsReauth() async {
        let cli = FakeCLI(expiry: Date().addingTimeInterval(3600)), seen = Locked<[String]>([])
        await #expect {
            _ = try await OAuthAPI.get("profile", as: Profile.self, session: self.sequence([401, 401], seen: seen),
                                       credential: self.credential(cli), refresher: cli.refresher())
        } throws: { ($0 as? AppError).map { if case .reauthRequired(.tokenNotExtended) = $0 { true } else { false } } ?? false }
        #expect(seen.value.count == 2)
        #expect(cli.runs.value == 1)
    }

    @Test func rateLimited429CarriesRetryAfter() async {
        await #expect {
            _ = try await OAuthAPI.get("usage", as: UsageResponse.self,
                session: session(429, ["Retry-After": "42"]), token: token)
        } throws: { ($0 as? AppError).map { if case .rateLimited(42) = $0 { true } else { false } } ?? false }
    }

    @Test func garbageBodyThrowsDecodingError() async {
        await #expect(throws: DecodingError.self) {
            _ = try await OAuthAPI.get("profile", as: Profile.self, session: session(200, [:], "not json"), token: token)
        }
    }

    @Test func keychainFailurePropagates() async {
        await #expect {
            _ = try await OAuthAPI.get("usage", as: UsageResponse.self, session: session(200),
                token: { throw AppError.keychain("no Claude Code credentials found") })
        } throws: { ($0 as? AppError).map { if case .keychain = $0 { true } else { false } } ?? false }
    }
}
