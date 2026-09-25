import AppKit
import ApplicationServices
import SwiftUI

/// Routes the MacBook's brightness keys to external monitors (DDC).
/// Uses an event tap on system-defined events, so it needs Accessibility permission.
@MainActor
final class BrightnessKeys: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case off, underPointer, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "Built-in display only"
            case .underPointer: return "Display under the pointer"
            case .all: return "All displays together"
            }
        }
    }

    @Published var mode: Mode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "brightnessKeys"); update() } }
    @Published private(set) var needsPermission = false

    private weak var displays: Displays?
    nonisolated(unsafe) private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let hud = BrightnessHUD()

    // NX_SYSDEFINED media-key events: subtype 8, key types 2/3 = brightness up/down.
    private static let sysDefined = CGEventType(rawValue: 14)!
    private static let brightnessUp = 2, brightnessDown = 3

    init(displays: Displays) {
        self.displays = displays
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: "brightnessKeys") ?? "") ?? .off
        update()
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Installs or removes the tap to match the mode. Re-run after granting permission.
    func update() {
        stopTap()
        guard mode != .off else { needsPermission = false; return }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else { needsPermission = true; return }
        needsPermission = false

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<BrightnessKeys>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let handled = MainActor.assumeIsolated { me.handle(event) }
            return handled ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: 1 << Self.sysDefined.rawValue, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            needsPermission = true; return
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }

    /// Returns true when the key press was used for an external display (and should be swallowed).
    private func handle(_ cgEvent: CGEvent) -> Bool {
        guard let event = NSEvent(cgEvent: cgEvent), event.subtype.rawValue == 8 else { return false }
        let keyType = (event.data1 & 0xFFFF_0000) >> 16
        guard keyType == Self.brightnessUp || keyType == Self.brightnessDown else { return false }
        let keyDown = ((event.data1 & 0xFF00) >> 8) == 0xA
        guard let displays, !displays.monitors.isEmpty else { return false }

        // Same steps as macOS: 16 per full range, or 64 with ⌥⇧ held for fine control.
        let fine = event.modifierFlags.contains(.option) && event.modifierFlags.contains(.shift)
        let delta = (keyType == Self.brightnessUp ? 1.0 : -1.0) * (fine ? 100.0 / 64 : 100.0 / 16)

        switch mode {
        case .off:
            return false
        case .underPointer:
            guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }),
                  !screen.isBuiltIn, let id = displays.monitorID(for: screen) else { return false }   // built-in: let macOS handle it
            if keyDown { show(displays.nudge(id, by: delta), on: screen) }
            return true
        case .all:
            if keyDown {
                for m in displays.monitors {
                    let value = displays.nudge(m.id, by: delta)
                    if let screen = NSScreen.screens.first(where: { displays.monitorID(for: $0) == m.id }) { show(value, on: screen) }
                }
            }
            return false   // let macOS change the built-in display too
        }
    }

    private func show(_ value: Double, on screen: NSScreen) { hud.show(level: value / 100, on: screen) }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
    var isBuiltIn: Bool { displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false }
}

// MARK: - HUD

/// Brightness overlay in the style of macOS 26+: a small glass panel near the top-right corner
/// of the display being changed.
@MainActor
final class BrightnessHUD {
    private final class Level: ObservableObject { @Published var value: Double = 0 }
    private let level = Level()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(level value: Double, on screen: NSScreen) {
        level.value = min(max(value, 0), 1)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = panel.frame.size
        let vf = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 12, y: vf.maxY - size.height - 10))
        if !panel.isVisible { panel.alphaValue = 0; panel.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }, completionHandler: { panel.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 62),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: HUDView(level: level))
        return panel
    }

    private struct HUDView: View {
        @ObservedObject var level: Level

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: "sun.max.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.15))
                        Capsule().fill(.primary).frame(width: max(g.size.width * level.value, level.value > 0 ? 6 : 0))
                    }
                }
                .frame(height: 6)
                Text("\(Int((level.value * 100).rounded()))%").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
            .padding(.horizontal, 18)
            .frame(width: 290, height: 52)
            .modifier(HUDBackground())
            .padding(5)
        }
    }

    private struct HUDBackground: ViewModifier {
        func body(content: Content) -> some View {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }
}
