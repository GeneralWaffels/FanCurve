import AppKit
import CoreAudio

/// System-wide microphone mute: mutes every input device via CoreAudio. It uses the device's
/// hardware mute if it has one, and otherwise sets input volume to 0 (restored on unmute).
/// While muted it re-applies itself every second and on device changes, so a newly plugged-in
/// headset or an app that raises input volume can't unmute you.
@MainActor
final class MicMuter: ObservableObject {
    enum IndicatorMode: String, CaseIterable, Identifiable {
        case always, whenMuted, never
        var id: String { rawValue }
        var label: String {
            switch self {
            case .always: return "Always"
            case .whenMuted: return "Only while muted"
            case .never: return "Never"
            }
        }
    }

    @Published private(set) var isMuted = false
    @Published var indicator: IndicatorMode { didSet { UserDefaults.standard.set(indicator.rawValue, forKey: "micIndicator") } }
    @Published var shortcut: Shortcut? { didSet { saveShortcut(); registerHotKey() } }

    /// Binding for the MenuBarExtra's isInserted. SwiftUI writes this back on every scene update,
    /// so the setter must only react to a real change (the user ⌘-dragging the icon out), otherwise
    /// each write republishes and the app graph re-renders forever.
    var showIndicator: Bool {
        get { indicator == .always || (indicator == .whenMuted && isMuted) }
        set { if !newValue && indicator == .always { indicator = .never } }
    }

    private var savedVolumes: [AudioDeviceID: [UInt32: Float32]] = [:]
    private var timer: Timer?

    init() {
        indicator = IndicatorMode(rawValue: UserDefaults.standard.string(forKey: "micIndicator") ?? "") ?? .whenMuted
        if let d = UserDefaults.standard.data(forKey: "micShortcut") { shortcut = try? JSONDecoder().decode(Shortcut.self, from: d) }
        else { shortcut = Shortcut.defaultMicToggle }
        registerHotKey()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setMuted(false) }   // never leave the mic muted after quitting
        }
    }

    func toggle() { setMuted(!isMuted) }

    func setMuted(_ on: Bool) {
        isMuted = on
        timer?.invalidate(); timer = nil
        if on {
            apply()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
        } else {
            for dev in Self.inputDevices() { unmute(dev) }
            savedVolumes = [:]
        }
    }

    private func apply() { for dev in Self.inputDevices() { mute(dev) } }

    // MARK: CoreAudio

    private static func address(_ selector: AudioObjectPropertySelector, element: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeInput, mElement: element)
    }

    static func inputDevices() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var a = address(kAudioDevicePropertyStreams)
            var s: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &s) == noErr && s > 0
        }
    }

    private static func settable(_ dev: AudioDeviceID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        var ok: DarwinBoolean = false
        return AudioObjectHasProperty(dev, &a) && AudioObjectIsPropertySettable(dev, &a, &ok) == noErr && ok.boolValue
    }

    private static func channels(_ dev: AudioDeviceID) -> [UInt32] {
        // element 0 = master; many built-in mics only expose per-channel volume (1…n)
        [0] + (1...8).filter { settable(dev, address(kAudioDevicePropertyVolumeScalar, element: $0)) }
    }

    private func mute(_ dev: AudioDeviceID) {
        var muteAddr = Self.address(kAudioDevicePropertyMute)
        if Self.settable(dev, muteAddr) {
            var one: UInt32 = 1
            AudioObjectSetPropertyData(dev, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &one)
            return
        }
        for ch in Self.channels(dev) {
            var a = Self.address(kAudioDevicePropertyVolumeScalar, element: ch)
            guard Self.settable(dev, a) else { continue }
            var vol: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &vol)
            if savedVolumes[dev]?[ch] == nil, vol > 0 { savedVolumes[dev, default: [:]][ch] = vol }
            var zero: Float32 = 0
            if vol != 0 { AudioObjectSetPropertyData(dev, &a, 0, nil, size, &zero) }
        }
    }

    private func unmute(_ dev: AudioDeviceID) {
        var muteAddr = Self.address(kAudioDevicePropertyMute)
        if Self.settable(dev, muteAddr) {
            var zero: UInt32 = 0
            AudioObjectSetPropertyData(dev, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &zero)
        }
        for (ch, vol) in savedVolumes[dev] ?? [:] {
            var a = Self.address(kAudioDevicePropertyVolumeScalar, element: ch)
            var v = vol
            AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
    }

    // MARK: shortcut

    private func saveShortcut() {
        if let shortcut, let d = try? JSONEncoder().encode(shortcut) { UserDefaults.standard.set(d, forKey: "micShortcut") }
        else { UserDefaults.standard.set(Data(), forKey: "micShortcut") }
    }

    private func registerHotKey() {
        HotKeys.shared.register(id: 1, shortcut: shortcut) { [weak self] in self?.toggle() }
    }
}
