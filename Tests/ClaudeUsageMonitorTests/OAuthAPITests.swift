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

    @Test func unauthorized401() async {
        await #expect {
            _ = try await OAuthAPI.get("usage", as: UsageResponse.self, session: session(401), token: token)
        } throws: { ($0 as? AppError).map { if case .http(401) = $0 { true } else { false } } ?? false }
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
