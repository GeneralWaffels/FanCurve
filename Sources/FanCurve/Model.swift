import Foundation
import SMCKit

@MainActor
final class Model: ObservableObject {
    @Published var config: FanConfig { didSet { if config != oldValue { scheduleSave() } } }
    @Published var temps: [TempSource: Double] = [:]
    @Published var fans: [Fan] = []
    @Published var status: DaemonStatus?
    @Published var saveError: String?
    @Published var history: [Double] = []   // recent temps of the selected source

    let hw: Hardware?
    private var timer: Timer?
    private var saveTask: Task<Void, Never>?

    init() {
        hw = try? Hardware()
        config = Paths.loadConfig()
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

    func refresh() {
        guard let hw else { return }
        for s in TempSource.allCases { temps[s] = hw.temperature(s) }
        fans = hw.fans()
        status = Paths.loadStatus()
        if let t = currentTemp { history.append(t); if history.count > 120 { history.removeFirst() } }
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

    func applyPreset(_ name: String) { if let p = FanConfig.presets[name] { config.points = p } }
}
