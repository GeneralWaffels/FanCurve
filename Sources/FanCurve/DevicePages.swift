import AppKit
import SMCKit
import SwiftUI

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
            PageHeader(page: .displays, description: "Control the brightness of external monitors, with the keyboard or automatically from your MacBook's light sensor.")

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
                                .labelsHidden()
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

            BrightnessKeysSection()

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

struct BrightnessKeysSection: View {
    @EnvironmentObject var keys: BrightnessKeys

    var body: some View {
        Section {
            Picker("Brightness keys control", selection: $keys.mode) {
                ForEach(BrightnessKeys.Mode.allCases) { Text($0.label).tag($0) }
            }
            if keys.mode != .off { AccessibilityRow(feature: "use the brightness keys for external displays") }
        } header: {
            Text("Brightness Keys")
        } footer: {
            Footer(keys.mode == .underPointer
                   ? "The keys change whichever display the pointer is on. Hold ⌥⇧ for finer steps."
                   : keys.mode == .all ? "The keys change the built-in and external displays together. Hold ⌥⇧ for finer steps."
                   : "The keys only change the MacBook's own display, as usual.")
        }
    }
}

// MARK: - General

struct GeneralPage: View {
    @EnvironmentObject var loginItem: LoginItem
    @EnvironmentObject var updater: Updater

    var body: some View {
        Form {
            PageHeader(page: .general, description: "Startup and software updates for FanCurve on this Mac.")

            Section {
                Toggle("Open at login", isOn: Binding(get: { loginItem.enabled }, set: { loginItem.set($0) }))
                if loginItem.needsApproval {
                    LabeledContent {
                        Button("Open Login Items…") { loginItem.openLoginItemsSettings() }
                    } label: {
                        StatusRow(text: "Allow FanCurve in Login Items to finish turning this on.", color: .orange)
                    }
                }
                if let e = loginItem.error { StatusRow(text: e, color: .red) }
            } header: {
                Text("Startup")
            } footer: {
                Footer("FanCurve starts in the menu bar when you log in. The fan service runs regardless, so your curve applies even before you log in.")
            }

            Section {
                LabeledContent("Current version", value: updater.currentVersion)
                Picker("Update from", selection: $updater.source) {
                    ForEach(Updater.Source.allCases) { Text($0.label).tag($0) }
                }
                if updater.source == .github {
                    TextField("Repository", text: $updater.repo, prompt: Text("owner/name"))
                    LabeledContent("Access token") {
                        if updater.hasToken {
                            HStack {
                                Label("Saved in Keychain", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                                Button("Remove") { updater.setToken("") }
                            }
                        } else {
                            TokenField { updater.setToken($0) }
                        }
                    }
                } else {
                    TextField("Update server", text: $updater.serverURL, prompt: Text("Address from ./serve.sh on"))
                }
                LabeledContent {
                    updateAction
                } label: {
                    updateStatus
                }
            } header: {
                Text("Software Update")
            } footer: {
                Footer(updater.source == .github
                       ? "FanCurve installs the latest GitHub release of this repository. Private forks need a fine-grained token with read-only access to Contents (github.com → Settings → Developer settings → Fine-grained tokens), kept in your Keychain; public repositories don't. Installing asks for your administrator password because the fan service is updated too."
                       : "Paste the address that ./serve.sh on prints on the Mac you build FanCurve on. Installing asks for your administrator password because the fan service is updated too.")
            }

            DiagnosticsSection()
        }
        .formStyle(.grouped)
        .onAppear { loginItem.refresh() }
    }

    @ViewBuilder private var updateStatus: some View {
        switch updater.state {
        case .idle: StatusRow(text: updater.isConfigured ? "Not checked yet." : "Not set up yet.", color: .secondary)
        case .checking: StatusRow(text: "Checking…", color: .secondary)
        case .upToDate: StatusRow(text: "FanCurve is up to date.", color: .green)
        case .available(let v): StatusRow(text: "Version \(v) is available.", color: .blue)
        case .downloading: StatusRow(text: "Downloading…", color: .blue)
        case .installing: StatusRow(text: "Installing: FanCurve will restart.", color: .blue)
        case .failed(let m): StatusRow(text: m, color: .red)
        }
    }

    @ViewBuilder private var updateAction: some View {
        switch updater.state {
        case .available: Button("Install Update") { updater.install() }.buttonStyle(.borderedProminent)
        case .checking, .downloading, .installing: ProgressView().controlSize(.small)
        default: Button("Check Now") { updater.check(userInitiated: true) }.disabled(!updater.isConfigured)
        }
    }
}

/// Secure token entry with its own draft state (the Command Line Tools can't expand SwiftUI's @State macro).
struct TokenField: View {
    let save: (String) -> Void
    @StateObject private var draft = Draft()
    final class Draft: ObservableObject { @Published var text = "" }

