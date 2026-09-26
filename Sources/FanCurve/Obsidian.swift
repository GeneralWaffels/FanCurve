import AppKit
import SwiftUI

/// Obsidian integration for the command palette, in the spirit of Raycast's Obsidian extension:
/// search notes (titles and text), open vaults, create notes, open and append to the daily note.
@MainActor
final class Obsidian: ObservableObject {
    struct Vault: Identifiable, Hashable { var id: String { path }; let name: String; let path: String }
    struct Note: Identifiable {
        var id: String { rel }
        let rel: String          // path inside the vault, e.g. "04 People/Jane Doe.md"
        let title: String
        let folder: String
        let modified: Date
        let body: String         // lowercased text for content search (first 32 KB)
    }

    @Published private(set) var vaults: [Vault] = []
    @Published private(set) var notes: [Note] = []
    @Published private(set) var indexing = false
    @Published var vaultPath: String {
        didSet { save("obsVault", vaultPath); notes = []; lastIndex = nil; loadVaultSettings(); reindex() }
    }
    /// Daily note location as a Moment-style pattern relative to the vault, e.g. "02 Daily/YYYY/MM/MM-DD-YY ddd".
    @Published var dailyPattern: String { didSet { save(dailyKey, dailyPattern) } }
    @Published var newNoteFolder: String { didSet { save("obsNewFolder:" + vaultPath, newNoteFolder) } }
    @Published var timestampAppends: Bool { didSet { UserDefaults.standard.set(timestampAppends, forKey: "obsTimestamp") } }

    private var lastIndex: Date?
    private var dailyKey: String { "obsDaily:" + vaultPath }

    var installed: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") != nil }
    var vault: Vault? { vaults.first { $0.path == vaultPath } }
    var appIcon: NSImage? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian").map { NSWorkspace.shared.icon(forFile: $0.path) } }

    init() {
        let list = Self.readVaults()
        vaults = list.map(\.vault)
        let saved = UserDefaults.standard.string(forKey: "obsVault")
        vaultPath = saved.flatMap { p in list.first { $0.vault.path == p }?.vault.path }
            ?? list.first { $0.open }?.vault.path ?? list.first?.vault.path ?? ""
        dailyPattern = ""
        newNoteFolder = ""
        timestampAppends = UserDefaults.standard.bool(forKey: "obsTimestamp")
        loadVaultSettings()
    }

    private func save(_ key: String, _ value: String) { UserDefaults.standard.set(value, forKey: key) }

    private func loadVaultSettings() {
        dailyPattern = Self.dailyFromCorePlugin(vaultPath) ?? UserDefaults.standard.string(forKey: dailyKey) ?? ""
        newNoteFolder = UserDefaults.standard.string(forKey: "obsNewFolder:" + vaultPath) ?? ""
    }

