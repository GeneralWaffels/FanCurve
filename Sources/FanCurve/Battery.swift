import AppKit
import IOKit
import SwiftUI

/// Battery health from the AppleSmartBattery registry entry (the same data System Information shows).
struct BatteryInfo: Equatable {
    var percent: Int
    var charging: Bool
    var pluggedIn: Bool
    var fullyCharged: Bool
    var cycles: Int
    var designCycles: Int?
    /// Maximum capacity as macOS reports it in Settings (%).
    var maxCapacity: Int?
    var designCapacity: Int?     // mAh
    var fullCapacity: Int?       // mAh, what the battery holds now
    var voltage: Double?         // V
    var watts: Double?           // + charging, − discharging
    var adapter: String?
    var adapterWatts: Int?
    var minutesLeft: Int?
    var temperature: Double?     // °C
    var notChargingReason: Int?

    /// Measured health: what it holds now against what it held new.
    var health: Double? {
        guard let d = designCapacity, d > 0, let f = fullCapacity else { return nil }
        return min(Double(f) / Double(d), 1.05)
    }

    static func read() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return nil }
        let data = d["BatteryData"] as? [String: Any] ?? [:]
        func int(_ k: String) -> Int? { (d[k] as? Int) ?? (data[k] as? Int) }
        let adapter = d["AdapterDetails"] as? [String: Any]
        let charger = d["ChargerData"] as? [String: Any]
        let amps = (d["InstantAmperage"] as? Int).map { Double(Int16(truncatingIfNeeded: $0)) }   // signed mA
        let volts = (d["Voltage"] as? Int).map { Double($0) / 1000 }
        var minutes: Int?
        if let t = int("TimeRemaining"), t > 0, t < 65535 { minutes = t }
        let temp = (int("Temperature") ?? int("VirtualTemperature")).map { Double($0) / 100 }
        return BatteryInfo(
            percent: int("CurrentCapacity") ?? 0,
            charging: d["IsCharging"] as? Bool ?? false,
            pluggedIn: d["ExternalConnected"] as? Bool ?? false,
            fullyCharged: d["FullyCharged"] as? Bool ?? false,
            cycles: int("CycleCount") ?? 0,
            designCycles: int("DesignCycleCount9C"),
            maxCapacity: int("MaxCapacity"),
            designCapacity: int("DesignCapacity"),
            fullCapacity: int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity") ?? int("FullChargeCapacity"),
            voltage: volts,
            watts: amps.flatMap { a in volts.map { a / 1000 * $0 } },
            adapter: adapter?["Name"] as? String,
            adapterWatts: adapter?["Watts"] as? Int,
            minutesLeft: minutes,
            temperature: temp.flatMap { $0 > 0 && $0 < 80 ? $0 : nil },
            notChargingReason: charger?["NotChargingReason"] as? Int)
    }
}

@MainActor
final class BatteryMonitor: ObservableObject {
    @Published private(set) var info: BatteryInfo?
    private var timer: Timer?

    func start() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        let i = BatteryInfo.read()
        if i != info { info = i }
    }
}

struct BatteryPage: View {
    @StateObject private var battery = BatteryMonitor()

    var body: some View {
        Form {
            PageHeader(page: .battery, description: "How healthy your battery is, and what it's doing right now.")
            if let b = battery.info {
                Section {
                    HStack(spacing: 0) {
                        StatTile(title: "Charge", value: "\(b.percent)%", symbol: b.charging ? "battery.100percent.bolt" : "battery.75percent", tint: .green)
                        StatTile(title: "Health", value: b.health.map { "\(Int(($0 * 100).rounded()))%" } ?? "--", symbol: "heart.fill", tint: healthTint(b))
                        StatTile(title: "Cycles", value: "\(b.cycles)", symbol: "arrow.triangle.2.circlepath", tint: .blue)
                        StatTile(title: "Power", value: b.watts.map { String(format: "%+.1f W", $0) } ?? "--", symbol: "bolt.fill", tint: .orange)
                    }
                }
                Section("Right Now") {
                    LabeledContent("State", value: stateText(b))
                    if let m = b.minutesLeft { LabeledContent(b.charging ? "Time to full" : "Time left", value: "\(m / 60) h \(m % 60) min") }
                    if let a = b.adapter { LabeledContent("Charger", value: a + (b.adapterWatts.map { " · \($0) W" } ?? "")) }
                    if let v = b.voltage { LabeledContent("Voltage", value: String(format: "%.2f V", v)) }
                    if let t = b.temperature { LabeledContent("Temperature", value: String(format: "%.1f °C", t)) }
                }
                Section {
                    if let m = b.maxCapacity { LabeledContent("Maximum capacity (macOS)", value: "\(m)%") }
                    if let f = b.fullCapacity, let d = b.designCapacity {
                        LabeledContent("Measured capacity", value: "\(f) of \(d) mAh")
                    }
                    LabeledContent("Charge cycles", value: "\(b.cycles)" + (b.designCycles.map { " of \($0) rated" } ?? ""))
                } header: {
                    Text("Health")
                } footer: {
                    Footer("Measured capacity is what the battery holds now against what it held new; macOS rounds its own figure. Apple rates MacBook batteries to keep 80% capacity for \(b.designCycles ?? 1000) cycles.")
                }
                Section {
                    LabeledContent("Charging") {
                        Button("Open Battery Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
                        }
                    }
                } footer: {
                    Footer("Use Optimised Battery Charging in System Settings → Battery (the ⓘ next to Battery Health), plus a charge limit if your macOS version offers one. FanCurve doesn't set its own limit: the M5's SMC doesn't expose the charging keys that tools like AlDente use on older Macs, and guessing at battery controls isn't safe.")
                }
            } else {
                Section { StatusRow(text: "This Mac doesn't have a battery.", color: .secondary) }
            }
        }
        .formStyle(.grouped)
        .onAppear { battery.start() }
        .onDisappear { battery.stop() }
    }

    private func stateText(_ b: BatteryInfo) -> String {
        if b.charging { return "Charging" }
        if b.pluggedIn { return b.fullyCharged || b.percent >= 100 ? "Charged, on power" : "On power, not charging (macOS is managing the charge)" }
        return "On battery"
    }

    private func healthTint(_ b: BatteryInfo) -> Color {
        guard let h = b.health else { return .secondary }
        return h >= 0.8 ? .green : h >= 0.7 ? .orange : .red
    }
}
