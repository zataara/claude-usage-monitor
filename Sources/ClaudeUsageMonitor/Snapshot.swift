import SwiftUI
import AppKit

/// Headless render of the popover to PNGs (light + dark) so the full UI can be verified
/// without opening the menu bar. Run: `ClaudeUsageMonitor --snapshot out.png`.
///
/// Uses a real AppKit run loop: ImageRenderer asserts it runs on the literal main
/// thread, which only holds when the main actor is bound to it via NSApplication.run()
/// (a bare dispatchMain() task runs on a cooperative thread and trips the assertion).
enum Snapshot {
    @MainActor
    static func run(path: String) -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        Task { @MainActor in
            let store = Store()
            await store.refresh()

            // Menu-bar label preview (on a bar-like strip) to check icon/text sizing.
            let label = MenuBarLabel(store: store)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color(hex: 0x2A2A2A))
                .foregroundStyle(.white)
                .environment(\.colorScheme, .dark)
            let lr = ImageRenderer(content: label)
            lr.scale = 3
            if let img = lr.nsImage, let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                let out = path.replacingOccurrences(of: ".png", with: "-label.png")
                try? png.write(to: URL(fileURLWithPath: out))
                print("✓ wrote \(out)  (\(Int(img.size.width))×\(Int(img.size.height)))")
            }

            for scheme in [ColorScheme.dark, .light] {
                let view = PopoverView(store: store)
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let img = renderer.nsImage,
                      let tiff = img.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    print("✗ render failed (\(scheme))")
                    continue
                }
                let suffix = scheme == .dark ? "-dark" : "-light"
                let out = path.replacingOccurrences(of: ".png", with: "\(suffix).png")
                try? png.write(to: URL(fileURLWithPath: out))
                print("✓ wrote \(out)  (\(Int(img.size.width))×\(Int(img.size.height)))")
            }
            exit(0)
        }

        app.run()
        fatalError("unreachable")
    }
}
