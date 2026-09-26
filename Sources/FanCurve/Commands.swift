import AppKit
import Carbon.HIToolbox
import SMCKit
import SwiftUI

/// The Raycast-style command palette: FanCurve actions, meetings, snippets, apps, a calculator
/// and a few system commands, all in one searchable list.
@MainActor
final class CommandSource: PanelSource {
    struct Deps {
        let model: Model
        let mic: MicMuter
        let keyboard: KeyboardBlocker
        let displays: Displays
        let calendar: CalendarStore
        let snippets: SnippetStore
        let updater: Updater
        let aero: AeroSpace
        let favourites: Favourites
        let obsidian: Obsidian
        let quickNotes: QuickNotes
        let jiggler: MouseJiggler
        let autocomplete: Autocomplete
        let openSettings: () -> Void
    }

    private let d: Deps
    private var apps: [(name: String, url: URL)] = []
    private var appsScanned: Date?

    init(_ deps: Deps) { d = deps }

    var placeholder: String { "Search for apps and commands…" }

    func willShow() {
        // Fresh workspace/window list each time; rows update in place when it arrives.
        if d.aero.installed { d.aero.refresh { LauncherPanel.shared.model.reload() } }
        if d.obsidian.installed { d.obsidian.reindex() }
    }

    func items(for query: String) -> [PanelItem] {
        scanAppsIfNeeded()
        var out: [PanelItem] = []

        // Calculator: an answer row on top whenever the query is arithmetic.
        if let value = Calculator.evaluate(query) {
            let text = Calculator.format(value)
            out.append(PanelItem(id: "calc", section: "Calculator", title: text, subtitle: query.trimmingCharacters(in: .whitespaces) + " =",
                                 accessory: "Copy", symbol: "equal", tint: .orange) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); return true
            })
        }

        var commands = fanCommands() + meetingCommands() + utilityCommands() + obsidianCommands() + aeroCommands() + systemCommands()
        let favs = d.favourites
        let favItems = favs.apps.enumerated().map { i, app in
            PanelItem(id: "fav:" + app.path, section: "Favourites", title: app.name, subtitle: nil,
                      accessory: i < 9 ? "⌘\(i + 1)" : nil, image: favs.icon(app),
                      appURL: URL(fileURLWithPath: app.path), boost: 15) {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: .init()); return true
            }
        }
        let appItems = apps.filter { !favs.contains($0.url) }.map { app in
            PanelItem(id: "app:" + app.url.path, section: "Applications", title: app.name, subtitle: nil, accessory: "Application",
                      image: NSWorkspace.shared.icon(forFile: app.url.resolvingSymlinksInPath().path), appURL: app.url) {
                NSWorkspace.shared.openApplication(at: app.url, configuration: .init()); return true
            }
        }

        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            // Empty query: favourites, then suggestions, like Raycast's root search.
            commands = Array(meetingCommands().prefix(3)) + fanCommands().prefix(2) + utilityCommands().prefix(4) + aeroCommands().prefix(1)
            return out + favItems + commands.map { var i = $0; i.section = "Suggestions"; return i }
        }
        commands = favItems + commands + appItems
        let q = query.trimmingCharacters(in: .whitespaces)
        let newNote = PanelItem(id: "qn.newroot", section: "Create", title: "New Quick Note", subtitle: "“\(q)”",
                                symbol: "square.and.pencil", tint: .yellow) { [d] in d.quickNotes.showWindow(select: d.quickNotes.create(q)); return true }
        let searchFiles = PanelItem(id: "files.for", section: "Files", title: "Search Files for “\(q)”",
                                    subtitle: "Spotlight", symbol: "doc.text.magnifyingglass", tint: .gray) {
            LauncherPanel.shared.show(FileSearchSource.shared, query: q); return true
        }
        // Matching Obsidian notes (titles only here; the Obsidian view also searches text).
        if d.obsidian.installed, query.trimmingCharacters(in: .whitespaces).count >= 2 {
            let obs = d.obsidian
            let notes = obs.search(query, limit: 30).filter { $0.snippet == nil }.prefix(5).map { r in
                PanelItem(id: "obs.root." + r.note.rel, section: "Obsidian Notes", title: r.note.title,
                          subtitle: r.note.folder.isEmpty ? obs.vault?.name : r.note.folder, accessory: "Note",
                          image: obs.appIcon) { obs.open(r.note); return true }
            }
            return out + commands.filtered(query) + notes + [newNote, searchFiles]
        }
        return out + commands.filtered(query) + (q.count >= 2 ? [newNote, searchFiles] : [])
    }

    // MARK: sections

    private func fanCommands() -> [PanelItem] {
        let m = d.model
        var items = [
            PanelItem(id: "fan.toggle", section: "Fans", title: m.config.enabled ? "Turn Off Fan Curve" : "Turn On Fan Curve",
                      subtitle: "Currently \(m.config.enabled ? "on" : "off") · \(m.activeProfile ?? "custom curve")",
                      symbol: "fan.fill", tint: .blue, keywords: ["fan", "curve", "cooling"]) { m.config.enabled.toggle(); return true },
        ]
        for name in FanConfig.presetOrder + m.customProfileNames {
            items.append(PanelItem(id: "fan.profile." + name, section: "Fans", title: "Fan Profile: \(name)",
                                   accessory: m.activeProfile == name ? "Active" : nil,
                                   symbol: "fan", tint: .blue, keywords: ["profile", "fan", name]) {
                m.applyPreset(name); m.config.enabled = true; return true
            })
        }
        return items
    }

    private func meetingCommands() -> [PanelItem] {
        let cal = d.calendar
        var items: [PanelItem] = []
        if let m = cal.joinable {
            items.append(PanelItem(id: "meet.join", section: "Calendar", title: "Join \(m.title)",
                                   subtitle: "\(m.timeRange) · \(m.link?.service ?? "")", accessory: cal.relative(m),
                                   symbol: "video.fill", tint: m.color, keywords: ["join", "meeting", "call", "zoom", "meet", "teams"]) {
                cal.join(m); return true
            })
        }
        items.append(PanelItem(id: "meet.schedule", section: "Calendar", title: "My Schedule",
                               subtitle: cal.next.map { "Next: \($0.title) · \(cal.relative($0))" } ?? "Today and tomorrow",
                               symbol: "calendar", tint: .red, keywords: ["schedule", "calendar", "agenda", "today", "meetings"]) {
            LauncherPanel.shared.show(ScheduleSource(calendar: cal)); return true
        })
        return items
    }

    private func utilityCommands() -> [PanelItem] {
        let mic = d.mic, kb = d.keyboard, disp = d.displays, snips = d.snippets
        var items = [
            PanelItem(id: "mic", section: "FanCurve", title: mic.isMuted ? "Unmute Microphone" : "Mute Microphone",
                      accessory: mic.shortcut?.display, symbol: mic.isMuted ? "mic.slash.fill" : "mic.fill", tint: .red,
                      keywords: ["mute", "mic", "microphone", "unmute"]) { mic.toggle(); return true },
            PanelItem(id: "qn.open", section: "FanCurve", title: "Quick Notes", subtitle: "Open the notes window",
                      accessory: "⌃⌥N", symbol: "note.text", tint: .yellow,
                      keywords: ["note", "notes", "quick", "scratch", "jot", "raycast notes"]) { [d] in d.quickNotes.showWindow(); return true },
            PanelItem(id: "qn.search", section: "FanCurve", title: "Search Quick Notes", symbol: "doc.text.magnifyingglass", tint: .yellow,
                      keywords: ["note", "notes", "search"]) { [d] in LauncherPanel.shared.show(QuickNotesSource(store: d.quickNotes)); return true },
            PanelItem(id: "snippets", section: "FanCurve", title: "Search Snippets", symbol: "text.quote", tint: .orange,
                      keywords: ["snippet", "text", "expand", "paste"]) {
                LauncherPanel.shared.show(SnippetSource(store: snips)); return true
            },
            PanelItem(id: "autocomplete", section: "FanCurve",
                      title: !d.autocomplete.enabled ? "Turn On AI Autocomplete" : d.autocomplete.paused ? "Resume AI Autocomplete" : "Pause AI Autocomplete",
                      subtitle: "Local model suggestions as you type", accessory: "⌃⌥A", symbol: "text.cursor", tint: .indigo,
                      keywords: ["ai", "autocomplete", "suggestions", "cotypist", "typing"]) { [d] in
                if d.autocomplete.enabled { d.autocomplete.paused.toggle() } else { d.autocomplete.enabled = true }
                return true
            },
            PanelItem(id: "jiggle", section: "FanCurve", title: d.jiggler.enabled ? "Turn Off Mouse Jiggler" : "Turn On Mouse Jiggler",
                      subtitle: "Keeps the Mac awake after \(Int(d.jiggler.idleMinutes)) min idle", symbol: "cursorarrow.motionlines", tint: .green,
                      keywords: ["jiggler", "mouse", "awake", "caffeine", "idle", "sleep"]) { [d] in d.jiggler.toggle(); return true },
            PanelItem(id: "clean", section: "FanCurve", title: kb.isOn ? "Stop Keyboard Cleaning" : "Keyboard Cleaning Mode",
                      symbol: "keyboard.fill", tint: .gray, keywords: ["clean", "keyboard", "block"]) { kb.toggle(); return true },
            PanelItem(id: "settings", section: "FanCurve", title: "FanCurve Settings", accessory: "⌘,", symbol: "gearshape.fill", tint: .gray,
                      keywords: ["settings", "preferences"]) { [d] in d.openSettings(); return true },
        ]
        if !disp.monitors.isEmpty {
            for v in [0, 25, 50, 75, 100] {
                items.append(PanelItem(id: "bright.\(v)", section: "Displays", title: "External Brightness \(v)%",
                                       symbol: v >= 50 ? "sun.max.fill" : "sun.min.fill", tint: .indigo,
                                       keywords: ["brightness", "monitor", "display", "\(v)"]) { disp.setAll(Double(v)); return true })
            }
            items.append(PanelItem(id: "bright.auto", section: "Displays",
                                   title: disp.followSensor ? "Stop Matching Light Sensor" : "Match Laptop Light Sensor",
                                   symbol: "light.max", tint: .indigo, keywords: ["auto", "brightness", "sensor"]) {
                disp.followSensor.toggle(); return true
            })
        }
        if let v = d.updater.availableVersion {
            items.insert(PanelItem(id: "update", section: "FanCurve", title: "Install FanCurve Update", subtitle: "Version \(v)",
                                   symbol: "arrow.down.circle.fill", tint: .blue, keywords: ["update"]) { [d] in d.updater.install(); return true }, at: 0)
        }
        return items
    }

    private func obsidianCommands() -> [PanelItem] {
        let obs = d.obsidian
        guard obs.installed, obs.vault != nil else { return [] }
        let open = PanelItem(id: "obs.open", section: "Obsidian", title: "Obsidian",
                             subtitle: "Search notes, capture to your daily note, create notes", accessory: obs.vault?.name,
                             image: obs.appIcon, keywords: ["obsidian", "notes", "vault", "search notes"]) {
            LauncherPanel.shared.show(ObsidianSource(obs: obs)); return true
        }
        return [open] + ObsidianSource.actions(obs)
    }

    /// AeroSpace entry point plus its commands/settings/workspaces (windows only in its own view).
    private func aeroCommands() -> [PanelItem] {
        let aero = d.aero
        guard aero.installed else { return [] }
        let open = PanelItem(id: "aero.open", section: "AeroSpace", title: "AeroSpace",
                             subtitle: aero.running ? "Workspaces, windows, layouts and settings" : "Not running",
                             accessory: aero.focusedWorkspace.map { "Workspace \($0)" }, symbol: "rectangle.3.group", tint: .teal,
                             keywords: ["aerospace", "tiling", "window manager", "workspace"]) {
            LauncherPanel.shared.show(AeroSpaceSource(aero: aero)); return true
        }
        return [open] + AeroSpaceSource.items(aero, includeWindows: false)
    }

    private func systemCommands() -> [PanelItem] {
        [
            PanelItem(id: "sys.lock", section: "System", title: "Lock Screen", symbol: "lock.fill", tint: .gray, keywords: ["lock"]) {
                Paster.key(kVK_ANSI_Q, flags: [.maskControl, .maskCommand]); return true
            },
            PanelItem(id: "sys.sleep", section: "System", title: "Sleep", symbol: "moon.fill", tint: .indigo, keywords: ["sleep"]) {
                Self.run("/usr/bin/pmset", ["sleepnow"]); return true
            },
            PanelItem(id: "sys.saver", section: "System", title: "Start Screen Saver", symbol: "sparkles.tv.fill", tint: .teal,
                      keywords: ["screensaver"]) {
                Self.run("/usr/bin/open", ["-a", "ScreenSaverEngine"]); return true
            },
            PanelItem(id: "sys.spotlight", section: "System", title: "Spotlight Search",
                      subtitle: SpotlightTakeover.spotlightShortcutDisabled ? "Search files with Spotlight, right here" : "Open macOS Spotlight",
                      symbol: "magnifyingglass", tint: .gray, keywords: ["spotlight", "search", "find", "files", "documents"]) {
                FileSearchSource.openSpotlightOrSearch(); return true
            },
            PanelItem(id: "sys.dark", section: "System", title: "Toggle Dark Mode", symbol: "circle.lefthalf.filled", tint: .gray,
                      keywords: ["dark", "light", "appearance"]) {
                Self.run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"])
                return true
            },
        ]
    }

    private static func run(_ tool: String, _ args: [String]) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        try? p.run()
    }

    // MARK: apps

    private func scanAppsIfNeeded() {
        if let t = appsScanned, Date().timeIntervalSince(t) < 300 { return }
        appsScanned = Date()
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                    fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var seen = Set<String>()
        apps = dirs.flatMap { dir -> [(String, URL)] in
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".app") }.compactMap { name in
                let n = String(name.dropLast(4))
                guard seen.insert(n).inserted else { return nil }
                return (n, URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
        .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }
}