    var body: some View {
        HStack {
            SecureField("Access token", text: $draft.text, prompt: Text("github_pat_…")).labelsHidden().frame(width: 220)
            Button("Save") { save(draft.text); draft.text = "" }.disabled(draft.text.isEmpty)
        }
    }
}

// MARK: - Microphone

struct MicPage: View {
    @EnvironmentObject var mic: MicMuter

    var body: some View {
        Form {
            PageHeader(page: .mic, description: "Mute every microphone on your Mac at once, from anywhere, with a keyboard shortcut.")

            Section {
                Toggle(isOn: Binding(get: { mic.isMuted }, set: { mic.setMuted($0) })) {
                    Text("Mute microphone")
                    Text(mic.isMuted ? "Every input device is silenced." : "Apps can hear you.")
                }
            } footer: {
                Footer("Mutes the built-in mic, headsets and USB mics, including ones plugged in while muted. Apps just receive silence. Quitting FanCurve unmutes you.")
            }

            Section {
                LabeledContent("Toggle shortcut") { ShortcutRecorder(shortcut: $mic.shortcut) }
                ShortcutWarnings(shortcut: mic.shortcut, conflict: mic.shortcutConflict)
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

// MARK: - Keep awake

struct KeepAwakePage: View {
    @EnvironmentObject var jiggler: MouseJiggler

    var body: some View {
        Form {
            PageHeader(page: .awake, description: "Keep your Mac awake, and apps showing you as active, by nudging the mouse while you're away.")

            Section {
                Toggle(isOn: $jiggler.enabled) {
                    Text("Mouse jiggler")
                    Text("Moves the pointer across every monitor, then back to where it was.")
                }
                if jiggler.enabled { AccessibilityRow(feature: "move the mouse") }
            } footer: {
                statusFooter
            }

            Section {
                LabeledContent("Start after being idle for") {
                    HStack {
                        Slider(value: rounded($jiggler.idleMinutes, to: 1), in: 1...60).frame(width: 180)
                        Text("\(Int(jiggler.idleMinutes)) min").monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                    }
                }
                Picker("Move the mouse every", selection: $jiggler.intervalSeconds) {
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                }
            } header: {
                Text("Timing")
            } footer: {
                Footer("It stops the moment you use the mouse or keyboard. With the lid closed it never runs, so your Mac sleeps as usual, unless an external display is connected (clamshell mode).")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var statusFooter: some View {
        switch jiggler.state {
        case .off: StatusRow(text: "Off.", color: .secondary)
        case .waiting(let idle):
            let left = max(0, Int(jiggler.idleMinutes * 60 - idle))
            StatusRow(text: "Waiting: starts after \(Int(jiggler.idleMinutes)) min without input (\(mmss(left)) to go).", color: .secondary)
        case .active(let last):
            StatusRow(text: "Active: last moved \(last.formatted(.relative(presentation: .named))).", color: .green)
        case .lidClosed: StatusRow(text: "Paused: the lid is closed, so your Mac is allowed to sleep.", color: .orange)
        case .needsPermission: StatusRow(text: "Waiting for Accessibility access.", color: .orange)
        }
    }
}

// MARK: - Keyboard

struct KeyboardPage: View {
    @EnvironmentObject var keyboard: KeyboardBlocker

    var body: some View {
        Form {
            PageHeader(page: .keyboard, description: "Clean your keyboard without typing into anything. The trackpad keeps working so you can switch it off.")

            Section {
                Toggle(isOn: Binding(get: { keyboard.isOn }, set: { _ in keyboard.toggle() })) {
                    Text("Keyboard cleaning mode")
                    Text(keyboard.isOn ? "Keys are ignored. Turns off automatically in \(mmss(keyboard.secondsLeft))." : "Ignores every key press.")
                }
                AccessibilityRow(feature: "block the keyboard while you clean it")
            } footer: {
                Footer("Use the trackpad to switch it off, or wait \(keyboard.timeout / 60) minutes. The power button and Touch ID can't be blocked.")
            }
        }
        .formStyle(.grouped)
    }
}
