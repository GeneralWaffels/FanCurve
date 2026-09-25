import SwiftUI
import SMCKit

// System Settings–style window: sidebar with tinted icon tiles, grouped forms on the right,
// Liquid Glass surfaces on macOS 26+ (falls back to materials on older systems).

struct SettingsView: View {
    @EnvironmentObject var nav: AppNav

    var body: some View {
        NavigationSplitView {
            // Only write back real changes: republishing an unchanged value makes SwiftUI re-render in a loop.
            List(selection: Binding(get: { Optional(nav.page) }, set: { if let p = $0, p != nav.page { nav.page = p } })) {
                SidebarHeader()
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 12, trailing: 4))
                    .selectionDisabled()
                ForEach(AppNav.Page.allCases) { page in
                    Label { Text(page.title) } icon: { IconTile(symbol: page.symbol, tint: page.tint) }
                        .padding(.vertical, 1)
                        .tag(page)
                }
            }
            .listStyle(.sidebar)
            .contentMargins(.horizontal, 10, for: .scrollContent)
            .contentMargins(.top, 6, for: .scrollContent)
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            Group {
                switch nav.page {
                case .fans: FansPage()
                case .displays: DisplaysPage()
                case .mic: MicPage()
                case .keyboard: KeyboardPage()
                }
            }
            .navigationTitle(nav.page.title)
        }
        .frame(minWidth: 780, minHeight: 580)
    }
}

/// App identity row at the top of the sidebar, like the Apple Account row in System Settings.
struct SidebarHeader: View {
    @EnvironmentObject var model: Model

    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: "fan.fill", tint: .blue, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("FanCurve").font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private var summary: String {
        let temp = model.currentTemp.map { "\(Int($0.rounded())) °C" } ?? "--"
        guard model.config.enabled else { return "\(temp) · macOS" }
        return model.status?.mode == "curve" ? "\(temp) · Curve active" : "\(temp) · Fans idle"
    }
}

/// Rounded, tinted SF Symbol tile like the ones in System Settings' sidebar.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(tint.gradient))
    }
}

/// Big number + caption, used in the glass stat strip.
struct StatTile: View {
    let title: String
    let value: String
    var symbol: String? = nil
    var tint: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).foregroundStyle(tint) }
                Text(title)
            }
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

/// Section footer text, leading-aligned like System Settings (grouped Form footers default to trailing).
struct Footer: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Inline status row: coloured dot + text.
struct StatusRow: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.leading)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Slider binding that snaps to a step without drawing tick marks (like System Settings' sliders).
func rounded(_ b: Binding<Double>, to step: Double) -> Binding<Double> {
    Binding(get: { b.wrappedValue }, set: { b.wrappedValue = ($0 / step).rounded() * step })
}

func mmss(_ seconds: Int) -> String { "\(seconds / 60):\(String(format: "%02d", seconds % 60))" }

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
        }
        .formStyle(.grouped)
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

// MARK: - Displays

struct DisplaysPage: View {
    @EnvironmentObject var displays: Displays

    var body: some View {
        form
            .onAppear { displays.pageVisible = true }
            .onDisappear { displays.pageVisible = false }
    }