    /// Vaults registered in Obsidian (~/Library/Application Support/obsidian/obsidian.json).
    private static func readVaults() -> [(vault: Vault, open: Bool)] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let d = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let vaults = json["vaults"] as? [String: [String: Any]] else { return [] }
        return vaults.values.compactMap { v in
            guard let path = v["path"] as? String, FileManager.default.fileExists(atPath: path) else { return nil }
            return (Vault(name: URL(fileURLWithPath: path).lastPathComponent, path: path), v["open"] as? Bool ?? false)
        }
        .sorted { ($0.open ? 0 : 1, $0.vault.name) < ($1.open ? 0 : 1, $1.vault.name) }
    }

    /// Obsidian's Daily Notes template path, if one is configured (e.g. "Templates/Daily").
    private var dailyTemplate: String? {
        let url = URL(fileURLWithPath: vaultPath).appendingPathComponent(".obsidian/daily-notes.json")
        guard let d = try? Data(contentsOf: url), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let t = j["template"] as? String, !t.isEmpty else { return nil }
        return t.hasSuffix(".md") ? t : t + ".md"
    }

    /// True when the daily format comes from Obsidian's own Daily Notes settings.
    var dailyFromObsidian: Bool { Self.dailyFromCorePlugin(vaultPath) != nil }

    /// Daily note pattern from the core Daily Notes plugin, if configured.
    private static func dailyFromCorePlugin(_ vault: String) -> String? {
        let url = URL(fileURLWithPath: vault).appendingPathComponent(".obsidian/daily-notes.json")
        guard let d = try? Data(contentsOf: url), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let folder = (j["folder"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let format = (j["format"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "YYYY-MM-DD"
        // Folder names are literal text (e.g. "Daily" would otherwise read as a day-of-month token).
        let literal = folder.split(separator: "/").map { "[" + $0 + "]" }.joined(separator: "/")
        return folder.isEmpty ? format : literal + "/" + format
    }

    // MARK: index

    /// Rebuilds the note index in the background (at most once a minute unless forced).
    func reindex(force: Bool = false) {
        reloadVaults()
        guard !vaultPath.isEmpty, !indexing else { return }
        if !force, let t = lastIndex, Date().timeIntervalSince(t) < 60 { return }
        indexing = true
        let root = vaultPath
        Task.detached(priority: .utility) {
            let notes = Self.scan(root)
            await MainActor.run {
                guard root == self.vaultPath else { self.indexing = false; return }
                self.notes = notes
                self.lastIndex = Date()
                self.indexing = false
                if self.dailyPattern.isEmpty, let p = self.detectDailyPattern() { self.dailyPattern = p }
                LauncherPanel.shared.model.reload()
            }
        }
    }

    nonisolated private static func scan(_ root: String) -> [Note] {
        let base = URL(fileURLWithPath: root)
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [Note] = []
        for case let url as URL in e {
            let rel = url.path.replacingOccurrences(of: root + "/", with: "")
            if rel.hasPrefix(".trash") { e.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "md" else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let body = (try? FileHandle(forReadingFrom: url)).map { h -> String in
                defer { try? h.close() }
                return String(decoding: (try? h.read(upToCount: 32_768)) ?? Data(), as: UTF8.self).lowercased()
            } ?? ""
            out.append(Note(rel: rel, title: url.deletingPathExtension().lastPathComponent,
                            folder: (rel as NSString).deletingLastPathComponent, modified: modified, body: body))
        }
        return out
    }

    // MARK: search

    /// Title matches first, then path, then body text.
    func search(_ query: String, limit: Int = 40) -> [(note: Note, snippet: String?)] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return recent(limit).map { ($0, nil) } }
        var scored: [(Note, Int, String?)] = []
        for n in notes {
            let t = n.title.lowercased()
            if t == q { scored.append((n, 100, nil)) }
            else if t.hasPrefix(q) { scored.append((n, 90, nil)) }
            else if t.contains(q) { scored.append((n, 70, nil)) }
            else if n.rel.lowercased().contains(q) { scored.append((n, 50, nil)) }
            else if let r = n.body.range(of: q) {
                let start = n.body.index(r.lowerBound, offsetBy: -40, limitedBy: n.body.startIndex) ?? n.body.startIndex
                let end = n.body.index(r.upperBound, offsetBy: 60, limitedBy: n.body.endIndex) ?? n.body.endIndex
                let snippet = n.body[start..<end].replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                scored.append((n, 30, "…" + snippet + "…"))
            }
        }
        return scored.sorted { ($0.1, $0.0.modified) > ($1.1, $1.0.modified) }.prefix(limit).map { ($0.0, $0.2) }
    }

    func recent(_ n: Int) -> [Note] { Array(notes.sorted { $0.modified > $1.modified }.prefix(n)) }

    // MARK: actions

    private func uri(_ path: String) -> URL? {
        var c = URLComponents(string: "obsidian://open")
        c?.queryItems = [URLQueryItem(name: "path", value: path)]
        return c?.url
    }

    func open(_ note: Note) { open(absolutePath: vaultPath + "/" + note.rel) }

    func open(absolutePath: String) { if let u = uri(absolutePath) { NSWorkspace.shared.open(u) } }

    func openVault() {
        var c = URLComponents(string: "obsidian://open")
        c?.queryItems = [URLQueryItem(name: "vault", value: vault?.name ?? "")]
        if let u = c?.url { NSWorkspace.shared.open(u) }
    }

    func openRandom() { if let n = notes.randomElement() { open(n) } else { NSSound.beep() } }

    /// Creates "<folder>/<title>.md" (or opens it if it already exists).
    func createNote(_ title: String) {
        let clean = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !vaultPath.isEmpty else { NSSound.beep(); return }
        let folder = newNoteFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let dir = folder.isEmpty ? vaultPath : vaultPath + "/" + folder
        let path = dir + "/" + clean + ".md"
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: Data())
        }
        open(absolutePath: path)
        lastIndex = nil
    }

    // MARK: daily note

    /// Today's daily note path (absolute), from the pattern.
    func dailyPath(for date: Date = Date()) -> String? {
        let p = dailyPattern.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !p.isEmpty, !vaultPath.isEmpty else { return nil }
        let rel = MomentFormat.format(p, date)
        return vaultPath + "/" + (rel.hasSuffix(".md") ? rel : rel + ".md")
    }

    var dailyExists: Bool { dailyPath().map { FileManager.default.fileExists(atPath: $0) } ?? false }

    func openDaily() {
        guard let path = dailyPath() else { NotificationCenter.default.post(name: AppDelegate.openSettings, object: nil); return }
        ensureDaily(path)
        open(absolutePath: path)
    }

    /// Appends a line ("- text", optionally "- HH:mm text") to today's daily note, creating it if needed.
    func appendToDaily(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, let path = dailyPath() else { NSSound.beep(); return }
        ensureDaily(path)
        let stamp = timestampAppends ? Date().formatted(date: .omitted, time: .shortened) + " " : ""
        append("- " + stamp + line, to: path)
    }

    /// Appends one line at the end of a note (adding a newline first if the file doesn't end with one).
    /// Read+write handle and Swift's throwing APIs: the legacy calls raise uncatchable ObjC exceptions.
    private func append(_ line: String, to path: String) {
        guard let h = FileHandle(forUpdatingAtPath: path) else { NSSound.beep(); return }
        defer { try? h.close() }
        do {
            let end = try h.seekToEnd()
            var prefix = ""
            if end > 0 {
                try h.seek(toOffset: end - 1)
                if try h.read(upToCount: 1) != Data("\n".utf8) { prefix = "\n" }
                try h.seekToEnd()
            }
            try h.write(contentsOf: Data((prefix + line + "\n").utf8))
        } catch {
            NSSound.beep()
        }
        lastIndex = nil
    }

    private func ensureDaily(_ path: String) {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var text = ""
        if let t = dailyTemplate, let tpl = try? String(contentsOfFile: vaultPath + "/" + t, encoding: .utf8) {
            let now = Date()
            text = tpl.replacingOccurrences(of: "{{date}}", with: MomentFormat.format("YYYY-MM-DD", now))
                .replacingOccurrences(of: "{{time}}", with: now.formatted(date: .omitted, time: .shortened))
                .replacingOccurrences(of: "{{title}}", with: ((path as NSString).lastPathComponent as NSString).deletingPathExtension)
        }
        FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
    }

    /// Adds "- [ ] text" to Inbox.md (the vault's capture note) or, without one, today's daily note.
    func addTask(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !vaultPath.isEmpty else { NSSound.beep(); return }
        let inbox = vaultPath + "/Inbox.md"
        let target = FileManager.default.fileExists(atPath: inbox) ? inbox : dailyPath()
        guard let target else { NSSound.beep(); return }
        if target != inbox { ensureDaily(target) }
        append("- [ ] " + t, to: target)
    }

    /// Where Add Task writes, for display.
    var taskTarget: String { FileManager.default.fileExists(atPath: vaultPath + "/Inbox.md") ? "Inbox" : "today's daily note" }

    func reloadVaults() {
        let list = Self.readVaults().map(\.vault)
        if list != vaults { vaults = list }
    }

    /// Finds a recent daily note in any common date format and turns its path into a pattern,
    /// e.g. "02 Daily/2026/09/09-26-26 Sat.md" → "02 Daily/YYYY/MM/MM-DD-YY ddd".
    func detectDailyPattern() -> String? {
        let formats = ["YYYY-MM-DD", "MM-DD-YY ddd", "YYYY-MM-DD ddd", "DD-MM-YYYY", "MM-DD-YYYY", "DD-MM-YY", "YYYY.MM.DD", "YYYYMMDD", "YYYY-MM-DD dddd"]
        let byName = Dictionary(notes.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
        for offset in 0..<21 {
            let day = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
            for f in formats {
                guard let n = byName[MomentFormat.format(f, day)] else { continue }
                let parts = n.folder.split(separator: "/").map(String.init).map { comp -> String in
                    if comp == MomentFormat.format("YYYY", day) { return "YYYY" }
                    if comp == MomentFormat.format("MM", day) { return "MM" }
                    if comp == MomentFormat.format("MMMM", day) { return "MMMM" }
                    if comp == MomentFormat.format("YYYY-MM", day) { return "YYYY-MM" }
                    return "[" + comp + "]"
                }
                return (parts + [f]).joined(separator: "/")
            }
        }
        return nil
    }
}

/// Minimal Moment.js-style date formatting (the syntax Obsidian uses): YYYY YY MMMM MMM MM M DD D dddd ddd,
/// and [literal text].
enum MomentFormat {
    static func format(_ pattern: String, _ date: Date) -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day, .weekday], from: date)
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
        let tokens: [(String, () -> String)] = [
            ("YYYY", { String(format: "%04d", c.year!) }),
            ("YY", { String(format: "%02d", c.year! % 100) }),
            ("MMMM", { df.monthSymbols[c.month! - 1] }),
            ("MMM", { df.shortMonthSymbols[c.month! - 1] }),
            ("MM", { String(format: "%02d", c.month!) }),
            ("M", { String(c.month!) }),
            ("DD", { String(format: "%02d", c.day!) }),
            ("D", { String(c.day!) }),
            ("dddd", { df.weekdaySymbols[c.weekday! - 1] }),
            ("ddd", { df.shortWeekdaySymbols[c.weekday! - 1] }),
        ]
        var out = "", i = pattern.startIndex
        outer: while i < pattern.endIndex {
            if pattern[i] == "[", let close = pattern[i...].firstIndex(of: "]") {
                out += pattern[pattern.index(after: i)..<close]
                i = pattern.index(after: close)
                continue
            }
            for (t, v) in tokens where pattern[i...].hasPrefix(t) {
                out += v()
                i = pattern.index(i, offsetBy: t.count)
                continue outer
            }
            out.append(pattern[i]); i = pattern.index(after: i)
        }
        return out
    }
}

