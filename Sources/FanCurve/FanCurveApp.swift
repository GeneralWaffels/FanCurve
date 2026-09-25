import SwiftUI
import SMCKit

@main
struct FanCurveApp: App {
    @StateObject private var model = Model()
    @StateObject private var keyboard = KeyboardBlocker()
    @StateObject private var displays = Displays()

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(model).environmentObject(keyboard).environmentObject(displays)
        } label: {
            if keyboard.isOn {
                Label("Keyboard off \(keyboard.secondsLeft / 60):\(String(format: "%02d", keyboard.secondsLeft % 60))", systemImage: "keyboard.badge.ellipsis")
                    .labelStyle(.titleAndIcon)
            } else {
                fanLabel
            }
        }

        Window("FanCurve", id: "editor") {
            TabView {
                EditorView().tabItem { Label("Fans", systemImage: "fan") }
                DisplaysView().tabItem { Label("Displays", systemImage: "display") }
                KeyboardView().tabItem { Label("Keyboard", systemImage: "keyboard") }
            }
            .environmentObject(model).environmentObject(keyboard).environmentObject(displays)
        }
        .defaultSize(width: 720, height: 600)
    }

    @ViewBuilder private var fanLabel: some View {
        let t = model.currentTemp.map { "\(Int($0))°" } ?? "--"
        let rpm = model.fans.first.map { $0.actual < 100 ? "off" : "\(Int($0.actual))" } ?? ""
        Label("\(t)  \(rpm)", systemImage: model.config.enabled ? "fan.fill" : "fan")
            .labelStyle(.titleAndIcon)
    }
}

struct MenuContent: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var keyboard: KeyboardBlocker
    @EnvironmentObject var displays: Displays
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("CPU \(fmt(model.temps[.cpuMax]))  ·  GPU \(fmt(model.temps[.gpuMax]))")
        ForEach(model.fans) { f in Text("Fan \(f.id + 1): \(Int(f.actual)) rpm") }
        Divider()
        Toggle("Use fan curve", isOn: $model.config.enabled)
        Menu("Preset") {
            ForEach(FanConfig.presetOrder, id: \.self) { name in Button(name) { model.applyPreset(name) } }
        }
        Button("Edit curve…") { openWindow(id: "editor"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        if displays.monitors.isEmpty {
            Text("No external displays")
        } else {
            Toggle("Match laptop light sensor", isOn: $displays.followSensor)
            ForEach(displays.monitors) { m in
                Menu("\(m.name): \(Int(m.brightness))%") {
                    ForEach([0, 10, 25, 50, 75, 100], id: \.self) { v in
                        Button("\(v)%") { displays.setBrightness(Double(v), for: m.id) }
                    }
                }
            }
        }
        Divider()
        Toggle("Keyboard cleaning mode", isOn: Binding(get: { keyboard.isOn }, set: { _ in keyboard.toggle() }))
        if keyboard.needsPermission {
            Button("Grant Accessibility access…") { keyboard.openAccessibilitySettings() }
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}

struct EditorView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.daemonRunning {
                banner("Daemon not running — the curve won't be applied. Run `sudo ./install.sh` in the project folder.", .red)
            } else if let s = model.status, s.mode == "error" {
                banner("Daemon error: \(s.message ?? "unknown")", .red)
            }
            if let e = model.saveError { banner(e, .orange) }

            HStack(spacing: 16) {
                Toggle("Use fan curve", isOn: $model.config.enabled).toggleStyle(.switch)
                Picker("Follow", selection: $model.config.source) {
                    ForEach(TempSource.allCases) { Text($0.label).tag($0) }
                }
                .frame(maxWidth: 320)
                Spacer()
                Menu("Preset") {
                    ForEach(FanConfig.presetOrder, id: \.self) { name in Button(name) { model.applyPreset(name) } }
                }
                .fixedSize()
            }

            CurveEditor(points: $model.config.points, currentTemp: model.currentTemp, fanMin: model.fanMin, fanMax: model.fanMax)
                .frame(minHeight: 300)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))

            Text("Drag points to shape the curve · double-click to add · right-click to delete")
                .font(.caption).foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 28) {
                stat("Following", fmt(model.currentTemp))
                stat("Smoothed", fmt(model.status?.smoothedTemp))
                stat("Daemon", daemonText)
                ForEach(model.fans) { f in
                    stat("Fan \(f.id + 1)", f.actual < 100 ? "off" : "\(Int(f.actual)) rpm")
                }
                Spacer()
            }

            HStack(spacing: 24) {
                LabeledContent("Smoothing") {
                    Slider(value: $model.config.smoothing, in: 1...20, step: 1).frame(width: 140)
                    Text("\(Int(model.config.smoothing)) s").monospacedDigit().frame(width: 36)
                }
                LabeledContent("Always max above") {
                    Stepper("\(Int(model.config.criticalTemp)) °C", value: $model.config.criticalTemp, in: 80...105, step: 1)
                }
                Spacer()
            }
            .font(.callout)

        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 520)
    }

    private var daemonText: String {
        guard model.daemonRunning, let s = model.status else { return "stopped" }
        switch s.mode {
        case "curve": return "\(Int(s.targetRPM ?? 0)) rpm"
        case "critical": return "MAX (critical)"
        case "auto": return "macOS auto"
        default: return s.mode
        }
    }

    private func banner(_ text: String, _ color: Color) -> some View {
        Text(text).font(.callout).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.15)))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
        }
    }
}

func fmt(_ t: Double?) -> String { t.map { String(format: "%.0f °C", $0) } ?? "--" }
