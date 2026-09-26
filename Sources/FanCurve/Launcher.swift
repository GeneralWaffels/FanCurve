import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Saved global shortcuts

/// A user-configurable global shortcut, persisted in UserDefaults and registered with HotKeys.
@MainActor
final class ShortcutSetting: ObservableObject {
    @Published var shortcut: Shortcut? { didSet { save(); register() } }
    @Published private(set) var conflict = false

    private let key: String
    private let id: UInt32
    private let action: () -> Void

    init(key: String, id: UInt32, default def: Shortcut?, action: @escaping () -> Void) {
        self.key = key; self.id = id; self.action = action
        if let d = UserDefaults.standard.data(forKey: key) { shortcut = d.isEmpty ? nil : try? JSONDecoder().decode(Shortcut.self, from: d) }
        else { shortcut = def }
        register()
    }

    private func save() {
        UserDefaults.standard.set(shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: key)
    }

    private func register() {
        conflict = !HotKeys.shared.register(id: id, shortcut: shortcut) { [weak self] in self?.action() }
    }
}

extension Shortcut {
    static func ctrlOpt(_ key: Int, _ letter: String) -> Shortcut {
        Shortcut(keyCode: UInt32(key), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥" + letter)
    }
}

/// Row with a shortcut recorder plus a conflict warning, for Settings pages.
struct ShortcutRow: View {
    let title: String
    @ObservedObject var setting: ShortcutSetting

    var body: some View {
        LabeledContent(title) { ShortcutRecorder(shortcut: $setting.shortcut) }
        if setting.conflict, let s = setting.shortcut {
            StatusRow(text: "\(s.display) is already used by macOS or another app. Pick a different combination.", color: .red)
        }
    }
}

// MARK: - Floating panel (Raycast-style)

/// One result row in the floating panel.
struct PanelItem: Identifiable {
    let id: String
    var section: String? = nil
    let title: String
    var subtitle: String? = nil
    var accessory: String? = nil
    var symbol: String = "circle"
    var image: NSImage? = nil
    var tint: Color = .accentColor
    var keywords: [String] = []
    /// Run when the row is chosen. Return false to keep the panel open.
    let run: () -> Bool
}

/// Supplies rows for a panel mode (commands, schedule, snippets, …).
@MainActor
protocol PanelSource: AnyObject {
    var placeholder: String { get }
    func items(for query: String) -> [PanelItem]
    /// Called each time the panel opens with this source (e.g. to refresh live data).
    func willShow()
}

extension PanelSource {
    func willShow() {}
}

@MainActor
final class PanelModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { reload() } } }
    @Published private(set) var items: [PanelItem] = []
    @Published var selection = 0
    var source: PanelSource? { didSet { query = ""; reload() } }

    func reload() {
        items = source?.items(for: query) ?? []
        selection = min(selection, max(items.count - 1, 0))
        if query.isEmpty || selection >= items.count { selection = 0 }
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = (selection + delta + items.count) % items.count
    }
}

/// Borderless, key-capable floating panel centred on the active screen. Closes when it loses focus.
@MainActor
final class LauncherPanel: NSObject, NSWindowDelegate {
    static let shared = LauncherPanel()

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    let model = PanelModel()
    private var panel: Panel?
    /// The app that was in front before the panel opened (so snippets paste into it).
    private(set) var previousApp: NSRunningApplication?

    var isVisible: Bool { panel?.isVisible ?? false }
    var windowNumber: Int? { panel?.windowNumber }

    func toggle(_ source: PanelSource) {
        if isVisible, model.source === source { close() } else { show(source) }
    }

    func show(_ source: PanelSource) {
        if !isVisible { previousApp = NSWorkspace.shared.frontmostApplication }
        source.willShow()
        model.source = source
        let panel = self.panel ?? make()
        self.panel = panel
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + f.height * 0.62 - size.height / 2))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() { panel?.orderOut(nil) }

    /// Runs the selected row; closes unless the row asks to stay open.
    func runSelected() {
        guard model.items.indices.contains(model.selection) else { return }
        let item = model.items[model.selection]
        close()
        if !item.run() { show(model.source!) }
    }

    /// Hands focus back to the app that was in front, then runs `then` (e.g. a paste).
    func returnToPreviousApp(then: @escaping () -> Void) {
        previousApp?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: then)
    }

    /// Debug snapshots render the panel while another window has focus; don't auto-close then.
    var keepOpenOnResign = false

    func windowDidResignKey(_ notification: Notification) { if !keepOpenOnResign { close() } }

    private func make() -> Panel {
        let p = Panel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
                      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.delegate = self
        p.contentView = NSHostingView(rootView: LauncherView(model: model, panel: self))
        return p
    }
}

