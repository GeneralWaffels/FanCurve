#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `FanCurve --snapshot <dir>` opens the real Settings window, renders every page
/// (light + dark) to PNGs via the window server, and exits. Used to review the UI.
@MainActor
enum DebugSnapshot {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1) else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        Task {
            try? await Task.sleep(for: .seconds(1))
            NotificationCenter.default.post(name: AppDelegate.openSettings, object: nil)
            try? await Task.sleep(for: .seconds(1.5))
            guard let window = NSApp.windows.first(where: { $0.title.contains("Settings") || $0.identifier?.rawValue.contains("settings") == true }) else { exit(1) }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                for page in AppNav.Page.allCases {
                    AppNav.shared.page = page
                    try? await Task.sleep(for: .milliseconds(900))
                    let name = "\(page.rawValue)-\(appearance == .aqua ? "light" : "dark").png"
                    if let cg = windowImage(window.windowNumber) {
                        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
                    }
                }
            }
            // The command palette itself: suggestions, then a calculator query.
            LauncherPanel.shared.keepOpenOnResign = true
            NotificationCenter.default.post(name: AppDelegate.openPalette, object: nil)
            for (name, query) in [("palette", ""), ("palette-calc", "23*1.21"), ("palette-search", "fan"), ("palette-aero", "aerospace"), ("palette-ws", "workspace 3")] {
                LauncherPanel.shared.model.query = query
                try? await Task.sleep(for: .milliseconds(900))
                if let n = LauncherPanel.shared.windowNumber, let cg = windowImage(n) {
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
                }
            }
            exit(0)
        }
    }

    /// CGWindowListCreateImage is unavailable to Swift in the macOS 15+ SDK but still exported; fine for a debug tool.
    /// An app may capture its own windows without screen-recording permission.
    private static func windowImage(_ number: Int) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let fn = unsafeBitCast(sym, to: Fn.self)
        // listOptions: optionIncludingWindow (8); imageOptions: boundsIgnoreFraming (1) | bestResolution (8)
        return fn(.null, 8, UInt32(number), 1 | 8)?.takeRetainedValue()
    }
}
#endif
