import AppKit
import SwiftUI

/// AeroSpace (tiling window manager) integration for the command palette: live commands via the
/// `aerospace` CLI, plus config toggles that edit ~/.aerospace.toml and reload it.
@MainActor
final class AeroSpace: ObservableObject {
    struct Window: Identifiable, Equatable { let id: String; let app: String; let title: String; let workspace: String }

    @Published private(set) var installed = false
    @Published private(set) var running = false
    @Published private(set) var version: String?
    @Published private(set) var workspaces: [String] = []
    @Published private(set) var focusedWorkspace: String?
    @Published private(set) var windows: [Window] = []
    @Published private(set) var focusedLayout: String?
    @Published private(set) var lastError: String?
    /// Gap size used by "Turn On Gaps".
    @Published var gapSize: Int { didSet { UserDefaults.standard.set(gapSize, forKey: "aeroGapSize") } }

    private let cli: String?
    let configURL: URL

    /// `configURL` override is for tests; normally AeroSpace's own lookup order is used.
    init(configURL: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let xdg = home.appendingPathComponent(".config/aerospace/aerospace.toml")
        self.configURL = configURL ?? (FileManager.default.fileExists(atPath: xdg.path) ? xdg : home.appendingPathComponent(".aerospace.toml"))
        cli = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace", "/Applications/AeroSpace.app/Contents/Resources/bin/aerospace"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        installed = cli != nil
        gapSize = UserDefaults.standard.object(forKey: "aeroGapSize") as? Int ?? 8
    }

    // MARK: CLI