/// Tiny safe arithmetic evaluator (+ − × ÷ ^ %, parentheses, decimals). NSExpression is avoided
/// because malformed input raises an Objective-C exception Swift can't catch.
enum Calculator {
    static func evaluate(_ input: String) -> Double? {
        let s = input.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "")
        guard s.contains(where: { "+-*/^%(".contains($0) }), s.contains(where: \.isNumber),
              s.allSatisfy({ "0123456789.+-*/^%()".contains($0) }) else { return nil }
        var p = Parser(chars: Array(s))
        guard let v = p.expr(), p.i == p.chars.count, v.isFinite else { return nil }
        return v
    }

    static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        let f = NumberFormatter(); f.maximumFractionDigits = 10; f.minimumFractionDigits = 0; f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        return f.string(from: v as NSNumber) ?? "\(v)"
    }

    private struct Parser {
        let chars: [Character]
        var i = 0

        mutating func expr() -> Double? {
            guard var v = term() else { return nil }
            while i < chars.count, chars[i] == "+" || chars[i] == "-" {
                let op = chars[i]; i += 1
                guard let r = term() else { return nil }
                v = op == "+" ? v + r : v - r
            }
            return v
        }

        mutating func term() -> Double? {
            guard var v = power() else { return nil }
            while i < chars.count, "*/%".contains(chars[i]) {
                let op = chars[i]; i += 1
                guard let r = power() else { return nil }
                switch op { case "*": v *= r; case "/": v /= r; default: v = v.truncatingRemainder(dividingBy: r) }
            }
            return v
        }

        mutating func power() -> Double? {
            guard let b = unary() else { return nil }
            if i < chars.count, chars[i] == "^" { i += 1; guard let e = power() else { return nil }; return pow(b, e) }
            return b
        }

        mutating func unary() -> Double? {
            if i < chars.count, chars[i] == "-" { i += 1; return unary().map { -$0 } }
            if i < chars.count, chars[i] == "+" { i += 1; return unary() }
            return atom()
        }

        mutating func atom() -> Double? {
            guard i < chars.count else { return nil }
            if chars[i] == "(" {
                i += 1
                guard let v = expr(), i < chars.count, chars[i] == ")" else { return nil }
                i += 1; return v
            }
            let start = i
            while i < chars.count, chars[i].isNumber || chars[i] == "." { i += 1 }
            return i > start ? Double(String(chars[start..<i])) : nil
        }
    }
}
