import Foundation
@testable import ClaudeUsageMonitor

enum Fixture {
    static func limit(_ kind: String, _ group: String, _ pct: Double, model: String? = nil) -> String {
        let scope = model.map { #","scope":{"model":{"display_name":"\#($0)"}}"# } ?? ""
        return #"{"kind":"\#(kind)","group":"\#(group)","percent":\#(pct),"severity":"normal","resets_at":"2026-11-07T12:00:00.123456+00:00","is_active":true\#(scope)}"#
    }

    static func usage(limits: [String], fiveHour: Double? = nil, sevenDay: Double? = nil,
                      fiveHourNull: Bool = false) -> UsageResponse {
        var parts = [#""limits":[\#(limits.joined(separator: ","))]"#]
        if let f = fiveHour { parts.append(#""five_hour":{"utilization":\#(f)}"#) }
        else if fiveHourNull { parts.append(#""five_hour":null"#) }
        if let w = sevenDay { parts.append(#""seven_day":{"utilization":\#(w)}"#) }
        let json = "{" + parts.joined(separator: ",") + "}"
        return try! JSON.decoder.decode(UsageResponse.self, from: Data(json.utf8))
    }
}
