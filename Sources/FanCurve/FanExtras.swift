import AppKit
import Charts
import CoreAudio
import SMCKit
import SwiftUI

// MARK: - History graph

/// Temperature and fan speed over the last 10 minutes to 3 hours.
struct FanHistorySection: View {
    @EnvironmentObject var model: Model
    @AppStorage("historyMinutes") private var minutes = 30

    var body: some View {
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
        let samples = model.history.filter { $0.id >= cutoff }
        Section {
            if samples.count < 3 {
                Text("Collecting readings… the graph fills in over the next minute.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                chart("Temperature", unit: "°C", tint: .orange, samples.compactMap { s in s.temp.map { (s.id, $0) } })
                chart("Fan speed", unit: "rpm", tint: .teal, samples.map { ($0.id, $0.rpm) })
            }
        } header: {
            HStack {
                Text("History")
                Spacer()
                Picker("", selection: $minutes) {
                    Text("10 min").tag(10); Text("30 min").tag(30); Text("1 hour").tag(60); Text("3 hours").tag(180)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        } footer: {
            Footer(summary(samples))
        }
    }

    private func chart(_ title: String, unit: String, tint: Color, _ points: [(Date, Double)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                if let last = points.last { Text("\(Int(last.1)) \(unit)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary) }
            }
            Chart {
                ForEach(points, id: \.0) { p in
                    AreaMark(x: .value("Time", p.0), y: .value(title, p.1))
                        .foregroundStyle(LinearGradient(colors: [tint.opacity(0.25), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", p.0), y: .value(title, p.1))
                        .foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth: 1.6)).interpolationMethod(.monotone)
                }
            }
            .chartYScale(domain: .automatic(includesZero: unit == "rpm"))
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) } }
            .frame(height: 110)
        }
        .padding(.vertical, 4)
    }

    private func summary(_ s: [HistorySample]) -> String {
        let temps = s.compactMap(\.temp)
        guard let hi = temps.max(), let lo = temps.min() else { return "Readings are kept in memory for 3 hours." }
        let on = s.filter { $0.rpm > 0 }.count
        let pct = s.isEmpty ? 0 : Int((Double(on) / Double(s.count) * 100).rounded())
        return "Between \(Int(lo)) and \(Int(hi)) °C; fans ran \(pct)% of the time. Readings are kept in memory for 3 hours."
    }
}

// MARK: - Automatic profiles

/// Switches fan profiles by situation: on battery, on the charger, in a meeting, or while an app runs.
/// The first matching rule wins; when none match, your own curve comes back.
@MainActor
final class AutoProfiles: ObservableObject {
    enum Condition: Codable, Hashable {
        case battery, charger, meeting
        case app(bundle: String, name: String)

        var label: String {
            switch self {
            case .battery: return "On battery"
            case .charger: return "On the charger"
            case .meeting: return "In a meeting or call"
            case .app(_, let name): return "While \(name) is running"
            }
        }
        var symbol: String {
            switch self {
            case .battery: return "battery.50percent"
            case .charger: return "bolt.fill"
            case .meeting: return "video.fill"
            case .app: return "app.fill"
            }
        }
    }

    struct Rule: Codable, Identifiable, Equatable {
        var id = UUID()
        var condition: Condition
        var profile: String
    }

    @Published var enabled: Bool { didSet { save(); evaluate() } }
    @Published var rules: [Rule] { didSet { if rules != oldValue { save(); evaluate() } } }
    @Published private(set) var active: Rule?

    private let model: Model
    private let calendar: CalendarStore
    /// The curve to go back to when no rule applies.
    private var basePoints: [CurvePoint]?
    private var timer: Timer?

    init(model: Model, calendar: CalendarStore) {
        self.model = model; self.calendar = calendar
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "autoProfiles")
        rules = (d.data(forKey: "autoProfileRules")).flatMap { try? JSONDecoder().decode([Rule].self, from: $0) } ?? []
        if let p = d.data(forKey: "autoProfileBase") { basePoints = try? JSONDecoder().decode([CurvePoint].self, from: p) }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.evaluate() } }
        timer?.tolerance = 5
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
        }
        evaluate()
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(enabled, forKey: "autoProfiles")
        d.set(try? JSONEncoder().encode(rules), forKey: "autoProfileRules")
        d.set(basePoints.flatMap { try? JSONEncoder().encode($0) }, forKey: "autoProfileBase")
    }

    func matches(_ c: Condition) -> Bool {
        switch c {
        case .battery: return Autocomplete.isOnBattery
        case .charger: return !Autocomplete.isOnBattery
        case .meeting: return Self.microphoneInUse || (calendar.meetings.contains { $0.link != nil && $0.isOngoing() })
        case .app(let bundle, _): return !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
        }
    }

    /// Applies the first matching rule's profile, only when the matching rule changes, so you can still
    /// adjust the curve by hand in between.
    func evaluate() {
        let match = enabled ? rules.first { matches($0.condition) && model.points(for: $0.profile) != nil } : nil
        guard match?.id != active?.id || match?.profile != active?.profile else { return }
        if let match {
            if basePoints == nil { basePoints = model.config.points }   // kept across restarts
            model.applyPreset(match.profile)
        } else if let base = basePoints {
            model.config.points = base
            basePoints = nil
        }
        active = match
        save()
    }

    /// True while any app records from the default input device (a call, a recording, dictation).
    static var microphoneInUse: Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}

