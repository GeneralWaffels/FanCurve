import AppKit
import SwiftUI

/// Raycast-style quick notes: a floating window with a note list and an editor that saves as you type.
/// Notes are plain Markdown files in ~/Library/Application Support/FanCurve/Quick Notes; "Send to
/// Obsidian" moves one into the current vault's Notes folder.
@MainActor
final class QuickNotes: ObservableObject {
    struct Note: Identifiable, Equatable {
        let id: String            // file name
        var text: String
        var modified: Date
        var title: String {
            let first = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            let t = first.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
            return t.isEmpty ? "New Note" : String(t.prefix(60))
        }
    }

    @Published private(set) var notes: [Note] = []
    @Published var selection: String?
    @Published var showList: Bool { didSet { UserDefaults.standard.set(showList, forKey: "qnList") } }
    @Published var alwaysOnTop: Bool { didSet { UserDefaults.standard.set(alwaysOnTop, forKey: "qnTop"); window?.level = alwaysOnTop ? .floating : .normal } }

    weak var obsidian: Obsidian?
    let folder: URL
    /// The app's instance (used by the debug snapshot tool).
    static weak var current: QuickNotes?
    var windowNumber: Int? { window?.windowNumber }
    private var window: NSPanel?
    private var saveTasks: [String: Task<Void, Never>] = [:]

    init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FanCurve/Quick Notes")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        showList = UserDefaults.standard.object(forKey: "qnList") as? Bool ?? true
        alwaysOnTop = UserDefaults.standard.object(forKey: "qnTop") as? Bool ?? true
        load()
        Self.current = self
        selection = UserDefaults.standard.string(forKey: "qnSelection").flatMap { id in notes.contains { $0.id == id } ? id : nil }
            ?? notes.first?.id
    }

    // MARK: storage

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        notes = files.filter { $0.pathExtension == "md" }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            return Note(id: url.lastPathComponent, text: text, modified: date)
        }
        .sorted { $0.modified > $1.modified }
    }

    var selected: Note? { notes.first { $0.id == selection } }

    func binding(for id: String) -> Binding<String> {
        Binding(get: { self.notes.first { $0.id == id }?.text ?? "" },
                set: { self.update(id, text: $0) })
    }

    /// Updates a note and saves it shortly after typing pauses.
    func update(_ id: String, text: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].text != text else { return }
        notes[i].text = text
        notes[i].modified = Date()
        saveTasks[id]?.cancel()
        let url = folder.appendingPathComponent(id)
        saveTasks[id] = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @discardableResult
    func create(_ text: String = "") -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmmss"
        var name = "Note \(f.string(from: Date())).md", n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "Note \(f.string(from: Date())) \(n).md"; n += 1
        }
        try? text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        notes.insert(Note(id: name, text: text, modified: Date()), at: 0)
        select(name)
        return name
    }

    func select(_ id: String?) {
        selection = id
        UserDefaults.standard.set(id, forKey: "qnSelection")
    }

    func delete(_ id: String) {
        let alert = NSAlert()
        alert.messageText = "Delete this note?"
        alert.informativeText = "It's moved to the Trash, so you can still restore it."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.trashItem(at: folder.appendingPathComponent(id), resultingItemURL: nil)
        notes.removeAll { $0.id == id }
        select(notes.first?.id)
    }

    /// Moves the note into the current Obsidian vault's Notes/ folder (named after its first line) and opens it.
    func sendToObsidian(_ id: String) {
        guard let obs = obsidian, let vault = obs.vault, let note = notes.first(where: { $0.id == id }) else { NSSound.beep(); return }
        let safe = note.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let dir = URL(fileURLWithPath: vault.path).appendingPathComponent("Notes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dest = dir.appendingPathComponent(safe + ".md"), n = 2
        while FileManager.default.fileExists(atPath: dest.path) { dest = dir.appendingPathComponent("\(safe) \(n).md"); n += 1 }
        saveTasks[id]?.cancel()
        do {
            try note.text.write(to: dest, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: folder.appendingPathComponent(id))
            notes.removeAll { $0.id == id }
            select(notes.first?.id)
            obs.open(absolutePath: dest.path)
        } catch {
            NSSound.beep()
        }
    }

    func search(_ q: String) -> [Note] {
        let s = q.lowercased().trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return notes }
        return notes.filter { $0.text.lowercased().contains(s) }
    }

    // MARK: window

    func toggleWindow() { (window?.isVisible ?? false) && window?.isKeyWindow == true ? window?.orderOut(nil) : showWindow() }

    func showWindow(select id: String? = nil) {
        if let id { select(id) }
        if notes.isEmpty { create() }
        if selection == nil { select(notes.first?.id) }
        let w = window ?? makeWindow()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSPanel {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
                        backing: .buffered, defer: false)
        w.title = "Quick Notes"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        w.level = alwaysOnTop ? .floating : .normal
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.minSize = NSSize(width: 360, height: 240)
        w.setFrameAutosaveName("FanCurveQuickNotes")
        if w.frame.origin == .zero { w.center() }
        w.contentView = NSHostingView(rootView: QuickNotesView(store: self))
        return w
    }
}

