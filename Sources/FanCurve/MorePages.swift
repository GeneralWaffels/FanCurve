import Carbon.HIToolbox
import EventKit
import SwiftUI
import UniformTypeIdentifiers

/// Global shortcuts for the launcher features, shared with Settings.
@MainActor
final class AppShortcuts: ObservableObject {
    let palette: ShortcutSetting
    lazy var spotlight = SpotlightTakeover(palette: palette)
    let joinMeeting: ShortcutSetting
    let schedule: ShortcutSetting
    let snippets: ShortcutSetting
    let quickNotes: ShortcutSetting
    var autocompletePause: ShortcutSetting?
    /// AeroSpace layout/width shortcuts, keyed by AeroSpace.shortcutActions id.
    var layouts: [String: ShortcutSetting] = [:]

    init(palette: ShortcutSetting, joinMeeting: ShortcutSetting, schedule: ShortcutSetting, snippets: ShortcutSetting,
         quickNotes: ShortcutSetting) {
        self.palette = palette; self.joinMeeting = joinMeeting; self.schedule = schedule; self.snippets = snippets
        self.quickNotes = quickNotes
    }

    /// Registers one global shortcut per AeroSpace layout action (⌃⌥Q / ⌃⌥W for the two presets).
    func setUpLayoutShortcuts(_ aero: AeroSpace) {
        let defaults: [String: Shortcut] = ["stack": .ctrlOpt(kVK_ANSI_Q, "Q"), "cols": .ctrlOpt(kVK_ANSI_W, "W")]
        for (i, action) in AeroSpace.shortcutActions.enumerated() {
            layouts[action.id] = ShortcutSetting(key: "aeroShortcut." + action.id, id: 20 + UInt32(i),
                                                 default: defaults[action.id]) { [weak aero] in aero?.run(action: action.id) }
        }
        aero.shortcutLabel = { [weak self] id in self?.layouts[id]?.shortcut?.display }
    }
}

// MARK: - Calendar

struct CalendarPage: View {
    @EnvironmentObject var cal: CalendarStore
    @EnvironmentObject var shortcuts: AppShortcuts