// MARK: - Palette source

@MainActor
final class ObsidianSource: PanelSource {
    let obs: Obsidian
    init(obs: Obsidian) { self.obs = obs }

    var placeholder: String { "Search notes, or type to create / capture…" }
    func willShow() { obs.reindex() }

    func items(for query: String) -> [PanelItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var items: [PanelItem] = []
        let tint = Color.purple
        if !q.isEmpty {
            items.append(PanelItem(id: "obs.task", section: "Capture", title: "Add Task",
                                   subtitle: "“\(q)” → \(obs.taskTarget)", symbol: "checkmark.circle", tint: tint) { [obs] in obs.addTask(q); return true })
            items.append(PanelItem(id: "obs.append", section: "Capture", title: "Append to Daily Note",
                                   subtitle: "“\(q)”", symbol: "text.append", tint: tint) { [obs] in obs.appendToDaily(q); return true })
            items.append(PanelItem(id: "obs.create", section: "Capture", title: "Create Note “\(q)”",
                                   subtitle: obs.newNoteFolder.isEmpty ? "In the vault's root folder" : "In \(obs.newNoteFolder)",
                                   symbol: "square.and.pencil", tint: tint) { [obs] in obs.createNote(q); return true })
        } else {
            items += Self.actions(obs)
        }
        let results = obs.search(q)
        items += results.map { r in
            PanelItem(id: "obs.note." + r.note.rel, section: q.isEmpty ? "Recent Notes" : "Notes", title: r.note.title,
                      subtitle: r.snippet ?? (r.note.folder.isEmpty ? obs.vault?.name : r.note.folder),
                      accessory: r.note.modified.formatted(.relative(presentation: .named)),
                      image: obs.appIcon, keywords: []) { [obs] in obs.open(r.note); return true }
        }
        if obs.notes.isEmpty && obs.indexing {
            items.append(PanelItem(id: "obs.indexing", section: "Notes", title: "Indexing notes…", symbol: "hourglass", tint: .gray) { false })
        }
        return items   // already ranked; no fuzzy re-filtering so content matches stay
    }

