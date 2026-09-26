import AppKit
import ApplicationServices
import SwiftUI

/// Accessibility permission, shared by snippets, brightness keys and keyboard cleaning mode.
///
/// macOS ties the permission to the app's code signature. Ad-hoc signed builds get a new signature on
/// every update, which leaves a stale entry in System Settings: it looks switched on but no longer
/// applies, and macOS won't show the prompt again while it exists. `request()` clears FanCurve's own
/// stale entry first so the real prompt appears, then watches for the grant.
@MainActor
final class AccessibilityPermission: ObservableObject {
    static let shared = AccessibilityPermission()

    @Published private(set) var isTrusted = AXIsProcessTrusted()
    private var watcher: Timer?
    private var onGrant: [() -> Void] = []

    /// Runs `action` once access is granted (immediately if it already is).
    func whenGranted(_ action: @escaping () -> Void) {
        if AXIsProcessTrusted() { isTrusted = true; action(); return }
        onGrant.append(action)
        watch()
    }

    /// Shows the macOS "FanCurve would like to control this computer" prompt.
    func request() {
        guard !AXIsProcessTrusted() else { isTrusted = true; fire(); return }
        // Remove only FanCurve's own (possibly stale) Accessibility entry, so macOS prompts again.
        if let id = Bundle.main.bundleIdentifier {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", "Accessibility", id]
            try? p.run()
            p.waitUntilExit()
        }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        watch()
    }

    func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Polls until the user flips the switch in System Settings, then starts the waiting features.
    private func watch() {
        guard watcher == nil else { return }
        watcher = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.isTrusted = true
                self.watcher?.invalidate(); self.watcher = nil
                self.fire()
            }
        }
    }

    private func fire() {
        let actions = onGrant
        onGrant = []
        actions.forEach { $0() }
    }
}

/// Status row + buttons shown wherever a feature is waiting for Accessibility access.
struct AccessibilityRow: View {
    let feature: String
    @ObservedObject private var permission = AccessibilityPermission.shared

    var body: some View {
        if !permission.isTrusted {
            LabeledContent {
                HStack {
                    Button("Allow Access…") { permission.request() }.buttonStyle(.borderedProminent)
                    Button("Open Settings") { permission.openSettings() }
                }
            } label: {
                StatusRow(text: "FanCurve needs Accessibility access to \(feature). Click Allow Access, then switch FanCurve on in the list.",
                          color: .orange)
            }
        }
    }
}
