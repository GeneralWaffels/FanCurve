import AppKit

/// External monitor brightness over DDC, optionally driven by the MacBook's ambient light sensor.
@MainActor
final class Displays: ObservableObject {
    struct Monitor: Identifiable {
        let id: Int
        let name: String
        var brightness: Double     // 0–100 %
        var maxRaw: UInt16         // monitor's native max (usually 100)
        var readable: Bool         // answered a DDC read
    }

    @Published private(set) var monitors: [Monitor] = []
    @Published private(set) var lux: Double?
    @Published private(set) var sensorPaused = false   // lid closed → sensor is covered

    @Published var followSensor: Bool { didSet { defaults.set(followSensor, forKey: "followSensor"); if followSensor { applySensor(force: true) } } }
    @Published var minBrightness: Double { didSet { defaults.set(minBrightness, forKey: "minBrightness"); if followSensor { applySensor(force: true) } } }
    @Published var maxBrightness: Double { didSet { defaults.set(maxBrightness, forKey: "maxBrightness"); if followSensor { applySensor(force: true) } } }

    let sensor = LightSensor()
    private var ddc: [DDCDisplay] = []
    private var smoothedLux: Double?
    private var lastSent: [Int: Double] = [:]
    private var pending: [Int: DispatchWorkItem] = [:]
    private let queue = DispatchQueue(label: "fancurve.ddc")
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    /// The Displays page is on screen: keep the lux readout live even when not following the sensor.
    var pageVisible = false { didSet { if pageVisible && !oldValue { applySensor(force: false) } } }

    /// Lux at which the sensor mapping reaches max brightness (bright office / window light).
    static let fullBrightLux = 1000.0

    init() {
        followSensor = defaults.bool(forKey: "followSensor")
        minBrightness = defaults.object(forKey: "minBrightness") as? Double ?? 10
        maxBrightness = defaults.object(forKey: "maxBrightness") as? Double ?? 100
        rescan()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in try? await Task.sleep(for: .seconds(2)); self?.rescan() }   // give DCP time to bring the link up
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySensor(force: false) }
        }
        timer?.tolerance = 0.5
    }

    func rescan() {
        let found = DDCDisplay.scan()
        ddc = found
        lastSent = [:]
        queue.async {
            let states = found.enumerated().map { i, d -> Monitor in
                let r = d.readBrightness()
                let maxRaw = max(r?.max ?? 100, 1)
                return Monitor(id: i, name: d.name, brightness: r.map { Double($0.current) / Double(maxRaw) * 100 } ?? 50,
                               maxRaw: maxRaw, readable: r != nil)
            }
            Task { @MainActor in
                self.monitors = states
                if self.followSensor { self.applySensor(force: true) }
            }
        }
    }

    /// Manual slider change. Turns off sensor following for a clear mental model.
    func setBrightness(_ value: Double, for id: Int, manual: Bool = true) {
        if manual && followSensor { followSensor = false }
        guard monitors.indices.contains(id) else { return }
        monitors[id].brightness = value
        send(id)
    }

    func setAll(_ value: Double) { for m in monitors { setBrightness(value, for: m.id) } }

    /// Brightness-key step: adjusts one monitor by `delta` percent and returns the new value.
    @discardableResult
    func nudge(_ id: Int, by delta: Double) -> Double {
        guard monitors.indices.contains(id) else { return 0 }
        let value = min(max(monitors[id].brightness + delta, 0), 100)
        setBrightness(value, for: id)
        return value
    }

    /// Which DDC monitor drives this screen: matched by product name, or the only external one.
    func monitorID(for screen: NSScreen) -> Int? {
        guard !screen.isBuiltIn else { return nil }
        if let m = monitors.first(where: { $0.name == screen.localizedName }) { return m.id }
        let externals = NSScreen.screens.filter { !$0.isBuiltIn }
        return externals.count == 1 && monitors.count == 1 ? monitors[0].id : nil
    }

    private func send(_ id: Int) {
        guard ddc.indices.contains(id), monitors.indices.contains(id) else { return }
        let display = ddc[id]
        let raw = Int((monitors[id].brightness / 100 * Double(monitors[id].maxRaw)).rounded())
        lastSent[id] = monitors[id].brightness
        // Debounce: slider drags produce many values; monitors only need the last one.
        pending[id]?.cancel()
        let work = DispatchWorkItem { _ = display.setBrightness(raw) }
        pending[id] = work
        queue.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func applySensor(force: Bool) {
        // Nothing to do unless we're following the sensor or showing it (saves sensor + display polling).
        guard followSensor || pageVisible else { return }
        let builtInActive = NSScreen.screens.contains { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) != 0 } ?? false
        }
        lux = sensor.lux()
        sensorPaused = !builtInActive
        guard followSensor, builtInActive, let lux else { return }

        // Smooth so passing shadows don't make the monitor pump.
        smoothedLux = smoothedLux.map { $0 + 0.3 * (lux - $0) } ?? lux
        let target = Self.brightness(forLux: smoothedLux!, min: minBrightness, max: maxBrightness).rounded()

        for m in monitors {
            let last = lastSent[m.id] ?? -100
            if force || abs(target - last) >= 2 { setBrightness(target, for: m.id, manual: false) }
        }
    }

    /// Log mapping: human brightness perception is roughly logarithmic in lux.
    static func brightness(forLux lux: Double, min lo: Double, max hi: Double) -> Double {
        let f = Swift.min(Swift.max(log10(1 + lux) / log10(1 + fullBrightLux), 0), 1)
        return lo + f * (hi - lo)
    }
}
