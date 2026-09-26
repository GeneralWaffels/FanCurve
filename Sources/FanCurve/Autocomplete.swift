import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

/// Cotypist-style AI autocomplete that runs entirely on this Mac.
///
/// It reads the text before the cursor through Accessibility, asks a local model (llama.cpp's
/// `llama-server` running a GGUF model such as Gemma 4 E2B) for the next few words, and shows them as
/// ghost text at the cursor. Tab accepts all of it, ⌥→ the next word, Esc dismisses. It personalises
/// suggestions by including similar snippets of your own past writing (stored only on this Mac).
@MainActor
final class Autocomplete: ObservableObject {
    enum EngineState: Equatable { case off, notInstalled, noModel, starting, ready, failed(String) }

    // MARK: settings
    @Published var enabled: Bool { didSet { save(); enabled ? start() : stop() } }
    @Published var paused = false { didSet { if paused { hide() } } }
    @Published var style: String { didSet { save() } }
    @Published var useScreenContext: Bool { didSet { save() } }
    @Published var learn: Bool { didSet { save() } }
    /// Periodically notes names and terms that keep appearing on screen (vocabulary only, never sentences).
    @Published var learnFromScreen: Bool { didSet { save(); updateScreenLearning() } }
    @Published var excludedApps: [String] { didSet { save() } }
    @Published var modelFile: String { didSet { save(); if enabled { restartServer() } } }

    // MARK: state
    @Published private(set) var engine: EngineState = .off
    @Published private(set) var accepted = 0
    @Published private(set) var historyCount = 0
    @Published private(set) var vocabulary: [String: Term] = [:]
    struct Term: Codable { var count: Int; var lastSeen: Date }
    private var screenTimer: Timer?
    @Published private(set) var lastLatency: Int?

    let folder: URL
    var modelsFolder: URL { folder.appendingPathComponent("Models") }
    private let defaults = UserDefaults.standard
    private var server: Process?
    private let port = 18765
    nonisolated(unsafe) private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var debounce: Task<Void, Never>?
    private var request: URLSessionDataTask?
    private var suggestion: (text: String, element: AXUIElement, value: String, caret: Int)?
    private let ghost = GhostText()
    private var history: [String] = []

    static let defaultExcluded = ["com.1password.1password", "com.bitwarden.desktop", "com.apple.Passwords",
                                  "com.apple.keychainaccess", "com.apple.Terminal", "com.googlecode.iterm2",
                                  "local.fancurve.app", "app.cotypist.Cotypist"]
    static let serverPaths = ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
    static let cotypistModels = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/app.cotypist.Cotypist/Models")

