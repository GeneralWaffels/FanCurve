import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var keyword: String
    var text: String
}

/// Pastes text into the frontmost app by briefly borrowing the clipboard (restored afterwards),
/// the same technique Raycast uses. Needs Accessibility permission to send ⌘V.
@MainActor
enum Paster {
    /// Marks events FanCurve posts itself, so the snippet listener ignores them.
    static let marker: Int64 = 0x4643_5256

    static func paste(_ text: String, cursorOffsetFromEnd: Int = 0) {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
        } ?? []
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))   // tells clipboard managers to skip it

        key(kVK_ANSI_V, flags: .maskCommand)
        if cursorOffsetFromEnd > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { for _ in 0..<cursorOffsetFromEnd { key(kVK_LeftArrow) } }
        }
        // Give the target app time to read the clipboard before restoring it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            pb.clearContents()
            let items = saved.map { dict -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (t, d) in dict { item.setData(d, forType: t) }
                return item
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
    }

    static func key(_ code: Int, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.post(tap: .cghidEventTap)
        }
    }
}

@MainActor
final class SnippetStore: ObservableObject {
    @Published var snippets: [Snippet] = [] { didSet { if snippets != oldValue { save() } } }
    @Published var editing: UUID?
    @Published var expandEnabled: Bool {
        didSet {
            UserDefaults.standard.set(expandEnabled, forKey: "snippetExpand")
            if expandEnabled && !AXIsProcessTrusted() { AccessibilityPermission.shared.request() }
            updateTap()
        }
    }
    @Published private(set) var needsPermission = false

    private let file: URL
    nonisolated(unsafe) private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var buffer = ""

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FanCurve")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("snippets.json")
        expandEnabled = UserDefaults.standard.object(forKey: "snippetExpand") as? Bool ?? true
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode([Snippet].self, from: d) {
            snippets = s
        } else {
            snippets = [
                Snippet(name: "Today's date", keyword: ";date", text: "{date}"),
                Snippet(name: "Current time", keyword: ";time", text: "{time}"),
                Snippet(name: "Shrug", keyword: ";shrug", text: "¯\\_(ツ)_/¯"),
            ]
        }
        updateTap()
    }

    private func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        try? enc.encode(snippets).write(to: file, options: .atomic)
    }

    // MARK: editing

    func add() -> UUID {
        let s = Snippet(name: "New Snippet", keyword: "", text: "")
        snippets.append(s)
        editing = s.id
        return s.id
    }

    func delete(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        if editing == id { editing = nil }
    }

    func binding(_ id: UUID) -> Binding<Snippet>? {
        guard snippets.contains(where: { $0.id == id }) else { return nil }
        return Binding(get: { self.snippets.first { $0.id == id } ?? Snippet(name: "", keyword: "", text: "") },
                       set: { new in if let i = self.snippets.firstIndex(where: { $0.id == id }) { self.snippets[i] = new } })
    }

    /// Keywords used by more than one snippet (only the first would ever expand).
    var duplicateKeywords: Set<String> {
        var seen = Set<String>(), dup = Set<String>()
        for k in snippets.map(\.keyword) where !k.isEmpty { if !seen.insert(k).inserted { dup.insert(k) } }
        return dup
    }

    // MARK: placeholders

    /// Expands {clipboard} {date} {time} {datetime} {day} {uuid}; returns text and how far the cursor
    /// should move back from the end for {cursor}.
    static func render(_ template: String) -> (String, Int) {
        let now = Date()
        var t = template
        let values: [String: String] = [
            "{clipboard}": NSPasteboard.general.string(forType: .string) ?? "",
            "{date}": now.formatted(date: .abbreviated, time: .omitted),
            "{time}": now.formatted(date: .omitted, time: .shortened),
            "{datetime}": now.formatted(date: .abbreviated, time: .shortened),
            "{day}": now.formatted(.dateTime.weekday(.wide)),
            "{uuid}": UUID().uuidString,
        ]
        for (k, v) in values { t = t.replacingOccurrences(of: k, with: v) }
        if let r = t.range(of: "{cursor}") {
            let after = t[r.upperBound...].count
            t.removeSubrange(r)
            return (t, after)
        }
        return (t, 0)
    }

    func insert(_ s: Snippet) {
        let (text, back) = Self.render(s.text)
        Paster.paste(text, cursorOffsetFromEnd: back)
    }

    // MARK: expansion as you type

    func updateTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; buffer = ""
        guard expandEnabled else { needsPermission = false; return }
        guard AXIsProcessTrusted() else {
            needsPermission = true
            AccessibilityPermission.shared.whenGranted { [weak self] in self?.updateTap() }   // starts as soon as it's allowed
            return
        }
        needsPermission = false

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<SnippetStore>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else {
                MainActor.assumeIsolated { me.observe(type, event) }
            }
            // Active tap (covered by Accessibility; a listen-only key tap would need Input Monitoring),
            // but it never swallows: typing always goes through untouched.
            return Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { needsPermission = true; return }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    private func observe(_ type: CGEventType, _ event: CGEvent) {
        guard type == .keyDown else { buffer = ""; return }                  // a click moves the caret
        guard event.getIntegerValueField(.eventSourceUserData) != Paster.marker else { return }
        guard !IsSecureEventInputEnabled() else { buffer = ""; return }       // password fields
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { buffer = ""; return }

        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch code {
        case kVK_Delete: if !buffer.isEmpty { buffer.removeLast() }; return
        case kVK_Return, kVK_Tab, kVK_Escape, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete:
            buffer = ""; return
        default: break
        }
        guard let chars = NSEvent(cgEvent: event)?.characters, !chars.isEmpty else { return }
        buffer += chars
        if buffer.count > 64 { buffer.removeFirst(buffer.count - 64) }

        guard let s = snippets.first(where: { !$0.keyword.isEmpty && buffer.hasSuffix($0.keyword) }) else { return }
        buffer = ""
        let count = s.keyword.count
        // Let the last keystroke land, erase the keyword, then paste the expansion.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            for _ in 0..<count { Paster.key(kVK_Delete) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.insert(s) }
        }
    }
}

// MARK: - Snippet search panel

@MainActor
final class SnippetSource: PanelSource {
    let store: SnippetStore
    init(store: SnippetStore) { self.store = store }

    var placeholder: String { "Search snippets…" }

    func items(for query: String) -> [PanelItem] {
        let items = store.snippets.map { s in
            PanelItem(id: s.id.uuidString, title: s.name.isEmpty ? s.keyword : s.name,
                      subtitle: s.text.replacingOccurrences(of: "\n", with: " ⏎ "),
                      accessory: s.keyword.isEmpty ? nil : s.keyword,
                      symbol: "text.quote", tint: .orange, keywords: [s.keyword, s.text]) { [store] in
                LauncherPanel.shared.returnToPreviousApp { store.insert(s) }
                return true
            }
        }
        if items.isEmpty {
            return [PanelItem(id: "none", title: "No snippets yet", subtitle: "Add them in FanCurve Settings → Snippets",
                              symbol: "text.quote", tint: .orange) { true }]
        }
        return items.filtered(query)
    }
}
