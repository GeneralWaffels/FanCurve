import AppKit
import ApplicationServices
import IOKit

/// Keeps the Mac (and "active" status in apps like Teams or Slack) awake by sweeping the pointer across
/// every monitor once you've been idle for a while. It stops as soon as you use the mouse or keyboard,
/// and never runs with the lid closed unless an external display is in use (clamshell mode).
@MainActor
final class MouseJiggler: ObservableObject {
    enum State: Equatable {
        case off, waiting(idle: TimeInterval), active(lastMove: Date), lidClosed, needsPermission
    }

    @Published var enabled: Bool { didSet { save(); if enabled { start() } else { stop() } } }
    /// Start after this many minutes without input.
    @Published var idleMinutes: Double { didSet { save() } }
    /// Seconds between sweeps while idle.
    @Published var intervalSeconds: Double { didSet { save() } }
    @Published private(set) var state: State = .off

    private var timer: Timer?
    private var lastUserActivity = Date()
    private var lastJiggle: Date?
    private let defaults = UserDefaults.standard

    init() {
        enabled = defaults.bool(forKey: "jiggleEnabled")
        idleMinutes = defaults.object(forKey: "jiggleIdle") as? Double ?? 5
        intervalSeconds = defaults.object(forKey: "jiggleInterval") as? Double ?? 60
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.timer?.invalidate(); self?.timer = nil }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Waking up counts as activity: never jiggle straight after the Mac wakes.
            MainActor.assumeIsolated { self?.lastUserActivity = Date(); self?.lastJiggle = nil; if self?.enabled == true { self?.start() } }
        }
        if enabled { start() }
    }

    private func save() {
        defaults.set(enabled, forKey: "jiggleEnabled")
        defaults.set(idleMinutes, forKey: "jiggleIdle")
        defaults.set(intervalSeconds, forKey: "jiggleInterval")
    }

    func toggle() { enabled.toggle() }

    private func start() {
        guard timer == nil else { return }
        lastUserActivity = Date().addingTimeInterval(-Self.hidIdleTime())
        lastJiggle = nil
        if !AXIsProcessTrusted() {
            AccessibilityPermission.shared.request()
            AccessibilityPermission.shared.whenGranted { [weak self] in self?.tick() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 1
        tick()
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        state = .off
    }

    private func tick() {
        guard enabled else { state = .off; return }
        let now = Date()
        // HID idle time counts our own moves too. An input event newer than our last sweep is the user.
        let lastInput = now.addingTimeInterval(-Self.hidIdleTime())
        if lastJiggle.map({ lastInput > $0.addingTimeInterval(1.5) }) ?? true {
            if lastInput > lastUserActivity { lastUserActivity = lastInput }
        }
        let userIdle = now.timeIntervalSince(lastUserActivity)

        guard Self.mayRun else { state = .lidClosed; lastJiggle = nil; return }
        guard AXIsProcessTrusted() else { state = .needsPermission; return }
        guard userIdle >= idleMinutes * 60 else {
            lastJiggle = nil
            state = .waiting(idle: userIdle)
            return
        }
        if lastJiggle.map({ now.timeIntervalSince($0) >= intervalSeconds - 0.5 }) ?? true {
            sweep()
            lastJiggle = Date()
        }
        state = .active(lastMove: lastJiggle ?? now)
    }

    /// Moves the pointer through the centre of each display, then back to where it was.
    private func sweep() {
        guard let origin = CGEvent(source: nil)?.location else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        let centres = ids.prefix(Int(count)).map { id -> CGPoint in
            let b = CGDisplayBounds(id)
            return CGPoint(x: b.midX, y: b.midY)
        }
        let path = centres + [origin]
        for (i, p) in path.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120 * i)) { Self.move(to: p) }
        }
    }

    private static func move(to p: CGPoint) {
        let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved,
                        mouseCursorPosition: p, mouseButton: .left)
        e?.post(tap: .cghidEventTap)
    }

    // MARK: system state

    /// Seconds since the last keyboard/mouse/trackpad input (IOHIDSystem's HIDIdleTime).
    static func hidIdleTime() -> TimeInterval {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        guard let v = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return 0 }
        return v.doubleValue / 1_000_000_000
    }

    /// True when the MacBook lid is closed (AppleClamshellState on the power root domain).
    static var lidClosed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return (IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool) ?? false
    }

    /// Lid open, or closed with an external display active (clamshell mode). Never with the lid simply closed.
    static var mayRun: Bool { !lidClosed || NSScreen.screens.contains { !$0.isBuiltIn } }
}