struct AutoProfilesSection: View {
    @EnvironmentObject var auto: AutoProfiles
    @EnvironmentObject var model: Model

    var body: some View {
        Section {
            Toggle(isOn: $auto.enabled) {
                Text("Switch profiles automatically")
                Text(statusText)
            }
            ForEach($auto.rules) { $rule in
                HStack(spacing: 10) {
                    IconTile(symbol: rule.condition.symbol, tint: .blue, size: 22)
                    Text(rule.condition.label)
                    Spacer()
                    Picker("", selection: $rule.profile) {
                        ForEach(FanConfig.presetOrder + model.customProfileNames, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Button { auto.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                }
                .opacity(auto.enabled ? 1 : 0.5)
            }
            Menu {
                ForEach([AutoProfiles.Condition.battery, .charger, .meeting], id: \.self) { c in
                    Button(c.label) { add(c) }.disabled(auto.rules.contains { $0.condition == c })
                }
                Menu("While an App Is Running") {
                    ForEach(runningApps, id: \.bundleIdentifier) { app in
                        Button(app.localizedName ?? "App") { add(.app(bundle: app.bundleIdentifier ?? "", name: app.localizedName ?? "App")) }
                    }
                }
            } label: { Label("Add Rule", systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize()
        } header: {
            Text("Automatic Profiles")
        } footer: {
            Footer("For example, Noctua Quiet on battery and during calls, Performance while a game or Xcode is running. The first rule that matches wins; when none match, your own curve comes back. Calls are detected from the microphone being in use or an ongoing calendar meeting with a link.")
        }
    }

    private var statusText: String {
        guard auto.enabled else { return "Off: the curve only changes when you change it." }
        if let a = auto.active { return "Now: \(a.profile) (\(a.condition.label.lowercased()))." }
        return auto.rules.isEmpty ? "Add a rule below." : "No rule matches right now, so your own curve is in use."
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
    }

    private func add(_ c: AutoProfiles.Condition) {
        let quiet = FanConfig.presetOrder.first ?? "Noctua Quiet"
        let profile: String
        switch c {
        case .battery, .meeting: profile = quiet
        case .charger: profile = FanConfig.presetOrder.dropFirst().first ?? quiet
        case .app: profile = FanConfig.presetOrder.last ?? quiet
        }
        auto.rules.append(.init(condition: c, profile: profile))
    }
}
