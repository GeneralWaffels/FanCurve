import Carbon.HIToolbox
import SwiftUI
import SMCKit

/// Opening FanCurve again (Finder, Spotlight, Dock) while it's running shows Settings.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let openSettings = Notification.Name("FanCurveOpenSettings")
    static let openPalette = Notification.Name("FanCurveOpenPalette")

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        MainActor.assumeIsolated { DebugSnapshot.runIfRequested() }
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: Self.openSettings, object: nil)
        return false
    }
}

@main
struct FanCurveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: Model
    @StateObject private var keyboard: KeyboardBlocker
    @StateObject private var displays: Displays
    @StateObject private var brightnessKeys: BrightnessKeys
    @StateObject private var mic: MicMuter
    @StateObject private var nav = AppNav.shared
    @StateObject private var loginItem = LoginItem()
    @StateObject private var updater: Updater
    @StateObject private var calendar: CalendarStore
    @StateObject private var snippets: SnippetStore
    @StateObject private var shortcuts: AppShortcuts
    @StateObject private var aero: AeroSpace
    @StateObject private var favourites: Favourites
    @StateObject private var obsidian: Obsidian
    @StateObject private var quickNotes: QuickNotes
    @StateObject private var jiggler: MouseJiggler
    @StateObject private var autocomplete: Autocomplete

    init() {
        let model = Model(), keyboard = KeyboardBlocker(), displays = Displays(), mic = MicMuter()
        let updater = Updater(), calendar = CalendarStore(), snippets = SnippetStore(), aero = AeroSpace(), favourites = Favourites(), obsidian = Obsidian(), quickNotes = QuickNotes(), jiggler = MouseJiggler(), autocomplete = Autocomplete()
        quickNotes.obsidian = obsidian
        favourites.aero = aero
        LauncherPanel.shared.favourites = favourites
        calendar.onJoin = { [weak mic] in mic?.setMuted(true) }

        let palette = CommandSource(.init(model: model, mic: mic, keyboard: keyboard, displays: displays, calendar: calendar,
                                          snippets: snippets, updater: updater, aero: aero, favourites: favourites, obsidian: obsidian, quickNotes: quickNotes, jiggler: jiggler, autocomplete: autocomplete,
                                          openSettings: { NotificationCenter.default.post(name: AppDelegate.openSettings, object: nil) }))
        let schedule = ScheduleSource(calendar: calendar)
        let snippetSearch = SnippetSource(store: snippets)
        NotificationCenter.default.addObserver(forName: AppDelegate.openPalette, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LauncherPanel.shared.show(palette) }
        }
        let shortcuts = AppShortcuts(
            palette: ShortcutSetting(key: "paletteShortcut", id: 5,
                                     default: Shortcut(keyCode: 49, modifiers: UInt32(optionKey), display: "⌥Space")) {
                LauncherPanel.shared.toggle(palette)
            },
            joinMeeting: ShortcutSetting(key: "joinShortcut", id: 2, default: .ctrlOpt(kVK_ANSI_J, "J")) { calendar.join() },
            schedule: ShortcutSetting(key: "scheduleShortcut", id: 3, default: .ctrlOpt(kVK_ANSI_C, "C")) {
                LauncherPanel.shared.toggle(schedule)
            },
            snippets: ShortcutSetting(key: "snippetShortcut", id: 4, default: .ctrlOpt(kVK_ANSI_S, "S")) {
                LauncherPanel.shared.toggle(snippetSearch)
            },
            quickNotes: ShortcutSetting(key: "quickNotesShortcut", id: 6, default: .ctrlOpt(kVK_ANSI_N, "N")) {
                quickNotes.toggleWindow()
            })

        shortcuts.setUpLayoutShortcuts(aero)
        shortcuts.autocompletePause = ShortcutSetting(key: "acPauseShortcut", id: 7, default: .ctrlOpt(kVK_ANSI_A, "A")) {
            if autocomplete.enabled { autocomplete.paused.toggle() } else { autocomplete.enabled = true }
        }
        shortcuts.autocompleteNow = ShortcutSetting(key: "acNowShortcut", id: 8, default: nil) { autocomplete.suggestNow() }
        shortcuts.draftReply = ShortcutSetting(key: "acDraftShortcut", id: 9, default: .ctrlOpt(kVK_ANSI_R, "R")) { autocomplete.draftReply() }
        _model = StateObject(wrappedValue: model)
        _keyboard = StateObject(wrappedValue: keyboard)
        _displays = StateObject(wrappedValue: displays)
        _brightnessKeys = StateObject(wrappedValue: BrightnessKeys(displays: displays))
        _mic = StateObject(wrappedValue: mic)
        _updater = StateObject(wrappedValue: updater)
        _calendar = StateObject(wrappedValue: calendar)
        _snippets = StateObject(wrappedValue: snippets)
        _shortcuts = StateObject(wrappedValue: shortcuts)
        _aero = StateObject(wrappedValue: aero)
        _favourites = StateObject(wrappedValue: favourites)
        _obsidian = StateObject(wrappedValue: obsidian)
        _quickNotes = StateObject(wrappedValue: quickNotes)
        _jiggler = StateObject(wrappedValue: jiggler)
        _autocomplete = StateObject(wrappedValue: autocomplete)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(model).environmentObject(keyboard).environmentObject(displays).environmentObject(mic).environmentObject(nav).environmentObject(updater)
                .environmentObject(calendar).environmentObject(shortcuts).environmentObject(quickNotes).environmentObject(jiggler).environmentObject(autocomplete)
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
                .environmentObject(brightnessKeys).environmentObject(loginItem).environmentObject(updater)
                .environmentObject(calendar).environmentObject(snippets).environmentObject(shortcuts).environmentObject(aero)
                .environmentObject(favourites).environmentObject(obsidian).environmentObject(quickNotes)
                .environmentObject(jiggler).environmentObject(autocomplete)
        }
        .defaultSize(width: 760, height: 680)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)

        // Separate mic status icon; visibility follows the "Show mic icon in menu bar" setting.
        MenuBarExtra(isInserted: $mic.showIndicator) {
            MicMenu().environmentObject(mic).environmentObject(nav)
        } label: {
            Image(systemName: mic.isMuted ? "mic.slash.fill" : "mic.fill")
        }

        // Next meeting ("Standup · in 12 min"); visibility follows Settings → Calendar → Menu Bar.
        MenuBarExtra(isInserted: $calendar.showInMenuBar) {
            MeetingMenu().environmentObject(calendar).environmentObject(nav).environmentObject(shortcuts)
        } label: {
            Label(calendar.menuBarTitle, systemImage: calendar.next?.isOngoing(at: calendar.now) == true ? "video.fill" : "calendar")
                .labelStyle(.titleAndIcon)
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
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var calendar: CalendarStore
    @EnvironmentObject var shortcuts: AppShortcuts
    @EnvironmentObject var quickNotes: QuickNotes
    @EnvironmentObject var jiggler: MouseJiggler
    @EnvironmentObject var autocomplete: Autocomplete
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let v = updater.availableVersion {
            Button("Install Update (\(v))…") { updater.install() }
            Divider()
        }
        if calendar.hasAccess, !calendar.upcomingToday.isEmpty {
            Section("Today") {
                ForEach(calendar.upcomingToday.prefix(3)) { m in MeetingMenuItem(meeting: m) }
            }
            Divider()
        }
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
        if autocomplete.enabled {
            Toggle("AI autocomplete", isOn: Binding(get: { !autocomplete.paused }, set: { autocomplete.paused = !$0 }))
        }
        Toggle("Mouse jiggler (after \(Int(jiggler.idleMinutes)) min idle)", isOn: $jiggler.enabled)
        Toggle("Keyboard cleaning mode", isOn: Binding(get: { keyboard.isOn }, set: { _ in keyboard.toggle() }))
        if keyboard.needsPermission {
            Button("Allow Accessibility Access…") { AccessibilityPermission.shared.request() }
        }
        Divider()
        Button("Command Palette\(shortcuts.palette.shortcut.map { "  (\($0.display))" } ?? "")") {
            NotificationCenter.default.post(name: AppDelegate.openPalette, object: nil)
        }
        Button("Quick Notes\(shortcuts.quickNotes.shortcut.map { "  (\($0.display))" } ?? "")") { quickNotes.showWindow() }
        Button("Settings…") { nav.openSettings(openWindow) }.keyboardShortcut(",")
        Button("Quit FanCurve") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// Settings window navigation (sidebar selection is remembered between openings).
@MainActor
final class AppNav: ObservableObject {
    static let shared = AppNav()
    enum Page: String, CaseIterable, Identifiable {
        case general, fans, displays, mic, keyboard, awake, calendar, snippets, autocomplete, launcher
        static let groups: [[Page]] = [[.general], [.fans, .displays, .mic, .keyboard, .awake], [.launcher, .autocomplete, .calendar, .snippets]]
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .awake: return "Keep Awake"
            case .autocomplete: return "Autocomplete"
            case .calendar: return "Calendar"
            case .snippets: return "Snippets"
            case .launcher: return "Command Palette"
            case .fans: return "Fans"
            case .displays: return "Displays"
            case .mic: return "Microphone"
            case .keyboard: return "Keyboard"
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape.fill"
            case .awake: return "cursorarrow.motionlines"
            case .autocomplete: return "text.cursor"
            case .calendar: return "calendar"
            case .snippets: return "text.quote"
            case .launcher: return "command"
            case .fans: return "fan.fill"
            case .displays: return "display"
            case .mic: return "mic.fill"
            case .keyboard: return "keyboard.fill"
            }
        }
        /// Extra search terms, so e.g. "shortcut" finds Microphone like System Settings' search.
        var keywords: [String] {
            switch self {
            case .general: return ["login", "startup", "update", "version"]
            case .autocomplete: return ["ai", "autocomplete", "cotypist", "suggestions", "gemma", "llm", "typing", "model"]
            case .awake: return ["jiggler", "mouse", "awake", "idle", "sleep", "caffeine", "teams", "slack"]
            case .calendar: return ["meeting", "join", "zoom", "schedule", "agenda", "notification"]
            case .snippets: return ["snippet", "text", "expand", "keyword", "abbreviation"]
            case .launcher: return ["palette", "launcher", "raycast", "search", "apps", "calculator", "obsidian", "notes", "daily note"]
            case .fans: return ["curve", "temperature", "profile", "noctua", "rpm", "cooling"]
            case .displays: return ["brightness", "monitor", "ddc", "light sensor", "keys"]
            case .mic: return ["mute", "shortcut", "microphone", "hotkey"]
            case .keyboard: return ["cleaning", "block", "keys"]
            }
        }
        var tint: Color {
            switch self {
            case .general: return .gray
            case .awake: return .green
            case .autocomplete: return .indigo
            case .calendar: return .red
            case .snippets: return .orange
            case .launcher: return .purple
            case .fans: return .blue
            case .displays: return .indigo
            case .mic: return .red
            case .keyboard: return .gray
            }
        }
    }

    @Published var page: Page = .fans {
        didSet { if page != oldValue && !navigatingHistory { back.append(oldValue); forward.removeAll() } }
    }
    @Published var search = ""
    // Back/forward history, like System Settings' toolbar arrows.
    @Published private(set) var back: [Page] = []
    @Published private(set) var forward: [Page] = []
    private var navigatingHistory = false

    func goBack() { guard let p = back.popLast() else { return }; forward.append(page); move(to: p) }
    func goForward() { guard let p = forward.popLast() else { return }; back.append(page); move(to: p) }
    private func move(to p: Page) { navigatingHistory = true; page = p; navigatingHistory = false }

    var filteredPages: [Page] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Page.allCases }
        return Page.allCases.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.keywords.contains { $0.localizedCaseInsensitiveContains(q) } }
    }

    func openSettings(_ openWindow: OpenWindowAction) {
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Menu for the separate mic status icon.
/// A meeting row in a menu: joins if it has a call link, otherwise opens it in Calendar.
struct MeetingMenuItem: View {
    let meeting: Meeting
    @EnvironmentObject var calendar: CalendarStore

    var body: some View {
        let m = meeting
        let time = m.isOngoing(at: calendar.now) ? "Now" : m.start.formatted(date: .omitted, time: .shortened)
        Button { calendar.join(m) } label: {
            Label("\(time)   \(m.title)" + (m.link != nil ? "  — Join" : ""), systemImage: m.link != nil ? "video.fill" : "calendar")
        }
    }
}

/// Menu for the next-meeting menu bar entry.
struct MeetingMenu: View {
    @EnvironmentObject var calendar: CalendarStore
    @EnvironmentObject var nav: AppNav
    @EnvironmentObject var shortcuts: AppShortcuts
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let m = calendar.joinable, m.link != nil {
            Button("Join \(m.title)\(shortcuts.joinMeeting.shortcut.map { "  (\($0.display))" } ?? "")") { calendar.join(m) }
            Divider()
        }
        Section("Today") {
            if calendar.upcomingToday.isEmpty { Text("No more meetings today") }
            ForEach(calendar.upcomingToday) { m in MeetingMenuItem(meeting: m) }
        }
        let tomorrow = calendar.meetings.filter { !$0.isAllDay && !calendar.isToday($0) }
        if !tomorrow.isEmpty {
            Section("Tomorrow") {
                ForEach(tomorrow.prefix(4)) { m in MeetingMenuItem(meeting: m) }
            }
        }
        Divider()
        Button("Show Schedule\(shortcuts.schedule.shortcut.map { "  (\($0.display))" } ?? "")") {
            LauncherPanel.shared.show(ScheduleSource(calendar: calendar))
        }
        Button("Settings…") { nav.page = .calendar; nav.openSettings(openWindow) }
    }
}

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