    /// Commands shared with the root palette.
    static func actions(_ obs: Obsidian) -> [PanelItem] {
        let tint = Color.purple
        return [
            PanelItem(id: "obs.daily", section: "Obsidian", title: "Open Daily Note",
                      subtitle: obs.dailyPath().map { ($0 as NSString).lastPathComponent } ?? "Set the daily note format in Settings",
                      symbol: "calendar.day.timeline.left", tint: tint, keywords: ["obsidian", "daily", "journal", "today"]) { obs.openDaily(); return true },
            PanelItem(id: "obs.vault", section: "Obsidian", title: "Open Vault", subtitle: obs.vault?.name,
                      symbol: "books.vertical.fill", tint: tint, keywords: ["obsidian", "vault"]) { obs.openVault(); return true },
            PanelItem(id: "obs.random", section: "Obsidian", title: "Open Random Note", symbol: "shuffle", tint: tint,
                      keywords: ["obsidian", "random", "note"]) { obs.openRandom(); return true },
        ] + obs.vaults.filter { $0.path != obs.vaultPath }.map { v in
            PanelItem(id: "obs.switch." + v.path, section: "Obsidian", title: "Switch to \(v.name)",
                      subtitle: "Search and capture in this vault instead", symbol: "arrow.left.arrow.right", tint: tint,
                      keywords: ["obsidian", "vault", "switch", v.name]) { obs.vaultPath = v.path; return false }
        }
    }
}

