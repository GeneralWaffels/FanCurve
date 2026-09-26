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
                if nav.search.isEmpty {
                    SidebarHeader().selectionDisabled()
                }
                // Grouped like System Settings: General / hardware / productivity.
                ForEach(AppNav.Page.groups, id: \.self) { group in
                    let pages = nav.filteredPages.filter { group.contains($0) }
                    if !pages.isEmpty {
                        Section {
                            ForEach(pages) { page in
                                Label { Text(page.title) } icon: { IconTile(symbol: page.symbol, tint: page.tint, size: 20) }
                                    .tag(page)
                            }
                        }
                    }
                }
            }
            .searchable(text: $nav.search, placement: .sidebar, prompt: "Search")
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 260)
        } detail: {
            Group {
                switch nav.page {
                case .general: GeneralPage()
                case .awake: KeepAwakePage()
                case .autocomplete: AutocompletePage()
                case .calendar: CalendarPage()
                case .snippets: SnippetsPage()
                case .launcher: LauncherPage()
                case .fans: FansPage()
                case .displays: DisplaysPage()
                case .mic: MicPage()
                case .keyboard: KeyboardPage()
                }
            }
            .frame(minWidth: 460)
            .modifier(HideToolbarTitle(title: nav.page.title))
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { nav.goBack() } label: { Image(systemName: "chevron.left") }
                        .disabled(nav.back.isEmpty).help("Back")
                    Button { nav.goForward() } label: { Image(systemName: "chevron.right") }
                        .disabled(nav.forward.isEmpty).help("Forward")
                }
            }
        }
        .frame(minWidth: 700, minHeight: 540)
    }
}

/// Like System Settings, pages carry their own header card, so the toolbar shows no duplicate title.
struct HideToolbarTitle: ViewModifier {
    let title: String
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.navigationTitle(title).toolbar(removing: .title)
        } else {
            content.navigationTitle(title)
        }
    }
}

/// Centred header card at the top of each page (large icon, title, one-line description),
/// matching the page headers in System Settings.
struct PageHeader: View {
    let page: AppNav.Page
    let description: String

    var body: some View {
        Section {
            VStack(spacing: 8) {
                IconTile(symbol: page.symbol, tint: page.tint, size: 56)
                    .padding(.bottom, 2)
                Text(page.title).font(.title2.weight(.bold))
                Text(description)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 24)
        }
    }
}

/// App identity row at the top of the sidebar, like the Apple Account row in System Settings.
struct SidebarHeader: View {
    @EnvironmentObject var model: Model

    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: "fan.fill", tint: .blue, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("FanCurve").font(.body.weight(.semibold))
                Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 6)
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
