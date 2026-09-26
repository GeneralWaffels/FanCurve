import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Lets the command palette use ⌘Space by switching off Spotlight's "Show Spotlight search" shortcut
/// (symbolic hotkey 64), and restores both when turned off. Finder search (⌥⌘Space) is left alone.
@MainActor
final class SpotlightTakeover: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var message: String?

    private let palette: ShortcutSetting
    private static let spotlightID = "64"
    private static let savedKey = "paletteShortcutBeforeSpotlight"
    static let commandSpace = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey), display: "⌘Space")

    init(palette: ShortcutSetting) {
        self.palette = palette
        enabled = Self.spotlightShortcutDisabled && palette.shortcut == Self.commandSpace
    }

    /// True when Spotlight's ⌘Space shortcut is switched off in the user's keyboard settings.
    static var spotlightShortcutDisabled: Bool {
        let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        return (all?[spotlightID] as? [String: Any])?["enabled"] as? Bool == false
    }

    func set(_ on: Bool) {
        message = nil
        if on {
            if palette.shortcut != Self.commandSpace, let d = try? JSONEncoder().encode(palette.shortcut) {
                UserDefaults.standard.set(d, forKey: Self.savedKey)
            }
            Self.setSpotlightShortcut(enabled: false)
            // The system releases ⌘Space asynchronously; claim it once it's free.
            claim(attempt: 0)
        } else {
            let saved = UserDefaults.standard.data(forKey: Self.savedKey).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
            palette.shortcut = saved ?? Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), display: "⌥Space")
            Self.setSpotlightShortcut(enabled: true)
            enabled = false
        }
    }

    private func claim(attempt: Int) {
        palette.shortcut = Self.commandSpace
        if !palette.conflict {
            enabled = true
        } else if attempt < 6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.claim(attempt: attempt + 1) }
        } else {
            enabled = true
            message = "Spotlight's shortcut is off, but macOS hasn't released ⌘Space yet. Log out and back in to finish."
        }
    }

    /// Writes symbolic hotkey 64 (⌘Space, Show Spotlight search) and asks macOS to apply it now.
    private static func setSpotlightShortcut(enabled: Bool) {
        let plist = """
        <dict><key>enabled</key><\(enabled ? "true" : "false")/><key>value</key><dict>\
        <key>parameters</key><array><integer>32</integer><integer>49</integer><integer>1048576</integer></array>\
        <key>type</key><string>standard</string></dict></dict>
        """
        run("/usr/bin/defaults", ["write", "com.apple.symbolichotkeys", "AppleSymbolicHotKeys", "-dict-add", spotlightID, plist])
        run("/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", ["-u"])
    }

    private static func run(_ tool: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}

struct SpotlightTakeoverRow: View {
    @ObservedObject var takeover: SpotlightTakeover

    var body: some View {
        Toggle(isOn: Binding(get: { takeover.enabled }, set: { takeover.set($0) })) {
            Text("Use ⌘Space for the command palette")
            Text("Turns off Spotlight's ⌘Space shortcut. Finder search stays on ⌥⌘Space, and turning this off restores Spotlight.")
        }
        if let m = takeover.message { StatusRow(text: m, color: .orange) }
    }
}