// MARK: - Settings

struct ObsidianSection: View {
    @EnvironmentObject var obs: Obsidian

    var body: some View {
        Section {
            if obs.vaults.isEmpty {
                StatusRow(text: "No Obsidian vaults found. Open a vault in Obsidian once and it will appear here.", color: .secondary)
            } else {
                Picker("Vault", selection: $obs.vaultPath) {
                    ForEach(obs.vaults) { Text($0.name).tag($0.path) }
                }
                TextField("Daily note format", text: $obs.dailyPattern, prompt: Text("e.g. Daily/YYYY-MM-DD"))
                    .font(.body.monospaced())
                    .disabled(obs.dailyFromObsidian)
                    .help(obs.dailyFromObsidian ? "Set in Obsidian → Settings → Daily notes" : "")
                LabeledContent("Today's daily note") {
                    if let p = obs.dailyPath() {
                        HStack(spacing: 6) {
                            Text(p.replacingOccurrences(of: obs.vaultPath + "/", with: "")).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            Image(systemName: obs.dailyExists ? "checkmark.circle.fill" : "plus.circle")
                                .foregroundStyle(obs.dailyExists ? .green : .secondary)
                                .help(obs.dailyExists ? "Exists" : "Will be created on first use")
                        }
                    } else {
                        Button("Detect") { if let p = obs.detectDailyPattern() { obs.dailyPattern = p } }
                    }
                }
                TextField("New notes folder", text: $obs.newNoteFolder, prompt: Text("Vault root"))
                Toggle("Add the time to daily note entries", isOn: $obs.timestampAppends)
                LabeledContent("Notes indexed") {
                    HStack {
                        Text(obs.indexing ? "Indexing…" : "\(obs.notes.count)").monospacedDigit().foregroundStyle(.secondary)
                        Button("Rebuild") { obs.reindex(force: true) }.disabled(obs.indexing)
                    }
                }
            }
        } header: {
            Text("Obsidian")
        } footer: {
            Footer("Type \"obsidian\" or a note name in the palette. In the Obsidian view, type anything to search note titles and text, append it to today's daily note, or create a note. Date format uses Obsidian's syntax: YYYY MM DD ddd, and [text] for literal folder names.")
        }
        .onAppear { obs.reindex() }
    }
}
