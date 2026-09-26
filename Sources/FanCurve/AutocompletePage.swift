import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
                    Text("\(ac.acceptKey.label) accepts a suggestion, ⌥→ just the next word, Esc dismisses it.")
                }
                if ac.enabled {
                    AccessibilityRow(feature: "read what you type and insert suggestions")
                    LabeledContent("Model") { engineStatus }
                    LabeledContent("Now") {
                        Text(ac.status).foregroundStyle(.secondary).multilineTextAlignment(.trailing).lineLimit(2)
                    }
                }
            } footer: {
                Footer("Works in any app. Where an app shows its cursor (Mail, Messages, Notes, Slack, Obsidian…) suggestions appear right after it; elsewhere, such as VS Code and some browsers, they appear in a small bubble. Password fields and apps you switch off are always skipped.")
            }

            Section {
                Picker("On battery", selection: $ac.batteryMode) {
                    ForEach(Autocomplete.BatteryMode.allCases) { m in
                        Text(m.label).tag(m).disabled(m == .apple && !Autocomplete.appleModelAvailable)
                    }
                }
                Picker("Suggestion length", selection: $ac.length) {
                    ForEach(Autocomplete.Length.allCases) { Text($0.label).tag($0) }
                }
                Picker("Accept with", selection: $ac.acceptKey) {
                    ForEach(Autocomplete.AcceptKey.allCases) { Text($0.label).tag($0) }
                }
                Toggle(isOn: $ac.emoji) {
                    Text("Emoji completion")
                    Text("Type a colon and a word, like :smile or :thumbsup, to get the emoji.")
                }
                Toggle(isOn: $ac.autocorrect) {
                    Text("Autocorrect")
                    Text("After a misspelt word, offers the correction; accept it like a suggestion.")
                }
                if let s = shortcuts.autocompletePause { ShortcutRow(title: "Pause or resume", setting: s) }
                if let s = shortcuts.autocompleteNow { ShortcutRow(title: "Suggest now", setting: s) }
                if let s = shortcuts.draftReply { ShortcutRow(title: "Draft a reply", setting: s) }
                LabeledContent("Words completed") {
                    Text("\(ac.wordsToday) today · \(ac.wordsTotal) in total").monospacedDigit().foregroundStyle(.secondary)
                }
                Toggle("Show words completed in the menu bar", isOn: $ac.menuBarWords)
            } header: {
                Text("Suggestions")
            } footer: {
                Footer("Suggestions stream in word by word. Press Esc straight after accepting one to undo it. Draft a reply writes an answer to the email or chat on screen, in your style. On battery, Apple's built-in model saves power and memory: FanCurve stops the larger model until you plug in again.")
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
                ForEach(ac.appStyles.keys.sorted { appName($0).localizedCaseInsensitiveCompare(appName($1)) == .orderedAscending }, id: \.self) { id in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            appIcon(id)
                            Text(appName(id))
                            Spacer()
                            Button { ac.appStyles[id] = nil } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.borderless).help("Use the main style in \(appName(id))")
                        }
                        TextField("Style in \(appName(id))", text: Binding(get: { ac.appStyles[id] ?? "" }, set: { ac.appStyles[id] = $0 }),
                                  prompt: Text("For example: casual, short, lowercase"), axis: .vertical)
                            .lineLimit(2...5)
                    }
                }
                let candidates = ac.seenApps.keys.filter { ac.appStyles[$0] == nil }
                    .sorted { appName($0).localizedCaseInsensitiveCompare(appName($1)) == .orderedAscending }
                Menu {
                    ForEach(candidates, id: \.self) { id in Button(appName(id)) { ac.appStyles[id] = "" } }
                } label: { Label("Add a Style for an App", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(candidates.isEmpty)
            } header: {
                Text("Styles per App")
            } footer: {
                Footer("Write differently in different places, for example casual in Messages and formal in Mail. Apps without their own style use the one above.")
            }

            Section {
                Toggle(isOn: $ac.useScreenContext) {
                    Text("Use what's on screen")
                    Text("Includes visible text from the window you're typing in, so replies fit the conversation.")
                }
                Toggle(isOn: $ac.learnFromScreen) {
                    Text("Learn from what's on screen")
                    Text("Every few minutes, notes names and terms that keep appearing in the window you're using (never whole sentences).")
                }
                if ac.learnFromScreen {
                    LabeledContent("Terms learned") {
                        HStack {
                            Text("\(ac.vocabulary.count)").monospacedDigit().foregroundStyle(.secondary)
                            Button("Learn Now") { ac.learnFromCurrentScreen() }
                            Button("Forget All") { ac.forgetVocabulary() }.disabled(ac.vocabulary.isEmpty)
                        }
                    }
                    if !ac.vocabulary.isEmpty {
                        Text(ac.topTerms.prefix(24).joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
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
                let apps = Array(Set(ac.excludedApps).union(ac.seenApps.keys)).sorted { appName($0).localizedCaseInsensitiveCompare(appName($1)) == .orderedAscending }
                ForEach(apps, id: \.self) { id in
                    Toggle(isOn: Binding(get: { !ac.excludedApps.contains(id) }, set: { ac.setApp(id, enabled: $0) })) {
                        HStack(spacing: 8) {
                            appIcon(id)
                            Text(appName(id))
                        }
                    }
                }
                Button { addApp() } label: { Label("Switch Off in Another App…", systemImage: "plus") }.buttonStyle(.borderless)
            } header: {
                Text("Apps")
            } footer: {
                Footer("Apps appear here once you've typed in them. Switch one off to never suggest there.")
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
        case .ready:
            StatusRow(text: ac.usingApple ? "Ready · Apple on-device model (on battery)" : "Ready · \(ac.modelFile)", color: .green).fixedSize()
        case .failed(let m): StatusRow(text: m, color: .red).fixedSize()
        }
    }

    @ViewBuilder private func appIcon(_ id: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
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