    init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FanCurve")
        enabled = defaults.bool(forKey: "acEnabled")
        style = defaults.string(forKey: "acStyle")
            ?? UserDefaults(suiteName: "app.cotypist.Cotypist")?.string(forKey: "CompletionManager_userPrompt")
            ?? "Write in a clear, friendly and professional voice."
        useScreenContext = defaults.object(forKey: "acScreen") as? Bool ?? true
        learn = defaults.object(forKey: "acLearn") as? Bool ?? true
        learnFromScreen = defaults.bool(forKey: "acLearnScreen")
        excludedApps = defaults.stringArray(forKey: "acExcluded") ?? Self.defaultExcluded
        modelFile = defaults.string(forKey: "acModel") ?? ""
        accepted = defaults.integer(forKey: "acAccepted")
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("Models"), withIntermediateDirectories: true)
        loadHistory()
        loadVocabulary()
        if modelFile.isEmpty { modelFile = availableModels.first ?? "" }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.server?.terminate() }
        }
        if enabled { start() }
    }

    private func save() {
        defaults.set(enabled, forKey: "acEnabled")
        defaults.set(style, forKey: "acStyle")
        defaults.set(useScreenContext, forKey: "acScreen")
        defaults.set(learn, forKey: "acLearn")
        defaults.set(learnFromScreen, forKey: "acLearnScreen")
        defaults.set(excludedApps, forKey: "acExcluded")
        defaults.set(modelFile, forKey: "acModel")
    }

    // MARK: models & engine

    var serverPath: String? { Self.serverPaths.first { FileManager.default.isExecutableFile(atPath: $0) } }
    var availableModels: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: modelsFolder.path)) ?? []).filter { $0.hasSuffix(".gguf") }.sorted()
    }
    var cotypistModel: URL? {
        ((try? FileManager.default.contentsOfDirectory(at: Self.cotypistModels, includingPropertiesForKeys: nil)) ?? [])
            .first { $0.pathExtension == "gguf" }
    }

    /// Copies Cotypist's model into FanCurve's folder. On APFS this is an instant clone that takes no extra
    /// space, and stays intact if Cotypist is uninstalled.
    func importCotypistModel() {
        guard let src = cotypistModel else { return }
        let dest = modelsFolder.appendingPathComponent(src.lastPathComponent)
        if !FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.copyItem(at: src, to: dest) }
        modelFile = src.lastPathComponent
    }

    func importCotypistStyle() {
        if let s = UserDefaults(suiteName: "app.cotypist.Cotypist")?.string(forKey: "CompletionManager_userPrompt") { style = s }
    }

    private func start() {
        guard !paused else { return }
        installTap()
        restartServer()
        updateScreenLearning()
    }

    private func stop() {
        screenTimer?.invalidate(); screenTimer = nil
        removeTap()
        hide()
        server?.terminate(); server = nil
        engine = .off
    }

    func restartServer() {
        server?.terminate(); server = nil
        guard let bin = serverPath else { engine = .notInstalled; return }
        let model = modelsFolder.appendingPathComponent(modelFile)
        guard !modelFile.isEmpty, FileManager.default.fileExists(atPath: model.path) else { engine = .noModel; return }
        engine = .starting
        Task {
            // Reuse a server that's still running from a previous launch.
            if await health() { engine = .ready; return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["-m", model.path, "--host", "127.0.0.1", "--port", String(port), "-ngl", "99",
                           "-c", "4096", "--no-webui", "--parallel", "1"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { engine = .failed(error.localizedDescription); return }
            server = p
            for _ in 0..<120 {
                try? await Task.sleep(for: .milliseconds(500))
                if await health() { engine = .ready; warmUp(); return }
                if !p.isRunning { engine = .failed("The model server stopped while loading."); return }
            }
            engine = .failed("The model took too long to load.")
        }
    }

    private func health() async -> Bool {
        guard let u = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var r = URLRequest(url: u); r.timeoutInterval = 1
        guard let (d, _) = try? await URLSession.shared.data(for: r) else { return false }
        return String(decoding: d, as: UTF8.self).contains("ok")
    }

    /// Loads the style prompt into the model's cache so the first real suggestion is fast.
    private func warmUp() { complete(prompt: buildPrompt(prefix: "Hello", app: "Notes", window: nil, screen: nil)) { _, _ in } }

    // MARK: key handling

    private func installTap() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            AccessibilityPermission.shared.request()
            AccessibilityPermission.shared.whenGranted { [weak self] in if self?.enabled == true { self?.installTap() } }
            return
        }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<Autocomplete>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let swallow = MainActor.assumeIsolated { me.handle(type, event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        tap = t
        tapSource = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil; tapSource = nil
    }

    /// Returns true to swallow the event (only Tab / ⌥→ / Esc while a suggestion is showing).
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard type == .keyDown else { hide(); return false }
        if event.getIntegerValueField(.eventSourceUserData) == Paster.marker { return false }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])

        if suggestion != nil {
            if code == kVK_Tab && flags.isEmpty { acceptAll(); return true }
            if code == kVK_RightArrow && flags == .maskAlternate { acceptWord(); return true }
            if code == kVK_Escape && flags.isEmpty { hide(); return true }
        }
        hide()
        guard enabled, !paused, engine == .ready else { return false }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { return false }
        switch code {
        case kVK_Return, kVK_Tab, kVK_Escape, kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow, kVK_Delete, kVK_ForwardDelete:
            if code == kVK_Return { DispatchQueue.main.async { self.rememberCurrentLine() } }
            return false
        default: break
        }
        scheduleSuggestion()
        return false
    }

    private func scheduleSuggestion() {
        debounce?.cancel()
        request?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            suggest()
        }
    }

    // MARK: context

    private struct Context {
        let element: AXUIElement
        let value: String
        let caret: Int
        let prefix: String
        let caretRect: CGRect
        let app: String
        let window: String?
        let screen: String?
    }

    private func focusedContext(includeScreen: Bool = true) -> Context? {
        guard !IsSecureEventInputEnabled(), let front = NSWorkspace.shared.frontmostApplication,
              !excludedApps.contains(front.bundleIdentifier ?? "") else { return nil }
        let system = AXUIElementCreateSystemWide()
        // A busy app must never stall typing: give up on slow Accessibility replies quickly.
        AXUIElementSetMessagingTimeout(system, 0.25)
        guard let el: AXUIElement = copy(system, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(el, 0.25)
        let role: String? = copy(el, kAXRoleAttribute), sub: String? = copy(el, kAXSubroleAttribute)
        guard sub != (kAXSecureTextFieldSubrole as String), role != "AXSecureTextField" else { return nil }
        guard let value: String = copy(el, kAXValueAttribute), !value.isEmpty,
              let rangeValue: AXValue = copy(el, kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range), range.length == 0 else { return nil }
        let ns = value as NSString
        let caret = min(range.location, ns.length)
        // Only complete at the end of a line (nothing but spaces after the cursor on this line).
        let after = ns.substring(from: caret)
        let restOfLine = after.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard restOfLine.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let prefix = ns.substring(to: caret)
        guard let last = prefix.last, !last.isNewline, prefix.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else { return nil }
        guard let rect = caretRect(el, caret) else { return nil }
        let windowEl: AXUIElement? = copy(AXUIElementCreateApplication(front.processIdentifier), kAXFocusedWindowAttribute)
        let title: String? = windowEl.flatMap { copy($0, kAXTitleAttribute) }
        let screen = useScreenContext && includeScreen ? windowEl.map { visibleText($0, excluding: value) } : nil
        return Context(element: el, value: value, caret: caret, prefix: String(prefix.suffix(1500)), caretRect: rect,
                       app: front.localizedName ?? "an app", window: title, screen: screen)
    }

    private func copy<T>(_ el: AXUIElement, _ attr: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? T
    }

    /// Screen rectangle of the insertion point (AX coordinates: top-left origin).
    private func caretRect(_ el: AXUIElement, _ caret: Int) -> CGRect? {
        func bounds(_ loc: Int, _ len: Int) -> CGRect? {
            var r = CFRange(location: loc, length: len)
            guard let arg = AXValueCreate(.cfRange, &r) else { return nil }
            var out: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, arg, &out) == .success,
                  let v = out, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
            var rect = CGRect.zero
            AXValueGetValue(v as! AXValue, .cgRect, &rect)
            return rect.height > 2 && rect.origin != .zero ? rect : nil
        }
        if let r = bounds(caret, 0) { return CGRect(x: r.minX, y: r.minY, width: 1, height: r.height) }
        if caret > 0, let r = bounds(caret - 1, 1) { return CGRect(x: r.maxX, y: r.minY, width: 1, height: r.height) }
        return nil
    }

    /// Visible text in the focused window (other than the field being typed in), for context.
    private func visibleText(_ window: AXUIElement, excluding own: String, limit: Int = 1200) -> String {
        var out: [String] = [], total = 0, visited = 0
        func walk(_ el: AXUIElement, _ depth: Int) {
            guard depth < 14, visited < 600, total < limit else { return }
            visited += 1
            let role: String? = copy(el, kAXRoleAttribute)
            if role == "AXStaticText" || role == "AXHeading", let v: String = copy(el, kAXValueAttribute),
               v.count > 2, v != own, !own.contains(v) {
                out.append(v); total += v.count
            }
            let kids: [AXUIElement] = copy(el, kAXChildrenAttribute) ?? []
            for k in kids { walk(k, depth + 1) }
        }
        walk(window, 0)
        return String(out.joined(separator: " · ").prefix(limit))
    }

    // MARK: suggestions

    private func suggest() {
        guard let ctx = focusedContext() else { return }
        let prompt = buildPrompt(prefix: ctx.prefix, app: ctx.app, window: ctx.window, screen: ctx.screen)
        let started = Date()
        complete(prompt: prompt) { [weak self] text, hitLimit in
            guard let self else { return }
            self.lastLatency = Int(Date().timeIntervalSince(started) * 1000)
            guard var t = text else { return }
            if hitLimit, let space = t.lastIndex(of: " ") { t = String(t[..<space]) }   // drop a cut-off last word
            if ctx.prefix.last?.isWhitespace == true { t = String(t.drop { $0 == " " }) }
            t = t.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .newlines)
            guard t.trimmingCharacters(in: .whitespaces).count >= 2 else { return }
            // Only show it if the user hasn't typed since we asked.
            guard let now: String = self.copy(ctx.element, kAXValueAttribute), now == ctx.value else { return }
            self.suggestion = (t, ctx.element, ctx.value, ctx.caret)
            self.ghost.show(t, at: ctx.caretRect)
        }
    }

    func buildPrompt(prefix: String, app: String, window: String?, screen: String?) -> String {
        var p = "Below is text being typed on a Mac in \(app)"
        if let w = window, !w.isEmpty { p += " (window: \"\(w.prefix(80))\")" }
        p += ". Continue it naturally with the next few words, in the writer's own voice.\n"
        p += "Writing style: \(style.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        if let s = screen, !s.isEmpty { p += "Also visible on screen: \(s)\n" }
        let terms = relevantTerms(for: prefix)
        if !terms.isEmpty { p += "Names and terms the writer often sees and uses: \(terms.joined(separator: ", "))\n" }
        let examples = similarHistory(to: prefix)
        if !examples.isEmpty { p += "Examples of how the writer phrases things:\n" + examples.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        return p + "---\n" + prefix
    }

    private func complete(prompt: String, done: @escaping (String?, Bool) -> Void) {
        request?.cancel()
        guard let url = URL(string: "http://127.0.0.1:\(port)/completion") else { return }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 4
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["prompt": prompt, "n_predict": 18, "temperature": 0.2, "top_k": 20, "top_p": 0.9,
                                   "stop": ["\n", "---"], "cache_prompt": true]
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let task = URLSession.shared.dataTask(with: r) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let text = json?["content"] as? String
            let limit = (json?["stop_type"] as? String) == "limit"
            DispatchQueue.main.async { done(text, limit) }
        }
        request = task
        task.resume()
    }

    // MARK: accepting

    private func acceptAll() {
        guard let s = suggestion else { return }
        insert(s.text, into: s.element)
        remember(lineEnding: s.value, with: s.text)
        count()
        hide()
    }

    /// Accepts up to and including the next word, then offers the rest.
    private func acceptWord() {
        guard let s = suggestion else { return }
        let chars = Array(s.text)
        var i = 0
        while i < chars.count, chars[i] == " " { i += 1 }
        while i < chars.count, chars[i] != " " { i += 1 }
        let word = String(chars[..<i]), rest = String(chars[i...])
        insert(word, into: s.element)
        hide()
        if !rest.trimmingCharacters(in: .whitespaces).isEmpty,
           let v: String = copy(s.element, kAXValueAttribute), let rect = caretRect(s.element, s.caret + (word as NSString).length) {
            suggestion = (rest, s.element, v, s.caret + (word as NSString).length)
            ghost.show(rest, at: rect)
        } else {
            count()
        }
    }

    private func count() { accepted += 1; defaults.set(accepted, forKey: "acAccepted") }

    /// Inserts at the cursor: Accessibility first (instant, native apps), typing as a fallback.
    private func insert(_ text: String, into el: AXUIElement) {
        let before: String? = copy(el, kAXValueAttribute)
        if AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success,
           let after: String = copy(el, kAXValueAttribute), after != before {
            return
        }
        Self.type(text)
    }

    /// Types text as keyboard events (works in browsers and Electron apps too), marked as ours.
    private static func type(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let utf16 = Array(text.utf16)
        var i = 0
        while i < utf16.count {
            let chunk = Array(utf16[i..<min(i + 16, utf16.count)])
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e.setIntegerValueField(.eventSourceUserData, value: Paster.marker)
                e.post(tap: .cghidEventTap)
            }
            i += 16
        }
    }

    func hide() {
        suggestion = nil
        ghost.hide()
    }

    // MARK: personalisation (local only)

    private var historyURL: URL { folder.appendingPathComponent("autocomplete-history.json") }

    private func loadHistory() {
        history = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: historyURL))) ?? []
        historyCount = history.count
    }

    private func saveHistory() {
        try? JSONEncoder().encode(history).write(to: historyURL, options: [.atomic, .completeFileProtection])
        historyCount = history.count
    }

    private func add(_ line: String) {
        let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard learn, l.count >= 16, l.count <= 400, !history.contains(l) else { return }
        history.append(l)
        if history.count > 3000 { history.removeFirst(history.count - 3000) }
        saveHistory()
    }

    /// When you press Return, the line you just finished is kept as an example of your writing.
    private func rememberCurrentLine() {
        guard learn, let ctx = focusedContext(includeScreen: false) else { return }
        if let line = ctx.prefix.split(separator: "\n").last { add(String(line)) }
    }

    private func remember(lineEnding value: String, with completion: String) {
        let line = value.split(separator: "\n").last.map(String.init) ?? ""
        add(line + completion)
    }

    func forgetHistory() { history = []; saveHistory() }

    // MARK: learning from the screen (vocabulary only)

    private var vocabURL: URL { folder.appendingPathComponent("autocomplete-vocabulary.json") }

    private func loadVocabulary() {
        vocabulary = (try? JSONDecoder().decode([String: Term].self, from: Data(contentsOf: vocabURL))) ?? [:]
    }

    private func saveVocabulary() {
        try? JSONEncoder().encode(vocabulary).write(to: vocabURL, options: [.atomic, .completeFileProtection])
    }

    func forgetVocabulary() { vocabulary = [:]; saveVocabulary() }

    /// Most-seen terms first (for Settings).
    var topTerms: [String] { vocabulary.sorted { ($0.value.count, $0.value.lastSeen) > ($1.value.count, $1.value.lastSeen) }.map(\.key) }

    private func updateScreenLearning() {
        screenTimer?.invalidate(); screenTimer = nil
        guard enabled, learnFromScreen else { return }
        screenTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.learnFromCurrentScreen() }
        }
        screenTimer?.tolerance = 30
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.learnFromCurrentScreen() }
    }

    /// Reads the visible text of the frontmost window and keeps recurring names and terms.
    func learnFromCurrentScreen() {
        guard enabled, learnFromScreen, !paused, !IsSecureEventInputEnabled(), !Self.screenLocked,
              let front = NSWorkspace.shared.frontmostApplication, !excludedApps.contains(front.bundleIdentifier ?? "") else { return }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let window: AXUIElement = copy(app, kAXFocusedWindowAttribute) else { return }
        let text = visibleText(window, excluding: "", limit: 6000)
        let now = Date()
        for term in Self.extractTerms(from: text) {
            vocabulary[term, default: Term(count: 0, lastSeen: now)].count += 1
            vocabulary[term]?.lastSeen = now
        }
        // Keep the 500 most useful terms; forget ones not seen for 60 days.
        let cutoff = now.addingTimeInterval(-60 * 86_400)
        vocabulary = vocabulary.filter { $0.value.lastSeen > cutoff }
        if vocabulary.count > 500 {
            vocabulary = Dictionary(uniqueKeysWithValues: vocabulary.sorted { $0.value.count > $1.value.count }.prefix(500).map { ($0.key, $0.value) })
        }
        saveVocabulary()
    }

    private static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Candidate vocabulary: capitalised names and phrases (not at the start of a sentence), CamelCase
    /// and words with digits (e.g. "FanCurve", "M5"). Common words are ignored.
    static func extractTerms(from text: String) -> Set<String> {
        let stop: Set<String> = ["The", "This", "That", "These", "Those", "There", "Then", "They", "What", "When", "Where", "Which",
                                 "Who", "Why", "How", "And", "But", "For", "With", "From", "Your", "You", "Our", "His", "Her",
                                 "Its", "Not", "All", "Any", "Can", "Will", "Just", "New", "Open", "Close", "Save", "Edit",
                                 "View", "File", "Help", "Window", "Settings", "Search", "Today", "Yesterday", "Tomorrow",
                                 "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "January",
                                 "February", "March", "April", "May", "June", "July", "August", "September", "October",
                                 "November", "December", "Yes", "No", "OK", "Cancel", "Done", "Reply", "Forward", "Delete",
                                 "Hi", "Hello", "Hey", "Dear", "Also", "Thanks", "Thank", "Please", "So", "If", "As", "In",
                                 "On", "At", "We", "It", "He", "She", "My", "Maybe", "Sure", "Great", "Good", "Best", "Regards"]
        var out = Set<String>()
        for sentence in text.components(separatedBy: CharacterSet(charactersIn: ".!?·\n")) {
            let words = sentence.split(whereSeparator: { $0.isWhitespace || ",;:()[]\"“”'".contains($0) }).map(String.init)
            var run: [String] = []
            func flush() {
                while let f = run.first, stop.contains(f) { run.removeFirst() }   // "Hi Thijs" → "Thijs"
                if run.count >= 2 { out.insert(run.prefix(3).joined(separator: " ")) }
                else if let w = run.first, w.count >= 4, !stop.contains(w) { out.insert(w) }
                run = []
            }
            for (i, w) in words.enumerated() {
                let clean = w.trimmingCharacters(in: .punctuationCharacters)
                guard clean.count >= 2, clean.count <= 30, clean.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { flush(); continue }
                let camel = clean.dropFirst().contains(where: \.isUppercase) && clean.contains(where: \.isLowercase)
                // Words mixing letters and digits (M5, iOS26), but not version numbers like v2026.
                let version = clean.first.map { "vV".contains($0) } == true && clean.dropFirst().allSatisfy { $0.isNumber || $0 == "." }
                let digits = clean.contains(where: \.isNumber) && clean.contains(where: \.isLetter) && !version
                // A capital at the start of a sentence only counts when the next word is capitalised too ("Spike Reply").
                let nextCapital = i + 1 < words.count && words[i + 1].first?.isUppercase == true
                let capital = clean.first!.isUppercase && (i > 0 || nextCapital) && (!stop.contains(clean) || !run.isEmpty)
                if camel || digits { flush(); out.insert(clean); continue }
                if capital { run.append(clean) } else { flush() }
            }
            flush()
        }
        return out
    }

    /// Up to 20 learned terms, preferring ones that match the word being typed, then the most frequent.
    private func relevantTerms(for prefix: String) -> [String] {
        guard learnFromScreen, !vocabulary.isEmpty else { return [] }
        let partial = prefix.split(whereSeparator: { $0.isWhitespace }).last.map { String($0).lowercased() } ?? ""
        let seen = vocabulary.filter { $0.value.count >= 2 }
        let matching = partial.count >= 2 ? seen.keys.filter { $0.lowercased().hasPrefix(partial) } : []
        let frequent = seen.sorted { $0.value.count > $1.value.count }.map(\.key)
        var picked: [String] = []
        for t in Array(matching) + frequent where !picked.contains(t) { picked.append(t); if picked.count == 20 { break } }
        return picked
    }

    /// Up to three past lines that share the most words with what's being typed.
    private func similarHistory(to prefix: String) -> [String] {
        guard learn, !history.isEmpty else { return [] }
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count >= 3 }.map(String.init))
        }
        let recent = words(String(prefix.suffix(160)))
        guard !recent.isEmpty else { return [] }
        return history.lazy.map { ($0, words($0).intersection(recent).count) }
            .filter { $0.1 >= 2 }
            .sorted { $0.1 > $1.1 }
            .prefix(3).map(\.0)
    }
}

// MARK: - Ghost text overlay

/// A click-through, non-activating panel that draws the suggestion in grey right after the cursor.
@MainActor
final class GhostText {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")

    func show(_ text: String, at caret: CGRect) {
        let p = panel ?? make()
        panel = p
        let size = min(max(caret.height * 0.78, 11), 30)
        let attr = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.75),
        ])
        attr.append(NSAttributedString(string: "  ⇥", attributes: [
            .font: NSFont.systemFont(ofSize: size * 0.7, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        label.attributedStringValue = attr
        label.sizeToFit()
        // AX uses a top-left origin on the primary display; AppKit uses bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = NSRect(x: caret.maxX + 1, y: primaryHeight - caret.maxY + (caret.height - label.frame.height) / 2,
                           width: label.frame.width + 4, height: label.frame.height)
        p.setFrame(frame, display: true)
        label.frame = NSRect(origin: .zero, size: frame.size)
        p.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        label.drawsBackground = false
        label.isBordered = false
        label.lineBreakMode = .byClipping
        p.contentView?.addSubview(label)
        return p
    }
}