    var body: some View {
        Form {
            PageHeader(page: .calendar, description: "See what's next and join video calls in one click, from the menu bar or the keyboard.")

            if !cal.hasAccess {
                Section {
                    HStack(spacing: 12) {
                        IconTile(symbol: "calendar.badge.exclamationmark", tint: .red, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cal.access == .denied || cal.access == .restricted ? "Calendar access is off" : "Allow calendar access")
                            Text("FanCurve reads the calendars in the Calendar app, including Google and Outlook accounts.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if cal.access == .notDetermined {
                            Button("Allow…") { cal.requestAccess() }.buttonStyle(.borderedProminent)
                        } else {
                            Button("Open Privacy Settings…") { cal.openPrivacySettings() }
                        }
                    }
                    .padding(.vertical, 2)
                } footer: {
                    Footer("Don't see your Google calendar? Add your Google account in System Settings → Internet Accounts and turn on Calendars.")
                }
            } else {
                Section {
                    if cal.upcomingToday.isEmpty {
                        StatusRow(text: "No more meetings today.", color: .green)
                    }
                    ForEach(cal.upcomingToday.prefix(4)) { m in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 2).fill(m.color).frame(width: 4, height: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.title).lineLimit(1)
                                Text("\(m.timeRange) · \(m.calendar)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let link = m.link {
                                Button(m.isOngoing(at: cal.now) ? "Join" : cal.relative(m)) { cal.join(m) }
                                    .buttonStyle(.borderedProminent).tint(m.isOngoing(at: cal.now) ? .green : .accentColor)
                                    .help("Join on \(link.service)")
                            } else {
                                Text(cal.relative(m)).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                } header: {
                    Text("Up Next")
                }

                Section("Menu Bar") {
                    Picker("Show next meeting", selection: $cal.menuBarMode) {
                        ForEach(CalendarStore.MenuBarMode.allCases) { Text($0.label).tag($0) }
                    }
                }

                Section {
                    Toggle("Notify before meetings", isOn: $cal.notify)
                    if cal.notify {
                        Picker("Alert", selection: $cal.leadMinutes) {
                            Text("At start time").tag(0)
                            Text("1 minute before").tag(1)
                            Text("5 minutes before").tag(5)
                            Text("10 minutes before").tag(10)
                        }
                    }
                    Toggle("Mute microphone when joining", isOn: $cal.muteOnJoin)
                } header: {
                    Text("Joining")
                } footer: {
                    Footer("Notifications include a Join button for Zoom, Google Meet, Teams, Webex, FaceTime, Whereby, Jitsi and Slack huddles. Zoom and Teams open in their apps when installed.")
                }

                Section("Events") {
                    Toggle("Hide all-day events", isOn: $cal.hideAllDay)
                    Toggle("Hide declined events", isOn: $cal.hideDeclined)
                }

                Section("Calendars") {
                    ForEach(cal.calendars, id: \.calendarIdentifier) { c in
                        Toggle(isOn: Binding(get: { !cal.hiddenCalendars.contains(c.calendarIdentifier) },
                                             set: { on in
                                                 var h = cal.hiddenCalendars
                                                 if on { h.remove(c.calendarIdentifier) } else { h.insert(c.calendarIdentifier) }
                                                 cal.hiddenCalendars = h
                                             })) {
                            HStack(spacing: 8) {
                                Circle().fill(Color(nsColor: c.color)).frame(width: 10, height: 10)
                                Text(c.title)
                                Text(c.source.title).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Keyboard Shortcuts") {
                ShortcutRow(title: "Join next meeting", setting: shortcuts.joinMeeting)
                ShortcutRow(title: "Show schedule", setting: shortcuts.schedule)
            }
        }
        .formStyle(.grouped)
        .onAppear { cal.reload() }
    }
}

// MARK: - Snippets

struct SnippetsPage: View {
    @EnvironmentObject var store: SnippetStore
    @EnvironmentObject var shortcuts: AppShortcuts

    var body: some View {
        Form {
            PageHeader(page: .snippets, description: "Type a short keyword anywhere and it expands into text you use often.")

            Section {
                Toggle(isOn: $store.expandEnabled) {
                    Text("Expand keywords as you type")
                    Text("Works in any app. Password fields are always skipped.")
                }
                if store.expandEnabled { AccessibilityRow(feature: "expand snippets as you type") }
                ShortcutRow(title: "Search snippets", setting: shortcuts.snippets)
            }

            Section {
                ForEach(store.snippets) { s in
                    if store.editing == s.id, let b = store.binding(s.id) {
                        SnippetEditor(snippet: b, duplicate: store.duplicateKeywords.contains(s.keyword),
                                      done: { store.editing = nil }, delete: { store.delete(s.id) })
                    } else {
                        SnippetRow(snippet: s, duplicate: store.duplicateKeywords.contains(s.keyword))
                            .contentShape(Rectangle())
                            .onTapGesture { store.editing = s.id }
                    }
                }
                Button { _ = store.add() } label: { Label("Add Snippet", systemImage: "plus") }
                    .buttonStyle(.borderless)
            } header: {
                Text("Snippets")
            } footer: {
                Footer("Click a snippet to edit it. Placeholders: {clipboard} {date} {time} {datetime} {day} {uuid}, and {cursor} to place the cursor after expanding. Starting keywords with ; avoids accidental expansion.")
            }
        }
        .formStyle(.grouped)
        .onAppear { store.updateTap() }
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    let duplicate: Bool

    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: "text.quote", tint: .orange, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(snippet.name.isEmpty ? "Untitled" : snippet.name)
                Text(snippet.text.isEmpty ? "Empty" : snippet.text.replacingOccurrences(of: "\n", with: " ⏎ "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !snippet.keyword.isEmpty {
                Text(snippet.keyword).font(.callout.monospaced())
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(duplicate ? Color.red.opacity(0.2) : Color.primary.opacity(0.08)))
                    .help(duplicate ? "Another snippet uses this keyword" : "Type this to expand")
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
    }
}

private struct SnippetEditor: View {
    @Binding var snippet: Snippet
    let duplicate: Bool
    let done: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name", text: $snippet.name)
            TextField("Keyword", text: $snippet.keyword, prompt: Text("e.g. ;addr"))
                .font(.body.monospaced())
            if duplicate { StatusRow(text: "Another snippet already uses this keyword.", color: .red) }
            TextEditor(text: $snippet.text)
                .font(.body)
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            HStack {
                Button("Delete", role: .destructive, action: delete)
                Spacer()
                Button("Done", action: done).buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Autocomplete

struct AutocompletePage: View {
    @EnvironmentObject var ac: Autocomplete
    @EnvironmentObject var shortcuts: AppShortcuts

    var body: some View {
        Form {
            PageHeader(page: .autocomplete, description: "AI suggestions as you type, in any app. A local model predicts your next words; nothing leaves your Mac.")

            Section {
                Toggle(isOn: $ac.enabled) {
                    Text("Autocomplete")
                    Text("Press Tab to accept a suggestion, ⌥→ for just the next word, Esc to dismiss.")
                }
                if ac.enabled {
                    AccessibilityRow(feature: "read what you type and insert suggestions")
                    LabeledContent("Model") { engineStatus }
                }
                if let s = shortcuts.autocompletePause { ShortcutRow(title: "Pause or resume", setting: s) }
            } footer: {
                Footer("Suggestions appear in native apps such as Mail, Messages, Notes, Slack and Obsidian. Some browsers and Electron apps don't report the cursor position, so suggestions may not show there. Password fields and the apps below are always skipped.")
            }

            Section {
                if ac.availableModels.isEmpty {
                    StatusRow(text: "No model installed yet.", color: .orange)
                } else {
                    Picker("Model file", selection: $ac.modelFile) {
                        ForEach(ac.availableModels, id: \.self) { Text($0).tag($0) }
                    }
                }
                LabeledContent("Get a model") {
                    HStack {
                        if ac.cotypistModel != nil { Button("Import from Cotypist") { ac.importCotypistModel() } }
                        Button("Show Models Folder") { NSWorkspace.shared.activateFileViewerSelecting([ac.modelsFolder]) }
                    }
                }
                if ac.serverPath == nil {
                    StatusRow(text: "llama.cpp isn't installed. Install it with: brew install llama.cpp", color: .orange)
                }
            } header: {
                Text("Model")
            } footer: {
                Footer("Any GGUF model works; small ones are fastest. Gemma 4 E2B (about 3.5 GB) gives good suggestions in roughly 0.1 s on Apple Silicon. Put .gguf files in the Models folder.")
            }

            Section {
                TextEditor(text: $ac.style)
                    .font(.body)
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)
                if UserDefaults(suiteName: "app.cotypist.Cotypist")?.string(forKey: "CompletionManager_userPrompt") != nil {
                    Button("Import Style from Cotypist") { ac.importCotypistStyle() }.buttonStyle(.borderless)
                }
            } header: {
                Text("Your Writing Style")
            } footer: {
                Footer("Tell the model who you are and how you write, for example your name, language, spelling and tone.")
            }

            Section {
                Toggle(isOn: $ac.useScreenContext) {
                    Text("Use what's on screen")
                    Text("Includes visible text from the window you're typing in, so replies fit the conversation.")
                }
                Toggle(isOn: $ac.learn) {
                    Text("Learn from how I write")
                    Text("Keeps lines you finish and suggestions you accept, and uses similar ones as examples.")
                }
                LabeledContent("Remembered") {
                    HStack {
                        Text("\(ac.historyCount) lines").monospacedDigit().foregroundStyle(.secondary)
                        Button("Forget All") { ac.forgetHistory() }.disabled(ac.historyCount == 0)
                    }
                }
                LabeledContent("Accepted suggestions") {
                    Text("\(ac.accepted)" + (ac.lastLatency.map { " · last \($0) ms" } ?? "")).monospacedDigit().foregroundStyle(.secondary)
                }
            } header: {
                Text("Personalisation")
            } footer: {
                Footer("Everything stays on this Mac, in ~/Library/Application Support/FanCurve. Nothing is uploaded, and there's no training-data collection.")
            }

            Section {
                ForEach(ac.excludedApps, id: \.self) { id in
                    HStack {
                        Text(appName(id))
                        Spacer()
                        Button { ac.excludedApps.removeAll { $0 == id } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.borderless)
                    }
                }
                Button { addApp() } label: { Label("Add App…", systemImage: "plus") }.buttonStyle(.borderless)
            } header: {
                Text("Never Suggest In")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var engineStatus: some View {
        switch ac.engine {
        case .off: StatusRow(text: "Off", color: .secondary).fixedSize()
        case .notInstalled: StatusRow(text: "llama.cpp not installed", color: .orange).fixedSize()
        case .noModel: StatusRow(text: "No model selected", color: .orange).fixedSize()
        case .starting: StatusRow(text: "Loading \(ac.modelFile)…", color: .orange).fixedSize()
        case .ready: StatusRow(text: "Ready · \(ac.modelFile)", color: .green).fixedSize()
        case .failed(let m): StatusRow(text: m, color: .red).fixedSize()
        }
    }

    private func appName(_ id: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path) } ?? id
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !ac.excludedApps.contains(id) { ac.excludedApps.append(id) }
        }
    }
}

// MARK: - Quick notes settings

struct QuickNotesSection: View {
    @EnvironmentObject var shortcuts: AppShortcuts
    @EnvironmentObject var notes: QuickNotes

    var body: some View {
        Section {
            ShortcutRow(title: "Open Quick Notes", setting: shortcuts.quickNotes)
            Toggle("Keep the notes window on top", isOn: $notes.alwaysOnTop)
            LabeledContent("Notes") {
                HStack {
                    Text("\(notes.notes.count)").monospacedDigit().foregroundStyle(.secondary)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([notes.folder]) }
                    Button("Open") { notes.showWindow() }
                }
            }
        } header: {
            Text("Quick Notes")
        } footer: {
            Footer("A floating scratchpad like Raycast Notes. Type in the palette and choose New Quick Note, or press the shortcut. Notes save as you type; move one into Obsidian with the ↑ button.")
        }
    }
}

// MARK: - Command palette

struct LauncherPage: View {
    @EnvironmentObject var shortcuts: AppShortcuts
    @EnvironmentObject var aero: AeroSpace
    @EnvironmentObject var obsidian: Obsidian

    var body: some View {
        Form {
            PageHeader(page: .launcher, description: "One shortcut to launch your favourite apps, run FanCurve commands, join meetings, paste snippets and do quick maths.")

            Section {
                SpotlightTakeoverRow(takeover: shortcuts.spotlight)
                ShortcutRow(title: "Open command palette", setting: shortcuts.palette)
                LabeledContent("Try it") {
                    Button("Open Command Palette") { NotificationCenter.default.post(name: AppDelegate.openPalette, object: nil) }
                }
            } footer: {
                Footer("⌥Space is the default, like Raycast. Turn on ⌘Space to replace Spotlight instead. If you also use Raycast or Alfred, give one of them a different shortcut.")
            }

            FavouritesSection()

            QuickNotesSection()

            Section("What You Can Search") {
                feature("star.fill", .yellow, "Favourites", "Pinned apps first; ⌘1–9 launches them, ⌘F pins the selected app.")
                feature("square.grid.2x2.fill", .blue, "Applications", "Open any app by typing part of its name.")
                feature("fan.fill", .blue, "Fans", "Turn the curve on or off and switch profiles.")
                feature("video.fill", .red, "Meetings", "Join the next call or open your schedule.")
                feature("text.quote", .orange, "Snippets", "Search and paste saved text.")
                feature("note.text", .yellow, "Quick Notes", "Jot something down instantly; it saves as you type.")
                feature("equal", .orange, "Calculator", "Type 23*1.21 and press Return to copy the answer.")
                feature("mic.fill", .red, "Microphone & Displays", "Mute, set external brightness, clean the keyboard.")
                feature("moon.fill", .indigo, "System", "Lock, sleep, screen saver and dark mode.")
                if obsidian.installed {
                    feature("books.vertical.fill", .purple, "Obsidian", "Search notes, capture to your daily note, create notes.")
                }
                if aero.installed {
                    feature("rectangle.3.group", .teal, "AeroSpace", "Toggle tiling, layouts, workspaces, windows and AeroSpace settings.")
                }
            }

            if obsidian.installed { ObsidianSection() }

            if aero.installed {
                Section {
                    LabeledContent("Status") {
                        StatusRow(text: aero.running ? "Running\(aero.version.map { " · \($0)" } ?? "")" : "Not running",
                                  color: aero.running ? .green : .secondary)
                            .fixedSize()
                    }
                    LabeledContent("Gap size for \"Turn On Window Gaps\"") {
                        Stepper("\(aero.gapSize) pt", value: $aero.gapSize, in: 2...40, step: 2)
                    }
                    LabeledContent("Config file") {
                        Button("Open \(aero.configURL.lastPathComponent)") { aero.openConfig() }
                    }
                    if let e = aero.lastError { StatusRow(text: e, color: .red) }
                } header: {
                    Text("AeroSpace")
                } footer: {
                    Footer("Type \"aerospace\" or a workspace name in the palette. Settings commands edit \(aero.configURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) and reload AeroSpace; a backup is saved next to it (.fancurve-backup) before the first change.")
                }
                .onAppear { aero.refresh() }

                Section {
                    ForEach(AeroSpace.shortcutActions, id: \.id) { action in
                        if let setting = shortcuts.layouts[action.id] { ShortcutRow(title: action.title, setting: setting) }
                    }
                } header: {
                    Text("AeroSpace Layout Shortcuts")
                } footer: {
                    Footer("Work from any app. The layouts give the focused window the left half. ⌃⌥ combinations don't clash with AeroSpace's ⌥ and ⌥⇧ bindings.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func feature(_ symbol: String, _ tint: Color, _ title: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, tint: tint, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