// MARK: - Window content

struct QuickNotesView: View {
    @ObservedObject var store: QuickNotes

    var body: some View {
        HStack(spacing: 0) {
            if store.showList {
                list.frame(width: 190)
                Divider()
            }
            VStack(spacing: 0) {
                toolbar
                if let id = store.selection {
                    NoteEditor(text: store.binding(for: id)).id(id)
                } else {
                    Text("No note selected").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(.regularMaterial)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Spacer().frame(width: store.showList ? 0 : 64)   // room for the traffic lights
            Button { store.showList.toggle() } label: { Image(systemName: "sidebar.left") }.help("Show or hide notes")
            Text(store.selected?.title ?? "").font(.headline).lineLimit(1)
            Spacer()
            Button { store.alwaysOnTop.toggle() } label: {
                Image(systemName: store.alwaysOnTop ? "pin.fill" : "pin")
            }
            .help(store.alwaysOnTop ? "Stays on top of other windows" : "Keep on top of other windows")
            if let id = store.selection {
                Button { store.sendToObsidian(id) } label: { Image(systemName: "arrow.up.doc") }
                    .help("Move to Obsidian (\(store.obsidian?.vault?.name ?? "no vault")) → Notes")
                    .disabled(store.obsidian?.vault == nil)
                Button { store.delete(id) } label: { Image(systemName: "trash") }.help("Delete note")
            }
            Button { store.create() } label: { Image(systemName: "square.and.pencil") }
                .keyboardShortcut("n", modifiers: .command).help("New note (⌘N)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 14))
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 38)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.notes) { note in
                        Button { store.select(note.id) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.title).lineLimit(1)
                                Text(note.modified.formatted(.relative(presentation: .named)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(store.selection == note.id ? Color.accentColor.opacity(0.18) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
        }
    }
}

/// Plain-text editor (NSTextView) with comfortable writing defaults; focuses itself when shown.
struct NoteEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.string = text
        tv.font = .systemFont(ofSize: 15)
        tv.textContainerInset = NSSize(width: 18, height: 10)
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = true
        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let tv = scroll.documentView as! NSTextView
        if tv.string != text { tv.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteEditor
        init(parent: NoteEditor) { self.parent = parent }
        func textDidChange(_ n: Notification) {
            if let tv = n.object as? NSTextView { parent.text = tv.string }
        }
    }
}

// MARK: - Palette source

@MainActor
final class QuickNotesSource: PanelSource {
    let store: QuickNotes
    init(store: QuickNotes) { self.store = store }

    var placeholder: String { "Search quick notes, or type to create one…" }

    func items(for query: String) -> [PanelItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var items: [PanelItem] = []
        if !q.isEmpty {
            items.append(PanelItem(id: "qn.new", section: "Create", title: "New Quick Note", subtitle: "“\(q)”",
                                   symbol: "square.and.pencil", tint: .yellow) { [store] in
                store.showWindow(select: store.create(q)); return true
            })
        } else {
            items.append(PanelItem(id: "qn.blank", section: "Create", title: "New Quick Note", subtitle: "Blank note",
                                   symbol: "square.and.pencil", tint: .yellow) { [store] in
                store.showWindow(select: store.create()); return true
            })
        }
        items += store.search(q).map { n in
            PanelItem(id: "qn." + n.id, section: "Quick Notes", title: n.title,
                      subtitle: n.text.split(separator: "\n").dropFirst().first.map { String($0.prefix(80)) },
                      accessory: n.modified.formatted(.relative(presentation: .named)),
                      symbol: "note.text", tint: .yellow) { [store] in store.showWindow(select: n.id); return true }
        }
        return items
    }
}