    private var form: some View {
        Form {
            Section {
                if displays.monitors.isEmpty {
                    HStack(spacing: 12) {
                        IconTile(symbol: "display", tint: .gray, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No external displays connected")
                            Text("Works over USB-C, Thunderbolt and DisplayPort.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Rescan") { displays.rescan() }
                    }
                    .padding(.vertical, 2)
                }
                ForEach(displays.monitors) { m in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            IconTile(symbol: "display", tint: .indigo, size: 20)
                            Text(m.name)
                            Spacer()
                            Text("\(Int(m.brightness))%").monospacedDigit().foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Image(systemName: "sun.min").foregroundStyle(.secondary)
                            Slider(value: Binding(get: { m.brightness }, set: { displays.setBrightness($0.rounded(), for: m.id) }), in: 0...100)
                            Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
                        }
                        if !m.readable {
                            Text("This display didn't answer a brightness read, but may still accept changes.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("External Displays")
            } footer: {
                if !displays.monitors.isEmpty {
                    Footer("Some HDMI ports and docks don't pass brightness control (DDC) through.")
                }
            }

            Section {
                Toggle(isOn: $displays.followSensor) {
                    Text("Match laptop light sensor")
                    Text("Sets external brightness from the ambient light around your MacBook.")
                }
                LabeledContent("Ambient light") {
                    Text(displays.lux.map { "\(Int($0)) lux" } ?? (displays.sensor.available ? "--" : "No sensor"))
                        .monospacedDigit()
                }
                LabeledContent("Sensor target") {
                    Text(displays.lux.map { "\(Int(Displays.brightness(forLux: $0, min: displays.minBrightness, max: displays.maxBrightness)))%" } ?? "--")
                        .monospacedDigit()
                }
                LabeledContent("Darkest") { percentSlider($displays.minBrightness) }
                LabeledContent("Brightest") { percentSlider($displays.maxBrightness) }
            } header: {
                Text("Automatic Brightness")
            } footer: {
                if displays.sensorPaused {
                    StatusRow(text: "Lid closed: the sensor is covered, so brightness is held.", color: .orange)
                } else {
                    Footer("A dark room uses Darkest; \(Int(Displays.fullBrightLux)) lux or more (bright office, daylight) uses Brightest. Moving a slider by hand turns this off.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func percentSlider(_ value: Binding<Double>) -> some View {
        HStack {
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.rounded() }), in: 0...100).frame(width: 200)
            Text("\(Int(value.wrappedValue))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
    }
}

// MARK: - Microphone

struct MicPage: View {
    @EnvironmentObject var mic: MicMuter

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    IconTile(symbol: mic.isMuted ? "mic.slash.fill" : "mic.fill", tint: mic.isMuted ? .red : .green, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mic.isMuted ? "Microphone muted" : "Microphone live").font(.headline)
                        Text(mic.isMuted ? "Every input device is silenced." : "Apps can hear you.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Mute", isOn: Binding(get: { mic.isMuted }, set: { mic.setMuted($0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.large)
                }
                .padding(.vertical, 4)
            } footer: {
                Footer("Mutes the built-in mic, headsets and USB mics, including ones plugged in while muted. Apps just receive silence. Quitting FanCurve unmutes you.")
            }

            Section {
                LabeledContent("Toggle shortcut") { ShortcutRecorder(shortcut: $mic.shortcut) }
                if mic.shortcutConflict, let s = mic.shortcut {
                    StatusRow(text: "\(s.display) is already used by macOS or another app. Pick a different combination.", color: .red)
                }
            } header: {
                Text("Keyboard Shortcut")
            } footer: {
                Footer("Works from any app. Use at least one of ⌘ ⌥ ⌃ ⇧, or an F-key. Esc cancels recording, Delete clears it.")
            }

            Section("Menu Bar") {
                Picker("Show mic icon", selection: $mic.indicator) {
                    ForEach(MicMuter.IndicatorMode.allCases) { Text($0.label).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Keyboard

struct KeyboardPage: View {
    @EnvironmentObject var keyboard: KeyboardBlocker

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    IconTile(symbol: keyboard.isOn ? "keyboard.badge.ellipsis" : "keyboard.fill", tint: keyboard.isOn ? .orange : .gray, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keyboard cleaning mode").font(.headline)
                        Text(keyboard.isOn ? "Keys are ignored. Turns off automatically in \(mmss(keyboard.secondsLeft))."
                                           : "Ignores every key press while the trackpad keeps working.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Cleaning mode", isOn: Binding(get: { keyboard.isOn }, set: { _ in keyboard.toggle() }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.large)
                }
                .padding(.vertical, 4)
                if keyboard.needsPermission {
                    LabeledContent {
                        Button("Open Accessibility Settings…") { keyboard.openAccessibilitySettings() }
                    } label: {
                        StatusRow(text: "FanCurve needs Accessibility access to block keys.", color: .orange)
                    }
                }
            } footer: {
                Footer("Use the trackpad to switch it off, or wait \(keyboard.timeout / 60) minutes. The power button and Touch ID can't be blocked.")
            }
        }
        .formStyle(.grouped)
    }
}
