import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A global keyboard shortcut (Carbon key code + Carbon modifier mask), plus how to display it.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    static let defaultMicToggle = Shortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥M")

    init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.display = display
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isFunctionKey = (kVK_F1...kVK_F20).contains(Int(event.keyCode))
        guard !flags.isEmpty || isFunctionKey else { return nil }   // bare letters would hijack typing
        var carbon: UInt32 = 0
        var text = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); text += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); text += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); text += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); text += "⌘" }
        let key = isFunctionKey ? "F\(Self.functionNumber(Int(event.keyCode)))"
                                : (event.charactersIgnoringModifiers ?? "?").uppercased()
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbon, display: text + key)
    }

    private static func functionNumber(_ code: Int) -> Int {
        let map = [kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6, kVK_F7: 7, kVK_F8: 8, kVK_F9: 9, kVK_F10: 10,
                   kVK_F11: 11, kVK_F12: 12, kVK_F13: 13, kVK_F14: 14, kVK_F15: 15, kVK_F16: 16, kVK_F17: 17, kVK_F18: 18, kVK_F19: 19, kVK_F20: 20]
        return map[code] ?? 0
    }
}

/// Global hotkeys via Carbon's RegisterEventHotKey. Works while other apps are in front and
/// needs no Accessibility permission.
@MainActor
final class HotKeys {
    static let shared = HotKeys()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private static let signature: OSType = 0x4643_5256   // 'FCRV'

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            MainActor.assumeIsolated { HotKeys.shared.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private var shortcuts: [UInt32: Shortcut] = [:]
    private var suspended = false

    /// Registers (or clears) a hotkey. Returns false if macOS refused it — usually because
    /// another app or a system shortcut already owns that combination.
    @discardableResult
    func register(id: UInt32, shortcut: Shortcut?, action: @escaping () -> Void) -> Bool {
        if let old = refs.removeValue(forKey: id) { UnregisterEventHotKey(old) }
        actions[id] = action
        shortcuts[id] = shortcut
        guard let shortcut, !suspended else { return true }
        return install(id: id, shortcut)
    }

    private func install(id: UInt32, _ shortcut: Shortcut) -> Bool {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: Self.signature, id: id)
        guard RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hkID, GetApplicationEventTarget(), 0, &ref) == noErr,
              let ref else { return false }
        refs[id] = ref
        return true
    }

    /// While recording a new shortcut, global hotkeys are paused so the current combination
    /// reaches the recorder instead of firing its action.
    func suspend() {
        suspended = true
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs = [:]
    }

    func resume() {
        suspended = false
        for (id, s) in shortcuts { _ = install(id: id, s) }
    }
}

/// Click, then press the new key combination. Esc cancels, Delete clears.
/// (State lives in an ObservableObject: the Command Line Tools can't expand SwiftUI's @State macro.)
@MainActor
final class RecorderState: ObservableObject {
    @Published var recording = false
    private var monitor: Any?

    func start(onKey: @escaping (NSEvent) -> Void) {
        recording = true
        HotKeys.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { onKey(event) }
            return nil
        }
    }

    func stop() {
        if recording { HotKeys.shared.resume() }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    @StateObject private var state = RecorderState()

    var body: some View {
        HStack(spacing: 6) {
            Button(state.recording ? "Press shortcut…" : (shortcut?.display ?? "Record shortcut")) {
                state.recording ? state.stop() : state.start(onKey: handle)
            }
            .fixedSize()
            if shortcut != nil && !state.recording {
                Button { shortcut = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).help("Clear shortcut")
            }
        }
        .onDisappear { state.stop() }
    }

    private func handle(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape: state.stop()
        case kVK_Delete, kVK_ForwardDelete: shortcut = nil; state.stop()
        default:
            if let s = Shortcut(event: event) { shortcut = s; state.stop() } else { NSSound.beep() }
        }
    }
}
