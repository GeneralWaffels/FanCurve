import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

/// Pinned apps: shown first in the command palette, launchable with ⌘1–9 in the palette and,
/// optionally, globally with ⌃⌥1–9 (chosen because AeroSpace's defaults use ⌥1–9 without ⌃).
@MainActor
final class Favourites: ObservableObject {
    struct App: Codable, Identifiable, Equatable {
        var id: String { path }
        let path: String
        var name: String
    }

    @Published private(set) var apps: [App] = [] { didSet { save(); registerHotKeys() } }
    @Published var globalShortcuts: Bool { didSet { UserDefaults.standard.set(globalShortcuts, forKey: "favGlobal"); registerHotKeys() } }
    /// Favourite slots whose ⌃⌥N combination is skipped because AeroSpace (or another app) owns it.
    @Published private(set) var blockedSlots: [Int: String] = [:]

    weak var aero: AeroSpace? { didSet { registerHotKeys() } }
    private static let hotKeyBase: UInt32 = 100

    init() {
        globalShortcuts = UserDefaults.standard.object(forKey: "favGlobal") as? Bool ?? true
        if let d = UserDefaults.standard.data(forKey: "favourites"), let a = try? JSONDecoder().decode([App].self, from: d) {
            apps = a.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        registerHotKeys()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(apps) { UserDefaults.standard.set(d, forKey: "favourites") }
    }

    func contains(_ url: URL) -> Bool { apps.contains { $0.path == url.path } }

    func toggle(_ url: URL) { contains(url) ? remove(url.path) : add(url) }

    func add(_ url: URL) {
        guard !contains(url) else { return }
        apps.append(App(path: url.path, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")))
    }

    func remove(_ path: String) { apps.removeAll { $0.path == path } }

    func move(_ path: String, by delta: Int) {
        guard let i = apps.firstIndex(where: { $0.path == path }) else { return }
        let j = min(max(i + delta, 0), apps.count - 1)
        guard i != j else { return }
        var a = apps; a.swapAt(i, j); apps = a
    }

    func launch(_ index: Int) {
        guard apps.indices.contains(index) else { NSSound.beep(); return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: apps[index].path), configuration: .init())
    }

    /// Resolves links first (e.g. /Applications/Safari.app), so icons don't get an alias badge.
    func icon(_ app: App) -> NSImage { NSWorkspace.shared.icon(forFile: URL(fileURLWithPath: app.path).resolvingSymlinksInPath().path) }

    /// "⌃⌥3" for slot 2, or nil if global shortcuts are off / the slot is past 9 / it's blocked.
    func shortcutLabel(_ index: Int) -> String? {
        guard globalShortcuts, index < 9, blockedSlots[index] == nil else { return nil }
        return "⌃⌥\(index + 1)"
    }

    private func registerHotKeys() {
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        var blocked: [Int: String] = [:]
        for slot in 0..<9 {
            let id = Self.hotKeyBase + UInt32(slot)
            let shortcut = Shortcut(keyCode: UInt32(digits[slot]), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥\(slot + 1)")
            guard globalShortcuts, slot < apps.count else { HotKeys.shared.register(id: id, shortcut: nil) {}; continue }
            if let action = aero?.binding(for: shortcut) {
                blocked[slot] = "AeroSpace: \(action)"
                HotKeys.shared.register(id: id, shortcut: nil) {}
                continue
            }
            if !HotKeys.shared.register(id: id, shortcut: shortcut, action: { [weak self] in self?.launch(slot) }) {
                blocked[slot] = "another app"
            }
        }
        if blocked != blockedSlots { blockedSlots = blocked }
    }

    /// Opens a picker in /Applications to add apps.
    func chooseApps() {
        let panel = NSOpenPanel()
        panel.title = "Add Favourite Apps"
        panel.prompt = "Add"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { panel.urls.forEach(add) }
    }
}

// MARK: - AeroSpace binding lookup

extension Shortcut {
    /// The same key combination in AeroSpace's config notation, e.g. "alt-shift-h", "ctrl-alt-space".
    var aerospaceNotation: String? {
        var mods: [String] = []
        if modifiers & UInt32(cmdKey) != 0 { mods.append("cmd") }
        if modifiers & UInt32(controlKey) != 0 { mods.append("ctrl") }
        if modifiers & UInt32(optionKey) != 0 { mods.append("alt") }
        if modifiers & UInt32(shiftKey) != 0 { mods.append("shift") }
        let key = display.drop { "⌃⌥⇧⌘".contains($0) }.lowercased()
        let names = [",": "comma", "/": "slash", "-": "minus", "=": "equal", ";": "semicolon", ".": "period", "'": "quote",
                     "`": "backtick", "[": "leftSquareBracket", "]": "rightSquareBracket", "\\": "backslash"]
        let k = names[key] ?? key
        guard !k.isEmpty else { return nil }
        return (mods + [k]).joined(separator: "-")
    }
}

extension AeroSpace {
    /// Key bindings from the [mode.main.binding] section: notation → command.
    var bindings: [String: String] {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return [:] }
        var inMain = false, out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { inMain = t == "[mode.main.binding]"; continue }
            guard inMain, !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            let key = t[..<eq].trimmingCharacters(in: .whitespaces)
            let value = t[t.index(after: eq)...].split(separator: "#").first?.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\"[]")) ?? ""
            out[Self.normalize(key)] = value
        }
        return out
    }

    /// AeroSpace accepts modifiers in any order; compare them sorted.
    private static func normalize(_ combo: String) -> String {
        var parts = combo.lowercased().split(separator: "-").map(String.init)
        guard let key = parts.popLast() else { return combo }
        return (parts.sorted() + [key]).joined(separator: "-")
    }

    /// The AeroSpace command bound to this shortcut, if any.
    func binding(for s: Shortcut) -> String? {
        guard installed, let n = s.aerospaceNotation else { return nil }
        return bindings[Self.normalize(n)]
    }
}

// MARK: - Settings UI

struct FavouritesSection: View {
    @EnvironmentObject var favs: Favourites

    var body: some View {
        Section {
            if favs.apps.isEmpty {
                HStack(spacing: 12) {
                    IconTile(symbol: "star.fill", tint: .yellow, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No favourites yet")
                        Text("Add apps here, or press ⌘F on an app in the command palette.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            ForEach(Array(favs.apps.enumerated()), id: \.element.id) { i, app in
                HStack(spacing: 10) {
                    Image(nsImage: favs.icon(app)).resizable().frame(width: 26, height: 26)
                    Text(app.name)
                    Spacer()
                    if let label = favs.shortcutLabel(i) {
                        Text(label).font(.callout.monospaced()).foregroundStyle(.secondary)
                    } else if let why = favs.blockedSlots[i] {
                        Text("⌃⌥\(i + 1) taken by \(why)").font(.caption).foregroundStyle(.orange)
                    }
                    ControlGroup {
                        Button { favs.move(app.path, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
                        Button { favs.move(app.path, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(i == favs.apps.count - 1)
                    }
                    .controlSize(.small).fixedSize()
                    Button { favs.remove(app.path) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless).help("Remove from favourites")
                }
            }
            Button { favs.chooseApps() } label: { Label("Add Apps…", systemImage: "plus") }.buttonStyle(.borderless)
            Toggle("Launch favourites from anywhere with ⌃⌥1–9", isOn: $favs.globalShortcuts)
        } header: {
            Text("Favourites")
        } footer: {
            Footer("Favourites appear first in the command palette; press ⌘1–9 there to launch one. ⌃⌥1–9 doesn't clash with AeroSpace, which uses ⌥1–9 for workspaces.")
        }
    }
}
