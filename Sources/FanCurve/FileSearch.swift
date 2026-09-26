import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Spotlight file search inside the command palette, like Raycast's "Search Files". It runs `mdfind`
/// (Spotlight's own index) in the background, so it stays useful when ⌘Space has been taken over.
@MainActor
final class FileSearchSource: PanelSource {
    static let shared = FileSearchSource()

    private var current = ""
    private var results: [String] = []
    private var searching = false
    private var pending: Task<Void, Never>?

    var placeholder: String { "Search files with Spotlight…" }

    func willShow() { current = ""; results = [] }

    func items(for text: String) -> [PanelItem] {
        let q = text.trimmingCharacters(in: .whitespaces)
        if q != current { start(q) }
        guard !q.isEmpty else {
            return [PanelItem(id: "files.hint", title: "Type to search your files", subtitle: "Uses Spotlight's index · ↩ opens",
                              symbol: "doc.text.magnifyingglass", tint: .gray) { false }]
        }
        if results.isEmpty {
            return [PanelItem(id: "files.none", title: searching ? "Searching…" : "No files found",
                              symbol: searching ? "hourglass" : "questionmark.folder", tint: .gray) { false }]
        }
        let home = NSHomeDirectory()
        return results.map { path in
            let url = URL(fileURLWithPath: path)
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return PanelItem(id: "file:" + path, section: "Files", title: url.lastPathComponent,
                             subtitle: url.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~"),
                             accessory: date?.formatted(.relative(presentation: .named)),
                             image: NSWorkspace.shared.icon(forFile: path)) {
                NSWorkspace.shared.open(url); return true
            }
        }
    }

    /// Debounced background search; results replace the list when they arrive.
    private func start(_ q: String) {
        current = q
        pending?.cancel()
        guard !q.isEmpty else { results = []; searching = false; return }
        searching = true
        pending = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let found = await Self.mdfind(q)
            guard !Task.isCancelled, q == self.current else { return }
            self.results = found
            self.searching = false
            LauncherPanel.shared.model.reload()
        }
    }

    /// Name search in the home folder and apps; most recently changed first, capped at 60.
    nonisolated private static func mdfind(_ q: String) async -> [String] {
        await Task.detached(priority: .userInitiated) { () -> [String] in
            var paths: [String] = []
            for scope in [NSHomeDirectory(), "/Applications"] {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
                p.arguments = ["-onlyin", scope, "-name", q]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { continue }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                paths += String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            }
            // Your files only: skip hidden folders and ~/Library (app data, logs), except iCloud Drive.
            let lib = NSHomeDirectory() + "/Library/"
            let visible = paths.filter { !$0.contains("/.") && (!$0.hasPrefix(lib) || $0.hasPrefix(lib + "Mobile Documents/")) }
            let dated = visible.prefix(400).map { path -> (String, Date) in
                let d = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return (path, d ?? .distantPast)
            }
            return dated.sorted { $0.1 > $1.1 }.prefix(60).map(\.0)
        }.value
    }

    /// Opens real Spotlight when its ⌘Space shortcut is available; otherwise searches here.
    static func openSpotlightOrSearch(_ query: String = "") {
        if !SpotlightTakeover.spotlightShortcutDisabled {
            let src = CGEventSource(stateID: .combinedSessionState)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Space), keyDown: down)
                e?.flags = .maskCommand
                e?.post(tap: .cghidEventTap)
            }
        } else {
            LauncherPanel.shared.show(shared, query: query)
        }
    }
}
