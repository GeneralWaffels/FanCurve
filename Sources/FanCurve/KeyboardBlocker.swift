import AppKit
import ApplicationServices

/// Keyboard cleaning mode: a session event tap that swallows every keyboard event
/// (keys, modifiers, media/brightness keys) while mouse and trackpad events pass through.
/// Needs Accessibility permission. The power button / Touch ID can't be blocked.
@MainActor
final class KeyboardBlocker: ObservableObject {
    @Published private(set) var isOn = false
    @Published private(set) var secondsLeft = 0
    @Published var needsPermission = false

    /// Safety net: cleaning mode turns itself off after this long.
    let timeout = 5 * 60

    nonisolated(unsafe) private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?

    // NX_SYSDEFINED (14) carries media, volume and brightness keys.
    private static let mask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) |
        (1 << CGEventType.flagsChanged.rawValue) | (1 << 14)

    func toggle() { isOn ? stop() : start() }

    func start() {
        guard !isOn else { return }
        guard AXIsProcessTrusted() else {
            needsPermission = true
            AccessibilityPermission.shared.request()
            AccessibilityPermission.shared.whenGranted { [weak self] in self?.needsPermission = false }
            return
        }
        needsPermission = false

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            // macOS disables taps that stall or on user input timeouts; re-enable and keep blocking.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let refcon, let tap = Unmanaged<KeyboardBlocker>.fromOpaque(refcon).takeUnretainedValue().tap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }
            return nil   // swallow the key
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: Self.mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            needsPermission = true; return
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isOn = true

        secondsLeft = timeout
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.secondsLeft -= 1
                if self.secondsLeft <= 0 { self.stop() }
            }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        isOn = false
        secondsLeft = 0
    }

    func openAccessibilitySettings() { AccessibilityPermission.shared.request() }
}