struct LauncherView: View {
    @ObservedObject var model: PanelModel
    let panel: LauncherPanel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .medium)).foregroundStyle(.secondary)
                PanelSearchField(text: $model.query, placeholder: model.source?.placeholder ?? "Search",
                                 onMove: { model.move($0) }, onSubmit: { panel.runSelected() }, onCancel: { panel.close() })
            }
            .padding(.horizontal, 18)
            .frame(height: 56)

            Divider().opacity(0.5)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if model.items.isEmpty {
                            Text("No results").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                        }
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            if let section = item.section, index == 0 || model.items[index - 1].section != section {
                                Text(section).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 12).padding(.top, index == 0 ? 6 : 12).padding(.bottom, 2)
                            }
                            PanelRow(item: item, selected: index == model.selection)
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture { model.selection = index; panel.runSelected() }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: model.selection) { _, i in
                    if model.items.indices.contains(i) { proxy.scrollTo(model.items[i].id) }
                }
            }

            Divider().opacity(0.5)
            HStack(spacing: 14) {
                Image(systemName: "fan.fill").foregroundStyle(.blue)
                Text("FanCurve").foregroundStyle(.secondary)
                Spacer()
                KeyHint(keys: "↩", label: "Open")
                KeyHint(keys: "↑↓", label: "Navigate")
                KeyHint(keys: "esc", label: "Close")
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .frame(height: 36)
        }
        .frame(width: 680, height: 420)
        .modifier(PanelBackground())
    }
}

private struct PanelRow: View {
    let item: PanelItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let image = item.image {
                Image(nsImage: image).resizable().frame(width: 28, height: 28)
            } else {
                IconTile(symbol: item.symbol, tint: item.tint, size: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if let s = item.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if let a = item.accessory { Text(a).font(.callout.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(.horizontal, 10)
        .frame(height: item.subtitle == nil ? 40 : 46)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Color.primary.opacity(0.1) : .clear))
    }
}

private struct KeyHint: View {
    let keys: String
    let label: String
    var body: some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(.secondary)
            Text(keys).padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
        }
    }
}

private struct PanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

/// Large borderless search field that routes ↑ ↓ ↩ esc to the panel.
struct PanelSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 20, weight: .regular)
        f.delegate = context.coordinator
        f.cell?.lineBreakMode = .byTruncatingTail
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
        f.placeholderString = placeholder
        DispatchQueue.main.async { if f.window?.firstResponder !== f.currentEditor() { f.window?.makeFirstResponder(f) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PanelSearchField
        init(parent: PanelSearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            if let f = obj.object as? NSTextField { parent.text = f.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1); return true
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1); return true
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
            default: return false
            }
        }
    }
}

// MARK: - Fuzzy match

extension PanelItem {
    /// Simple subsequence match with a preference for prefix/word-start hits (Raycast-like).
    func score(_ query: String) -> Int? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        var best: Int?
        for text in [title] + keywords {
            let t = text.lowercased()
            if t.hasPrefix(q) { best = max(best ?? 0, 100) }
            else if t.contains(" " + q) { best = max(best ?? 0, 80) }
            else if t.contains(q) { best = max(best ?? 0, 60) }
            else if isSubsequence(q, of: t) { best = max(best ?? 0, 20) }
        }
        return best
    }

    private func isSubsequence(_ q: String, of t: String) -> Bool {
        var i = q.startIndex
        for c in t where i < q.endIndex && c == q[i] { i = q.index(after: i) }
        return i == q.endIndex
    }
}

extension Array where Element == PanelItem {
    func filtered(_ query: String) -> [PanelItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return self }
        return compactMap { item in item.score(query).map { (item, $0) } }
            .sorted { $0.1 > $1.1 }
            .map { var i = $0.0; i.section = nil; return i }
    }
}
