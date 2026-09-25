import Foundation

/// What temperature the curve follows.
public enum TempSource: String, Codable, CaseIterable, Identifiable {
    case cpuMax, cpuAvg, gpuMax, hottest

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .cpuMax: return "CPU (hottest core)"
        case .cpuAvg: return "CPU (average)"
        case .gpuMax: return "GPU (hottest)"
        case .hottest: return "CPU or GPU, whichever is hotter"
        }
    }
}

public struct Fan: Identifiable {
    public let id: Int
    public let actual: Double
    public let target: Double
    public let min: Double
    public let max: Double
    public let manual: Bool
}

/// Apple Silicon sensor/fan map (M5 Pro verified; M1–M4 per exelban/stats).
/// Tp* / Te* / Ts* / Tm* = CPU core clusters (Te = M1–M4 efficiency cores), Tg* = GPU. Keys ending in "P" in the Ts range
/// (Ts0P, Ts1P) are chassis/palm-rest sensors, not the die, so they're excluded.
public final class Hardware {
    public let smc: SMC
    public let cpuKeys: [String]
    public let gpuKeys: [String]
    public let fanCount: Int
    /// "F0md" on M5, "F0Md" on M1–M4.
    private let lowerModeKey: Bool
    /// M1–M4 need Ftst=1 before thermalmonitord lets go of the fans; M5 has no Ftst key.
    private let hasFtst: Bool

    public init() throws {
        let smc = try SMC()
        self.smc = smc
        let keys = smc.allKeys()
        func plausible(_ k: String) -> Bool {
            guard let v = smc.readDouble(k) else { return false }
            return v > 5 && v < 130
        }
        cpuKeys = keys.filter { ["Tp", "Te", "Ts", "Tm"].contains(where: $0.hasPrefix) && !($0.hasPrefix("Ts") && $0.hasSuffix("P")) && plausible($0) }
        gpuKeys = keys.filter { $0.hasPrefix("Tg") && plausible($0) }
        fanCount = Int(smc.readDouble("FNum") ?? 0)
        lowerModeKey = (try? smc.read("F0md")) != nil
        hasFtst = (try? smc.read("Ftst")) != nil
    }

    private func modeKey(_ i: Int) -> String { lowerModeKey ? "F\(i)md" : "F\(i)Md" }

    private func writeRetrying(_ key: String, _ value: Double, attempts: Int, delay: useconds_t = 100_000) throws {
        for n in 1...attempts {
            do { try smc.write(key, value: value); return } catch { if n == attempts { throw error }; usleep(delay) }
        }
    }

    private func values(_ keys: [String]) -> [Double] {
        keys.compactMap { smc.readDouble($0) }.filter { $0 > 5 && $0 < 130 }
    }

    public func cpuTemps() -> [Double] { values(cpuKeys) }
    public func gpuTemps() -> [Double] { values(gpuKeys) }

    public func temperature(_ source: TempSource) -> Double? {
        switch source {
        case .cpuMax: return cpuTemps().max()
        case .cpuAvg: let t = cpuTemps(); return t.isEmpty ? nil : t.reduce(0, +) / Double(t.count)
        case .gpuMax: return gpuTemps().max()
        case .hottest: return (cpuTemps() + gpuTemps()).max()
        }
    }

    public func fans() -> [Fan] {
        (0..<fanCount).map { i in
            Fan(id: i,
                actual: smc.readDouble("F\(i)Ac") ?? 0,
                target: smc.readDouble("F\(i)Tg") ?? 0,
                min: smc.readDouble("F\(i)Mn") ?? 0,
                max: smc.readDouble("F\(i)Mx") ?? 0,
                manual: (smc.readDouble(modeKey(i)) ?? 0) != 0)
        }
    }

    // MARK: control (root only)

    public func setManual(fan i: Int, rpm: Double) throws {
        if (smc.readDouble(modeKey(i)) ?? 0) != 1 { try unlock(fan: i) }
        try writeRetrying("F\(i)Tg", rpm, attempts: 10, delay: 50_000)
    }

    /// Puts a fan in manual mode. M5: direct mode write. M1–M4: set Ftst, wait for
    /// thermalmonitord to yield (~3 s), then retry the mode write (same sequence as Stats).
    private func unlock(fan i: Int) throws {
        if (try? smc.write(modeKey(i), value: 1)) != nil { return }
        guard hasFtst else { try smc.write(modeKey(i), value: 1); return }
        if (smc.readDouble("Ftst") ?? 0) != 1 {
            try writeRetrying("Ftst", 1, attempts: 100, delay: 50_000)
            usleep(3_000_000)
        }
        try writeRetrying(modeKey(i), 1, attempts: 100)
    }

    public func setAuto(fan i: Int) throws {
        try smc.write(modeKey(i), value: 0)
    }

    /// Hands every fan back to macOS. On M1–M4 clearing Ftst returns control to thermalmonitord.
    public func setAllAuto() {
        if hasFtst, (smc.readDouble("Ftst") ?? 0) != 0 { try? writeRetrying("Ftst", 0, attempts: 10, delay: 50_000) }
        for i in 0..<fanCount { try? setAuto(fan: i) }
    }
}
