import AppKit
import SMCKit
import SwiftUI

// MARK: - Fans

struct FansPage: View {
    @EnvironmentObject var model: Model

    var body: some View {
        form
            .onAppear { model.liveUpdates = true }
            .onDisappear { model.liveUpdates = false }
    }

    private var form: some View {
        Form {
            PageHeader(page: .fans, description: "Choose how your Mac's fans respond to temperature, from silent to full speed.")

            Section {
                HStack(spacing: 0) {
                    StatTile(title: "Following", value: fmt(model.currentTemp), symbol: "thermometer.medium", tint: tempTint)
                    StatTile(title: "Target", value: targetText, symbol: "target", tint: .blue)
                    ForEach(model.fans) { f in
                        StatTile(title: "Fan \(f.id + 1)", value: f.actual < 100 ? "Off" : "\(Int(f.actual)) rpm", symbol: "fan", tint: .teal)
                    }
                }
            }

            Section {
                Toggle(isOn: $model.config.enabled) {
                    Text("Use fan curve")
                    Text("When off, macOS controls the fans as usual.")
                }
                Picker("Follow temperature", selection: $model.config.source) {
                    ForEach(TempSource.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Profile") { ProfileMenu().fixedSize() }
            } footer: {
                daemonFooter
            }

            Section {
                // Profile actions sit directly above the curve they apply to.
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.activeProfile ?? "Custom curve").font(.headline)
                        Text(profileHint).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ProfileButtons()
                }
                CurveEditor(points: $model.config.points, currentTemp: model.currentTemp, fanMin: model.fanMin, fanMax: model.fanMax)
                    .frame(height: 300)
                    .padding(.vertical, 6)
            } header: {
                Text("Curve")
            } footer: {
                Footer(curveSummary + " Drag points to reshape the curve, double-click to add one, right-click a point to delete it.")
            }

            Section {
                LabeledContent("Smoothing") {
                    HStack {
                        Slider(value: rounded($model.config.smoothing, to: 1), in: 1...20).frame(width: 180)
                        Text("\(Int(model.config.smoothing)) s").monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                    }
                }
                LabeledContent("Spin-up delay") {
                    HStack {
                        Slider(value: rounded($model.config.spinUpDelay, to: 5), in: 0...60).frame(width: 180)
                        Text("\(Int(model.config.spinUpDelay)) s").monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                    }
                }
                LabeledContent("Always max above") {
                    Stepper("\(Int(model.config.criticalTemp)) °C", value: $model.config.criticalTemp, in: 80...105, step: 1)
                }
            } header: {
                Text("Behaviour")
            } footer: {
                Footer("Smoothing evens out quick temperature swings. Idle fans wait for the spin-up delay before starting, so short bursts of work don't wake them. Above the maximum temperature, fans always run flat out.")
            }

            FanHistorySection()

            AutoProfilesSection()
        }
        .formStyle(.grouped)
    }

    private var profileHint: String {
        guard let a = model.activeProfile else { return "Not saved as a profile yet" }
        return model.isBuiltIn(a) ? "Built-in profile" : "Your profile"
    }

    private var curveSummary: String {
        guard let start = model.config.startTemp(fanMin: model.fanMin) else { return "This curve keeps the fans off." }
        if start <= 20.5 { return "This curve keeps the fans running at all times." }
        let delay = Int(model.config.spinUpDelay)
        return "Fans start at \(Int(start.rounded())) °C\(delay > 0 ? " after \(delay) s" : "") and stop below \(Int((start - 3).rounded())) °C."
    }

    private var tempTint: Color {
        guard let t = model.currentTemp else { return .secondary }
        return t >= 85 ? .red : t >= 70 ? .orange : .green
    }

    private var targetText: String {
        guard model.daemonRunning, let s = model.status else { return "--" }
        switch s.mode {
        case "curve": return "\(Int(s.targetRPM ?? 0)) rpm"
        case "critical": return "Max"
        default: return "Auto"
        }
    }

    @ViewBuilder private var daemonFooter: some View {
        if let e = model.saveError {
            StatusRow(text: e, color: .orange)
        } else if !model.daemonRunning {
            StatusRow(text: "Fan service isn't running, so the curve won't be applied. Run sudo ./install.sh in the project folder.", color: .red)
        } else if let s = model.status {
            switch s.mode {
            case "curve": StatusRow(text: "Fan service is applying your curve.", color: .green)
            case "critical": StatusRow(text: "Above \(Int(model.config.criticalTemp)) °C: fans at maximum.", color: .red)
            case "error": StatusRow(text: "Fan service error: \(s.message ?? "unknown"). macOS is in control.", color: .red)
            default:
                if let m = s.message, m.hasPrefix("waiting") {
                    StatusRow(text: "Warming up: " + m.replacingOccurrences(of: "waiting — ", with: "") + ".", color: .orange)
                } else {
                    StatusRow(text: model.config.enabled ? "Fans are idle. macOS keeps them off until the curve needs them." : "macOS is controlling the fans.", color: .secondary)
                }
            }
        }
    }
}
