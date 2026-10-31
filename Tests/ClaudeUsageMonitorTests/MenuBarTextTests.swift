import Testing
@testable import ClaudeUsageMonitor

struct MenuBarTextTests {
    @Test func sessionAndWeekly() {
        let u = Fixture.usage(limits: [Fixture.limit("session", "session", 66), Fixture.limit("weekly_all", "weekly", 21)])
        #expect(MenuBarText.make(usage: u, hasError: false) == .init(text: "66% · 21%", driver: "session"))
    }

    /// Live shape observed 2026-10-31 on an Ultra account: no session window, `five_hour: null`.
    /// Before 0-01 this rendered "…" forever.
    @Test func weeklyOnlyLiveShape() {
        let u = Fixture.usage(limits: [Fixture.limit("weekly_all", "weekly", 2),
                                       Fixture.limit("weekly_scoped", "weekly", 0, model: "Fable")],
                              fiveHourNull: true)
        #expect(MenuBarText.make(usage: u, hasError: false) == .init(text: "2%", driver: "weekly_all"))
    }

    @Test func unknownKindFallsBackToHighest() {
        let u = Fixture.usage(limits: [Fixture.limit("monthly_new", "monthly", 40), Fixture.limit("other", "x", 10)])
        #expect(MenuBarText.make(usage: u, hasError: false) == .init(text: "40%", driver: "monthly_new"))
    }

    @Test func loadedButEmpty() {
        #expect(MenuBarText.make(usage: Fixture.usage(limits: []), hasError: false) == .init(text: "—", driver: "none"))
    }

    @Test func loading() {
        #expect(MenuBarText.make(usage: nil, hasError: false) == .init(text: "…", driver: "loading"))
    }

    @Test func errorWithNoData() {
        #expect(MenuBarText.make(usage: nil, hasError: true) == .init(text: "!", driver: "error"))
    }

    @Test func errorKeepsLastGoodData() {
        let u = Fixture.usage(limits: [Fixture.limit("weekly_all", "weekly", 5)])
        #expect(MenuBarText.make(usage: u, hasError: true).text == "5%")
    }

    @Test func topLevelFallbacksKept() {
        #expect(MenuBarText.make(usage: Fixture.usage(limits: [], sevenDay: 30), hasError: false)
            == .init(text: "30%", driver: "weekly_all"))
        #expect(MenuBarText.make(usage: Fixture.usage(limits: [], fiveHour: 12, sevenDay: 30), hasError: false)
            == .init(text: "12% · 30%", driver: "session"))
    }
}