    /// Runs `aerospace <args>` off the main thread with a timeout (the CLI waits for the server).
    nonisolated private static func exec(_ cli: String, _ args: [String], timeout: TimeInterval = 3) -> (ok: Bool, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return (false, error.localizedDescription) }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(10_000) }
        if p.isRunning { p.terminate(); return (false, "AeroSpace didn't respond") }
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (p.terminationStatus == 0, p.terminationStatus == 0 ? o : (e.isEmpty ? o : e))
    }

    /// Runs a command, then refreshes state. Errors show in Settings and as a beep.
    func run(_ args: [String]) {
        guard let cli else { NSSound.beep(); return }
        Task.detached {
            let r = Self.exec(cli, args)
            await MainActor.run {
                self.lastError = r.ok ? nil : r.out.trimmingCharacters(in: .whitespacesAndNewlines)
                if !r.ok { NSSound.beep() }
                self.refresh()
            }
        }
    }

    /// Reloads workspaces, windows and layout (called when the palette opens).
    func refresh(then: (() -> Void)? = nil) {
        guard let cli else { then?(); return }
        Task.detached {
            let v = Self.exec(cli, ["--version"])
            let ws = Self.exec(cli, ["list-workspaces", "--all"])
            let focused = Self.exec(cli, ["list-workspaces", "--focused"])
            let wins = Self.exec(cli, ["list-windows", "--all", "--format", "%{window-id}|%{app-name}|%{window-title}|%{workspace}"])
            let layout = Self.exec(cli, ["list-windows", "--focused", "--format", "%{window-layout}"])
            await MainActor.run {
                self.running = ws.ok
                self.version = v.out.split(separator: "\n").last.flatMap { $0.split(separator: ":").last }?
                    .trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)
                self.workspaces = ws.ok ? ws.out.split(separator: "\n").map(String.init) : []
                self.focusedWorkspace = focused.ok ? focused.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
                self.windows = wins.ok ? wins.out.split(separator: "\n").compactMap { line in
                    let f = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                    return f.count == 4 ? Window(id: f[0], app: f[1], title: f[2], workspace: f[3]) : nil
                } : []
                self.focusedLayout = layout.ok ? layout.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
                then?()
            }
        }
    }

    func launch() { NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/AeroSpace.app"), configuration: .init()) }

    // MARK: config file

    private var config: String { (try? String(contentsOf: configURL, encoding: .utf8)) ?? "" }

    /// Value of a top-level `key = value` line (before the first [section]).
    func topLevel(_ key: String) -> String? {
        for line in config.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { break }
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "="),
                  t[..<eq].trimmingCharacters(in: .whitespaces) == key else { continue }
            return t[t.index(after: eq)...].split(separator: "#").first?.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    func bool(_ key: String) -> Bool? { topLevel(key).map { $0 == "true" } }

    /// Current gap size (all [gaps] values equal), or nil when mixed.
    var gaps: Int? {
        let values = gapLines().map(\.value)
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    private func gapLines() -> [(index: Int, value: Int)] {
        var inGaps = false, out: [(Int, Int)] = []
        for (i, line) in config.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { inGaps = t == "[gaps]"; continue }
            guard inGaps, !t.hasPrefix("#"), let eq = t.firstIndex(of: "="),
                  let v = Int(t[t.index(after: eq)...].split(separator: "#").first?.trimmingCharacters(in: .whitespaces) ?? "") else { continue }
            out.append((i, v))
        }
        return out
    }

    /// Rewrites lines, keeping comments and layout intact, then reloads AeroSpace.
    private func edit(_ transform: (inout [String]) -> Bool) {
        var lines = config.components(separatedBy: "\n")
        guard !lines.isEmpty, transform(&lines) else { NSSound.beep(); return }
        let backup = configURL.appendingPathExtension("fancurve-backup")
        if !FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.copyItem(at: configURL, to: backup) }
        do {
            try lines.joined(separator: "\n").write(to: configURL, atomically: true, encoding: .utf8)
            objectWillChange.send()
            run(["reload-config"])
        } catch {
            lastError = "Couldn't write \(configURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func setTopLevel(_ key: String, _ value: String) {
        edit { lines in
            let end = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
            if let i = lines[..<end].firstIndex(where: {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return !t.hasPrefix("#") && t.split(separator: "=").first?.trimmingCharacters(in: .whitespaces) == key
            }) {
                lines[i] = "\(key) = \(value)"
            } else {
                lines.insert("\(key) = \(value)", at: end)
            }
            return true
        }
    }

    func setGaps(_ size: Int) {
        let targets = gapLines()
        guard !targets.isEmpty else { lastError = "No [gaps] section found in the config."; NSSound.beep(); return }
        edit { lines in
            for (i, _) in targets {
                // Replace only the number, keeping the user's alignment and any trailing comment.
                let line = lines[i]
                guard let eq = line.firstIndex(of: "="),
                      let num = line[eq...].range(of: #"-?\d+"#, options: .regularExpression) else { continue }
                lines[i] = line.replacingCharacters(in: num, with: String(size))
            }
            return true
        }
    }

    func openConfig() { NSWorkspace.shared.open(configURL) }
}

// MARK: - Palette source

@MainActor
final class AeroSpaceSource: PanelSource {
    let aero: AeroSpace
    init(aero: AeroSpace) { self.aero = aero }

    var placeholder: String { "Search AeroSpace commands, workspaces and windows…" }

    func items(for query: String) -> [PanelItem] { Self.items(aero, includeWindows: true).filtered(query) }

    func willShow() { aero.refresh { LauncherPanel.shared.model.reload() } }

    /// Shared with the root palette. `includeWindows` adds a row per window (focus it).
    static func items(_ a: AeroSpace, includeWindows: Bool) -> [PanelItem] {
        guard a.installed else { return [] }
        let tint = Color.teal
        func cmd(_ id: String, _ title: String, _ sub: String? = nil, _ symbol: String, _ args: [String], _ kw: [String] = []) -> PanelItem {
            PanelItem(id: "aero." + id, section: "AeroSpace", title: title, subtitle: sub, symbol: symbol, tint: tint,
                      keywords: ["aerospace", "tiling", "window"] + kw) { a.run(args); return true }
        }
        guard a.running else {
            return [PanelItem(id: "aero.launch", section: "AeroSpace", title: "Start AeroSpace", subtitle: "AeroSpace isn't running",
                              symbol: "rectangle.3.group", tint: tint, keywords: ["aerospace", "tiling"]) { a.launch(); return true }]
        }

        var items: [PanelItem] = [
            cmd("enable", "Toggle Tiling (AeroSpace On/Off)", "Temporarily stop or resume window management", "power", ["enable", "toggle"], ["enable", "disable"]),
            cmd("float", a.focusedLayout == "floating" ? "Tile Focused Window" : "Float Focused Window", nil, "macwindow.on.rectangle",
                ["layout", "floating", "tiling"], ["float", "floating"]),
            cmd("tiles", "Layout: Tiles", "Alternate horizontal and vertical", "rectangle.split.3x1", ["layout", "tiles", "horizontal", "vertical"], ["layout", "tiles"]),
            cmd("accordion", "Layout: Accordion", nil, "rectangle.stack", ["layout", "accordion", "horizontal", "vertical"], ["layout", "accordion"]),
            cmd("orientation", "Flip Orientation", "Horizontal ↔ vertical", "arrow.left.arrow.right", ["layout", "horizontal", "vertical"], ["rotate", "orientation"]),
            cmd("fullscreen", "Toggle Fullscreen", nil, "arrow.up.left.and.arrow.down.right", ["fullscreen"], ["fullscreen", "maximize"]),
            cmd("balance", "Balance Window Sizes", nil, "equal.square", ["balance-sizes"], ["balance", "equal"]),
            cmd("flatten", "Flatten Workspace Tree", "Reset nested splits", "square.3.layers.3d.down.right", ["flatten-workspace-tree"], ["flatten", "reset"]),
            cmd("monitor", "Move Workspace to Next Monitor", nil, "display.2", ["move-workspace-to-monitor", "--wrap-around", "next"], ["monitor", "display"]),
            cmd("backforth", "Previous Workspace", nil, "arrow.uturn.backward", ["workspace-back-and-forth"], ["back", "previous"]),
            cmd("reload", "Reload AeroSpace Config", nil, "arrow.clockwise", ["reload-config"], ["reload", "config"]),
            PanelItem(id: "aero.config", section: "AeroSpace", title: "Open AeroSpace Config", subtitle: a.configURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                      symbol: "doc.text", tint: tint, keywords: ["aerospace", "config", "edit", "toml"]) { a.openConfig(); return true },
        ]

        // Settings (edit the config file, then reload).
        let gapsOn = (a.gaps ?? 0) > 0
        items.append(PanelItem(id: "aero.set.gaps", section: "AeroSpace Settings", title: gapsOn ? "Turn Off Window Gaps" : "Turn On Window Gaps (\(a.gapSize) pt)",
                               subtitle: "Currently \(a.gaps.map { "\($0) pt" } ?? "mixed")", symbol: "square.grid.2x2", tint: tint,
                               keywords: ["aerospace", "gaps", "padding", "spacing", "setting"]) { a.setGaps(gapsOn ? 0 : a.gapSize); return true })
        let login = a.bool("start-at-login") ?? false
        items.append(PanelItem(id: "aero.set.login", section: "AeroSpace Settings", title: login ? "Don't Start AeroSpace at Login" : "Start AeroSpace at Login",
                               subtitle: "Currently \(login ? "on" : "off")", symbol: "person.badge.clock", tint: tint,
                               keywords: ["aerospace", "login", "startup", "setting"]) { a.setTopLevel("start-at-login", login ? "false" : "true"); return true })
        let layout = a.topLevel("default-root-container-layout")?.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) ?? "tiles"
        items.append(PanelItem(id: "aero.set.layout", section: "AeroSpace Settings",
                               title: "Default Layout: \(layout == "tiles" ? "Accordion" : "Tiles")",
                               subtitle: "New workspaces currently use \(layout)", symbol: "rectangle.3.group", tint: tint,
                               keywords: ["aerospace", "default", "layout", "setting"]) {
            a.setTopLevel("default-root-container-layout", layout == "tiles" ? "'accordion'" : "'tiles'"); return true
        })
        let unhide = a.bool("automatically-unhide-macos-hidden-apps") ?? false
        items.append(PanelItem(id: "aero.set.unhide", section: "AeroSpace Settings",
                               title: unhide ? "Stop Unhiding Hidden Apps" : "Automatically Unhide Hidden Apps",
                               subtitle: "Apps hidden with ⌘H · currently \(unhide ? "unhidden" : "left hidden")", symbol: "eye", tint: tint,
                               keywords: ["aerospace", "hide", "unhide", "setting"]) {
            a.setTopLevel("automatically-unhide-macos-hidden-apps", unhide ? "false" : "true"); return true
        })
        let flatten = a.bool("enable-normalization-flatten-containers") ?? true
        items.append(PanelItem(id: "aero.set.flatten", section: "AeroSpace Settings",
                               title: flatten ? "Allow Nested Containers" : "Flatten Containers Automatically",
                               subtitle: "Normalization · currently \(flatten ? "flattening" : "nesting allowed")", symbol: "square.stack.3d.up", tint: tint,
                               keywords: ["aerospace", "normalization", "flatten", "setting"]) {
            a.setTopLevel("enable-normalization-flatten-containers", flatten ? "false" : "true"); return true
        })

        // Workspaces: go to / move window there. Show app names so workspaces are recognisable.
        for ws in a.workspaces {
            let apps = Array(Set(a.windows.filter { $0.workspace == ws }.map(\.app))).sorted()
            let focused = ws == a.focusedWorkspace
            items.append(PanelItem(id: "aero.ws." + ws, section: "Workspaces", title: "Workspace \(ws)",
                                   subtitle: apps.isEmpty ? "Empty" : apps.joined(separator: ", "), accessory: focused ? "Current" : "⌥\(ws)",
                                   symbol: "square.on.square", tint: focused ? .accentColor : tint,
                                   keywords: ["workspace", "space", "desktop", ws] + apps) { a.run(["workspace", ws]); return true })
        }
        for ws in a.workspaces where ws != a.focusedWorkspace {
            items.append(PanelItem(id: "aero.mv." + ws, section: "Move Window", title: "Move Window to Workspace \(ws)",
                                   accessory: "⌥⇧\(ws)", symbol: "arrow.right.square", tint: tint,
                                   keywords: ["move", "send", "workspace", ws]) { a.run(["move-node-to-workspace", "--focus-follows-window", ws]); return true })
        }
        if includeWindows {
            for w in a.windows {
                items.append(PanelItem(id: "aero.win." + w.id, section: "Windows", title: w.title.isEmpty ? w.app : w.title,
                                       subtitle: "\(w.app) · Workspace \(w.workspace)", accessory: nil,
                                       image: NSWorkspace.shared.runningApplications.first { $0.localizedName == w.app }?.icon,
                                       keywords: [w.app, "window", "focus"]) { a.run(["focus", "--window-id", w.id]); return true })
            }
        }
        return items
    }
}
