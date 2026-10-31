import Foundation
import Testing
@testable import ClaudeUsageMonitor

struct PlanBadgeTests {
    private func org(_ json: String) throws -> Profile.Organization? {
        try JSON.decoder.decode(Profile.self, from: Data(json.utf8)).organization
    }

    @Test func serverDisplayNameWins() throws {
        let o = try org(#"{"organization":{"plan_display_name":"Ultra","organization_type":"claude_max","rate_limit_tier":"default_claude_max_20x","seat_tier":null}}"#)
        #expect(PlanBadge.text(for: o) == "Ultra")
    }

    @Test func teamFromTypeTableWithSeat() throws {
        let o = try org(#"{"organization":{"organization_type":"claude_team","seat_tier":"premium"}}"#)
        #expect(PlanBadge.text(for: o) == "Team · Premium")
    }

    @Test func unknownTypeRendersRawTitleCased() throws {
        let o = try org(#"{"organization":{"organization_type":"claude_foo_bar"}}"#)
        #expect(PlanBadge.text(for: o) == "Foo Bar")
    }

    @Test func noPlanFieldsNoBadge() throws {
        #expect(PlanBadge.text(for: try org(#"{"organization":{}}"#)) == nil)
        #expect(PlanBadge.text(for: try org(#"{"organization":{"plan_display_name":"  "}}"#)) == nil)
    }
}

struct ProfileDecodeTests {
    /// Real response shape (keys only; PII values replaced) with many unmodeled fields.
    @Test func realShapeWithExtraKeysDecodes() throws {
        let json = #"{"account":{"uuid":"x","email":"x","has_claude_max":true},"organization":{"uuid":"x","name":"x","organization_type":"claude_max","billing_type":"stripe_subscription","rate_limit_tier":"default_claude_max_20x","seat_tier":null,"plan_display_name":"Ultra","plan_display_label":"Ultra plan","cc_onboarding_flags":{}},"application":{"uuid":"x"},"enabled_plugins":[]}"#
        let p = try JSON.decoder.decode(Profile.self, from: Data(json.utf8))
        #expect(p.organization?.rateLimitTier == "default_claude_max_20x")
        #expect(PlanBadge.text(for: p.organization) == "Ultra")
    }

    @Test func nullOrganizationMeansNoBadge() throws {
        let p = try JSON.decoder.decode(Profile.self, from: Data(#"{"organization":null}"#.utf8))
        #expect(PlanBadge.text(for: p.organization) == nil)
    }

    @Test func malformedJSONThrows() {
        #expect(throws: DecodingError.self) {
            try JSON.decoder.decode(Profile.self, from: Data("{not json".utf8))
        }
    }

    /// Error path: a failed profile fetch records planError, keeps the last good badge,
    /// and never touches usageError (the badge is decoration; usage is the job).
    @MainActor @Test func planFailureIsolatedFromUsage() {
        let store = Store(autostart: false)
        store.applyPlan(.success(try! JSON.decoder.decode(Profile.self, from: Data(#"{"organization":{"plan_display_name":"Ultra"}}"#.utf8))))
        store.applyPlan(.failure(AppError.http(500)))
        #expect(store.plan == "Ultra")
        #expect(store.planError != nil)
        #expect(store.usageError == nil)
    }
}
