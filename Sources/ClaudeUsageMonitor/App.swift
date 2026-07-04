import SwiftUI

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest") {
            SelfTest.run()
        } else if let i = args.firstIndex(of: "--snapshot") {
            let path = i + 1 < args.count ? args[i + 1] : "popover.png"
            Snapshot.run(path: path)
        } else {
            ClaudeUsageMonitorApp.main()
        }
    }
}

struct ClaudeUsageMonitorApp: App {
    @State private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Compact menu-bar readout: 5-hour percent (primary) · weekly percent (secondary).
/// A single Text renders most reliably in an NSStatusItem; the leading glyph is a
/// plain unicode gauge so we don't depend on SF Symbol layout inside the label.
struct MenuBarLabel: View {
    @Bindable var store: Store

    var body: some View {
        HStack(spacing: 5) {
            if let mark = ClaudeMark.menuBar {
                Image(nsImage: mark)   // natural NSImage size (16pt); no SwiftUI frame
            }
            Text(store.menuBarText)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }
}
