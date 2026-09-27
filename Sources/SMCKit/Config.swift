import Foundation

public struct CurvePoint: Codable, Hashable {
    public var temp: Double   // °C
    public var rpm: Double
    public init(temp: Double, rpm: Double) { self.temp = temp; self.rpm = rpm }
}

public struct FanConfig: Codable, Equatable {
    /// false = macOS controls the fans (daemon hands control back).
    public var enabled: Bool = false
    public var source: TempSource = .cpuMax
    public var points: [CurvePoint] = FanConfig.presets["Noctua Balanced"]!
    /// Seconds of exponential smoothing on the temperature, so fans don't spike on short bursts.
    public var smoothing: Double = 6
    /// Above this temperature fans always go to max, regardless of the curve.
    public var criticalTemp: Double = 95
    /// Idle fans only start once the curve has asked for them continuously this long (seconds),
    /// so short bursts (app launches, page loads) don't wake them. Critical temps bypass it.
    public var spinUpDelay: Double = 15

    public init() {}

    // Tolerant decoding: settings added in later versions fall back to defaults instead of
    // making an older config.json fail to load (which would silently reset the user's curve).
    private enum CodingKeys: String, CodingKey { case enabled, source, points, smoothing, criticalTemp, spinUpDelay }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FanConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        source = (try? c.decodeIfPresent(TempSource.self, forKey: .source)) ?? d.source
        points = try c.decodeIfPresent([CurvePoint].self, forKey: .points) ?? d.points
        smoothing = try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? d.smoothing
        criticalTemp = try c.decodeIfPresent(Double.self, forKey: .criticalTemp) ?? d.criticalTemp
        spinUpDelay = try c.decodeIfPresent(Double.self, forKey: .spinUpDelay) ?? d.spinUpDelay
    }

    /// Lowest temperature at which the curve asks for at least `fanMin` rpm (i.e. where fans start), if any.
    public func startTemp(fanMin: Double) -> Double? {
        stride(from: 20.0, through: 110, by: 0.1).first { rpm(at: $0) >= fanMin }
    }

    public static let presetOrder = ["Noctua Quiet", "Noctua Balanced", "Noctua Performance", "Puget Systems"]

    public static let presets: [String: [CurvePoint]] = [
        // Noctua's Antec Flux Pro Noctua Edition curves (noctua.at, Mar 2026), PWM % mapped onto the
        // M5 Pro's 7826 rpm max, including Noctua's 30% floor (~2350 rpm), so the fans keep turning.
        "Noctua Quiet": [.init(temp: 40, rpm: 2350), .init(temp: 60, rpm: 3150), .init(temp: 80, rpm: 3900), .init(temp: 90, rpm: 5500), .init(temp: 95, rpm: 7826)],
        "Noctua Balanced": [.init(temp: 40, rpm: 2350), .init(temp: 50, rpm: 3150), .init(temp: 60, rpm: 3900), .init(temp: 80, rpm: 5500), .init(temp: 95, rpm: 7826)],
        "Noctua Performance": [.init(temp: 40, rpm: 2350), .init(temp: 50, rpm: 3500), .init(temp: 60, rpm: 4700), .init(temp: 80, rpm: 6250), .init(temp: 90, rpm: 7826)],
        // Puget Systems-style BIOS curve (Gigabyte Smart Fan 5): 0 °C 0%, 30 °C 25%, 55 °C 35%, 70 °C 50%,
        // 80 °C 75%, 90 °C 100%, on the same 7826 rpm scale. 25% is below the fans' minimum, so they
        // stay off until ~42 °C.
        "Puget Systems": [.init(temp: 0, rpm: 0), .init(temp: 30, rpm: 1957), .init(temp: 55, rpm: 2739), .init(temp: 70, rpm: 3913), .init(temp: 80, rpm: 5870), .init(temp: 90, rpm: 7826)],
    ]

    /// The laptop-tweaked Noctua curves shipped before 2026-09-27 (fans-off zone), mapped to their
    /// current names so a saved config still shows the right profile.
    public static let legacyPresets: [String: [CurvePoint]] = [
        "Noctua Quiet": [.init(temp: 55, rpm: 0), .init(temp: 60, rpm: 3150), .init(temp: 80, rpm: 3900), .init(temp: 90, rpm: 5500), .init(temp: 95, rpm: 7826)],
        "Noctua Balanced": [.init(temp: 50, rpm: 0), .init(temp: 55, rpm: 3500), .init(temp: 60, rpm: 3900), .init(temp: 80, rpm: 5500), .init(temp: 95, rpm: 7826)],
        "Noctua Performance": [.init(temp: 45, rpm: 0), .init(temp: 50, rpm: 3500), .init(temp: 60, rpm: 4700), .init(temp: 80, rpm: 6250), .init(temp: 90, rpm: 7826)],
    ]

    /// Linear interpolation over the curve. Below the first point → first rpm, above the last → last rpm.
    public func rpm(at temp: Double) -> Double {
        let p = points.sorted { $0.temp < $1.temp }
        guard let first = p.first, let last = p.last else { return 0 }
        if temp <= first.temp { return first.rpm }
        if temp >= last.temp { return last.rpm }
        for (a, b) in zip(p, p.dropFirst()) where temp <= b.temp {
            let f = (temp - a.temp) / max(b.temp - a.temp, 0.001)
            return a.rpm + f * (b.rpm - a.rpm)
        }
        return last.rpm
    }
}

/// State the daemon publishes so the app can show whether it's actually in control.
public struct DaemonStatus: Codable, Equatable {
    public var updated: Date
    public var temp: Double?
    public var smoothedTemp: Double?
    public var targetRPM: Double?
    public var mode: String      // "curve", "auto", "critical", "error"
    public var message: String?
    public init(updated: Date, temp: Double?, smoothedTemp: Double?, targetRPM: Double?, mode: String, message: String?) {
        self.updated = updated; self.temp = temp; self.smoothedTemp = smoothedTemp
        self.targetRPM = targetRPM; self.mode = mode; self.message = message
    }
}

public enum Paths {
    public static let dir = URL(fileURLWithPath: "/Library/Application Support/FanCurve")
    public static let config = dir.appendingPathComponent("config.json")
    public static let status = dir.appendingPathComponent("status.json")

    public static func loadConfig() -> FanConfig {
        guard let d = try? Data(contentsOf: config), let c = try? JSONDecoder().decode(FanConfig.self, from: d) else { return FanConfig() }
        return c
    }

    public static func save(_ c: FanConfig) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(c).write(to: config, options: .atomic)
    }

    public static func loadStatus() -> DaemonStatus? {
        guard let d = try? Data(contentsOf: status) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(DaemonStatus.self, from: d)
    }

    public static func save(_ s: DaemonStatus) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(s).write(to: status, options: .atomic)
    }
}
