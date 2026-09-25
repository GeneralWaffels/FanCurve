import Foundation
import SMCKit

@MainActor
final class Model: ObservableObject {
    @Published var config: FanConfig { didSet { if config != oldValue { scheduleSave() } } }
    @Published var temps: [TempSource: Double] = [:]
    @Published var fans: [Fan] = []
    @Published var status: DaemonStatus?
    @Published var saveError: String?
    /// User-saved curves (name → points). Built-in Noctua presets are separate and can't be deleted.
    @Published private(set) var customProfiles: [String: [CurvePoint]] = [:]

    let hw: Hardware?
    private var timer: Timer?
    private var saveTask: Task<Void, Never>?

    init() {
        hw = try? Hardware()
        config = Paths.loadConfig()
        if let d = UserDefaults.standard.data(forKey: "customProfiles"),
           let p = try? JSONDecoder().decode([String: [CurvePoint]].self, from: d) { customProfiles = p }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var currentTemp: Double? { temps[config.source] }
    var fanMin: Double { fans.map(\.min).max() ?? 2317 }
    var fanMax: Double { fans.map(\.max).min() ?? 7826 }

    /// Daemon counts as running if it wrote status in the last 10 s.
    var daemonRunning: Bool { status.map { Date().timeIntervalSince($0.updated) < 10 } ?? false }

    /// One sensor pass per second; published values are rounded and only assigned when they
    /// change, so the UI redraws at most once a second instead of for every sensor flicker.
    func refresh() {
        guard let hw else { return }
        let cpu = hw.cpuTemps(), gpu = hw.gpuTemps()
        func r(_ v: Double?) -> Double? { v.map { ($0 * 2).rounded() / 2 } }   // 0.5 °C steps
        let t: [TempSource: Double?] = [
            .cpuMax: r(cpu.max()),
            .cpuAvg: r(cpu.isEmpty ? nil : cpu.reduce(0, +) / Double(cpu.count)),
            .gpuMax: r(gpu.max()),
            .hottest: r((cpu + gpu).max()),
        ]
        let newTemps = t.compactMapValues { $0 }
        if newTemps != temps { temps = newTemps }
        let newFans = hw.fans().map { Fan(id: $0.id, actual: ($0.actual / 10).rounded() * 10, target: $0.target, min: $0.min, max: $0.max, manual: $0.manual) }
        if newFans != fans { fans = newFans }
        let newStatus = Paths.loadStatus()
        if newStatus != status { status = newStatus }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [config] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do { try Paths.save(config); saveError = nil }
            catch { saveError = "Can't write config — run install.sh first (\(error.localizedDescription))" }
        }
    }

    // MARK: profiles

    var customProfileNames: [String] { customProfiles.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    func points(for name: String) -> [CurvePoint]? { FanConfig.presets[name] ?? customProfiles[name] }

    func applyPreset(_ name: String) { if let p = points(for: name) { config.points = p } }

    /// The profile whose curve matches the current one (point order doesn't matter), if any.
    var activeProfile: String? {
        let current = config.points.sorted { $0.temp < $1.temp }
        return (FanConfig.presetOrder + customProfileNames).first { points(for: $0)?.sorted { $0.temp < $1.temp } == current }
    }

    func isBuiltIn(_ name: String) -> Bool { FanConfig.presets[name] != nil }

    func saveProfile(named name: String) {
        customProfiles[name] = config.points.sorted { $0.temp < $1.temp }
        persistProfiles()
    }

    func deleteProfile(named name: String) {
        customProfiles[name] = nil
        persistProfiles()
    }

    private func persistProfiles() {
        if let d = try? JSONEncoder().encode(customProfiles) { UserDefaults.standard.set(d, forKey: "customProfiles") }
    }
}
