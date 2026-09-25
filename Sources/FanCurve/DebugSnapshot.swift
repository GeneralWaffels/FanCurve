#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `FanCurve --snapshot <dir>` renders every settings page (light + dark) to PNGs
/// and exits. Used to review the UI without screen-recording permission.
@MainActor
enum DebugSnapshot {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1) else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let model = Model(), keyboard = KeyboardBlocker(), displays = Displays(), mic = MicMuter(), nav = AppNav()
        let root = SettingsView()
            .environmentObject(model).environmentObject(keyboard).environmentObject(displays).environmentObject(mic).environmentObject(nav)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "FanCurve Settings"
        window.contentView = NSHostingView(rootView: root)
        window.setFrameOrigin(NSPoint(x: -3000, y: 0))   // off-screen
        window.orderFrontRegardless()

        Task {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                for page in AppNav.Page.allCases {
                    nav.page = page
                    try? await Task.sleep(for: .milliseconds(900))
                    guard let view = window.contentView?.superview ?? window.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let name = "\(page.rawValue)-\(appearance == .aqua ? "light" : "dark").png"
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
                }
            }
            exit(0)
        }
    }
}
#endif
