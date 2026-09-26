import AppKit
import ApplicationServices
import SMCKit
import SwiftUI
import UniformTypeIdentifiers

/// A plain-text report for bug reports: versions, hardware, fan config and service log, and which
/// features are on. It never includes anything you've typed, copied or written in notes.
@MainActor
enum Diagnostics {
    static func report(model: Model, autocomplete: Autocomplete, aero: AeroSpace, updater: Updater) -> String {
        var out: [String] = []
        func line(_ k: String, _ v: Any?) { out.append("\(k): \(v.map { "\($0)" } ?? "–")") }
        func header(_ t: String) { out.append(""); out.append("## \(t)") }

        out.append("# FanCurve diagnostics · \(Date().formatted(.iso8601))")
        header("System")
        line("FanCurve", updater.currentVersion)
        line("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
        line("Model", sysctl("hw.model"))
        line("Chip", sysctl("machdep.cpu.brand_string"))
        line("Memory", "\(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB")
        line("Battery", BatteryInfo.read().map { "\($0.percent)%, \($0.cycles) cycles, health \($0.health.map { "\(Int($0 * 100))%" } ?? "–")" })

        header("Fans")
        line("SMC readable", model.hw != nil)
        for f in model.fans { line("Fan \(f.id + 1)", "\(Int(f.actual)) rpm (target \(Int(f.target)), \(Int(f.min))–\(Int(f.max)), manual \(f.manual))") }
        for (k, v) in model.temps.sorted(by: { $0.key.rawValue < $1.key.rawValue }) { line("Temp \(k.rawValue)", String(format: "%.1f °C", v)) }
        line("Service running", model.daemonRunning)
        line("Service status", model.status.map { "\($0.mode) \($0.message ?? "")" })
        out.append("Config: " + ((try? String(contentsOf: Paths.config, encoding: .utf8)) ?? "unreadable"))

        header("Features")
        line("Accessibility access", AXIsProcessTrusted())
        line("Autocomplete", autocomplete.enabled ? "\(autocomplete.engine) · \(autocomplete.usingApple ? "Apple model" : autocomplete.modelFile) · paused \(autocomplete.paused)" : "off")
        line("Autocomplete status", autocomplete.status)
        line("llama-server", autocomplete.serverPath ?? "not installed")
        line("Apple model available", Autocomplete.appleModelAvailable)
        line("AeroSpace", aero.installed ? "\(aero.version ?? "?") running \(aero.running)" : "not installed")

        header("Fan service log (last 60 lines)")
        let log = (try? String(contentsOfFile: "/var/log/fancurved.log", encoding: .utf8)) ?? "unreadable"
        out.append(log.split(separator: "\n", omittingEmptySubsequences: false).suffix(60).joined(separator: "\n"))
        return out.joined(separator: "\n")
    }

    /// Asks where to save the report, then shows it in Finder.
    static func export(model: Model, autocomplete: Autocomplete, aero: AeroSpace, updater: Updater) {
        let text = report(model: model, autocomplete: autocomplete, aero: aero, updater: updater)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "FanCurve Diagnostics \(Date().formatted(.iso8601.year().month().day())).txt"
        panel.allowedContentTypes = [.plainText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}

struct DiagnosticsSection: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var autocomplete: Autocomplete
    @EnvironmentObject var aero: AeroSpace
    @EnvironmentObject var updater: Updater

    var body: some View {
        Section {
            LabeledContent("Diagnostics") {
                Button("Export…") { Diagnostics.export(model: model, autocomplete: autocomplete, aero: aero, updater: updater) }
            }
        } header: {
            Text("Troubleshooting")
        } footer: {
            Footer("Saves a text file with versions, fan readings, your fan settings and the fan service log, to attach to a bug report. It never includes anything you've typed, copied or written. Read it before sharing.")
        }
    }
}
