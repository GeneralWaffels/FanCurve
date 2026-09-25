import SwiftUI
import SMCKit

/// Opening FanCurve again (Finder, Spotlight, Dock) while it's running shows Settings.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let openSettings = Notification.Name("FanCurveOpenSettings")

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: Self.openSettings, object: nil)
        return false
    }
}

@main
struct FanCurveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = Model()
    @StateObject private var keyboard = KeyboardBlocker()
    @StateObject private var displays = Displays()
    @StateObject private var mic = MicMuter()
    @StateObject private var nav = AppNav()

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(model).environmentObject(keyboard).environmentObject(displays).environmentObject(mic).environmentObject(nav)
        } label: {
            MenuBarLabel(nav: nav) {
                if keyboard.isOn {
                    Label("Keyboard off \(mmss(keyboard.secondsLeft))", systemImage: "keyboard.badge.ellipsis")
                        .labelStyle(.titleAndIcon)
                } else {
                    fanLabel
                }
            }
        }

        Window("FanCurve Settings", id: "settings") {
            SettingsView()
                .environmentObject(model).environmentObject(keyboard).environmentObject(displays).environmentObject(mic).environmentObject(nav)
        }
        .defaultSize(width: 860, height: 640)
        .windowResizability(.contentMinSize)

        // Separate mic status icon; visibility follows the "Show mic icon in menu bar" setting.
        MenuBarExtra(isInserted: $mic.showIndicator) {
            MicMenu().environmentObject(mic).environmentObject(nav)
        } label: {
            Image(systemName: mic.isMuted ? "mic.slash.fill" : "mic.fill")
        }
    }

    @ViewBuilder private var fanLabel: some View {
        let t = model.currentTemp.map { "\(Int($0))°" } ?? "--"
        let rpm = model.fans.first.map { $0.actual < 100 ? "off" : "\(Int($0.actual))" } ?? ""
        Label("\(t)  \(rpm)", systemImage: model.config.enabled ? "fan.fill" : "fan")
            .labelStyle(.titleAndIcon)
    }
}

/// The menu bar label is always alive, so it's where the "open Settings" request is handled.
struct MenuBarLabel<Content: View>: View {
    let nav: AppNav
    @ViewBuilder let content: Content
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        content.onReceive(NotificationCenter.default.publisher(for: AppDelegate.openSettings)) { _ in nav.openSettings(openWindow) }
    }
}

struct MenuContent: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var keyboard: KeyboardBlocker
    @EnvironmentObject var displays: Displays
    @EnvironmentObject var mic: MicMuter
    @EnvironmentObject var nav: AppNav
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("CPU \(fmt(model.temps[.cpuMax]))  ·  GPU \(fmt(model.temps[.gpuMax]))")
        ForEach(model.fans) { f in Text("Fan \(f.id + 1): \(Int(f.actual)) rpm") }
        Divider()
        Toggle("Use fan curve", isOn: $model.config.enabled)
        ProfileMenu()
        Divider()
        if displays.monitors.isEmpty {
            Text("No external displays")
        } else {
            Toggle("Match laptop light sensor", isOn: $displays.followSensor)
            ForEach(displays.monitors) { m in
                Menu("\(m.name): \(Int(m.brightness))%") {
                    ForEach([0, 10, 25, 50, 75, 100], id: \.self) { v in
                        Button("\(v)%") { displays.setBrightness(Double(v), for: m.id) }
                    }
                }
            }
        }
        Divider()
        Toggle("Mute microphone\(mic.shortcut.map { "  (\($0.display))" } ?? "")", isOn: Binding(get: { mic.isMuted }, set: { mic.setMuted($0) }))
        Toggle("Keyboard cleaning mode", isOn: Binding(get: { keyboard.isOn }, set: { _ in keyboard.toggle() }))
        if keyboard.needsPermission {
            Button("Grant Accessibility access…") { keyboard.openAccessibilitySettings() }
        }
        Divider()
        Button("Settings…") { nav.openSettings(openWindow) }.keyboardShortcut(",")
        Button("Quit FanCurve") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// Settings window navigation (sidebar selection is remembered between openings).
@MainActor
final class AppNav: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case fans, displays, mic, keyboard
        var id: String { rawValue }
        var title: String {
            switch self {
            case .fans: return "Fans"
            case .displays: return "Displays"
            case .mic: return "Microphone"
            case .keyboard: return "Keyboard"
            }
        }
        var symbol: String {
            switch self {
            case .fans: return "fan.fill"
            case .displays: return "display"
            case .mic: return "mic.fill"
            case .keyboard: return "keyboard.fill"
            }
        }
        var tint: Color {
            switch self {
            case .fans: return .blue
            case .displays: return .indigo
            case .mic: return .red
            case .keyboard: return .gray
            }
        }
    }

    @Published var page: Page = .fans

    func openSettings(_ openWindow: OpenWindowAction) {
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Menu for the separate mic status icon.
struct MicMenu: View {
    @EnvironmentObject var mic: MicMuter
    @EnvironmentObject var nav: AppNav
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(mic.isMuted ? "Unmute microphone" : "Mute microphone") { mic.toggle() }
        Text("Shortcut: \(mic.shortcut?.display ?? "none")")
        Divider()
        Button("Settings…") { nav.openSettings(openWindow) }
    }
}

func fmt(_ t: Double?) -> String { t.map { String(format: "%.0f °C", $0) } ?? "--" }
