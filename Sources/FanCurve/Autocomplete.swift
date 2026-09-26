import AppKit
import ApplicationServices
import Carbon.HIToolbox
import IOKit.ps
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

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

    enum Length: String, CaseIterable, Identifiable {
        case short, medium, long
        var id: String { rawValue }
        var tokens: Int { self == .short ? 8 : self == .medium ? 18 : 40 }
        var label: String { self == .short ? "A few words" : self == .medium ? "Part of a sentence" : "Up to a full sentence" }
    }
    enum AcceptKey: String, CaseIterable, Identifiable {
        case tab, rightArrow
        var id: String { rawValue }
        var label: String { self == .tab ? "Tab" : "→ Right Arrow" }
    }
    enum BatteryMode: String, CaseIterable, Identifiable {
        case apple, gemma, pause
        var id: String { rawValue }
        var label: String { self == .apple ? "Apple's on-device model" : self == .gemma ? "Keep using the selected model" : "Pause autocomplete" }
    }
    /// What to use while running on battery: Apple's built-in model is far lighter on power than llama.cpp.
    @Published var batteryMode: BatteryMode { didSet { save(); updatePower() } }
    @Published private(set) var onBattery = false
    /// True while suggestions come from Apple's on-device model instead of llama.cpp.
    @Published private(set) var usingApple = false
    private var powerSource: CFRunLoopSource?
    private var appleTask: Task<Void, Never>?

    @Published var length: Length { didSet { save() } }
    @Published var acceptKey: AcceptKey { didSet { save() } }
    @Published var emoji: Bool { didSet { save() } }
    @Published var autocorrect: Bool { didSet { save() } }

    // MARK: state
    @Published private(set) var engine: EngineState = .off
    @Published private(set) var accepted = 0
    @Published private(set) var historyCount = 0
    @Published private(set) var vocabulary: [String: Term] = [:]
    struct Term: Codable { var count: Int; var lastSeen: Date }
    private var screenTimer: Timer?
    @Published private(set) var lastLatency: Int?
    /// Plain-English description of what autocomplete just did (shown in Settings).
    @Published private(set) var status = "Off"
    @Published private(set) var wordsToday = 0
    @Published private(set) var wordsTotal = 0
    /// Apps it has run in (bundle id → name), for the per-app switches in Settings.
    @Published private(set) var seenApps: [String: String] = [:]

    let folder: URL
    var modelsFolder: URL { folder.appendingPathComponent("Models") }
    private let defaults = UserDefaults.standard
    private var server: Process?
    private let port = 18765
    nonisolated(unsafe) private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var debounce: Task<Void, Never>?
    private var request: URLSessionDataTask?
    private var suggestion: Suggestion?
    private var buffer = ""
    private var bufferPID: pid_t = 0
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
        length = Length(rawValue: defaults.string(forKey: "acLength") ?? "") ?? .medium
        batteryMode = BatteryMode(rawValue: defaults.string(forKey: "acBattery") ?? "") ?? (Self.appleModelAvailable ? .apple : .gemma)
        acceptKey = AcceptKey(rawValue: defaults.string(forKey: "acAcceptKey") ?? "") ?? .tab
        emoji = defaults.object(forKey: "acEmoji") as? Bool ?? true
        autocorrect = defaults.object(forKey: "acAutocorrect") as? Bool ?? true
        wordsTotal = defaults.integer(forKey: "acWordsTotal")
        wordsToday = defaults.string(forKey: "acWordsDay") == Self.dayKey() ? defaults.integer(forKey: "acWordsToday") : 0
        seenApps = defaults.dictionary(forKey: "acSeenApps") as? [String: String] ?? [:]
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("Models"), withIntermediateDirectories: true)
        loadHistory()
        loadVocabulary()
        if modelFile.isEmpty { modelFile = availableModels.first ?? "" }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.server?.terminate() }
        }
        watchPower()
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
        defaults.set(length.rawValue, forKey: "acLength")
        defaults.set(batteryMode.rawValue, forKey: "acBattery")
        defaults.set(acceptKey.rawValue, forKey: "acAcceptKey")
        defaults.set(emoji, forKey: "acEmoji")
        defaults.set(autocorrect, forKey: "acAutocorrect")
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
        onBattery = Self.isOnBattery
        applyEngineForPower()
        updateScreenLearning()
    }

    private func stop() {
        screenTimer?.invalidate(); screenTimer = nil
        removeTap()
        hide()
        stopServer()
        usingApple = false
        engine = .off
        setStatus("Off")
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

    // MARK: power (battery → Apple's model)

    static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        return (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPSBatteryPowerValue
    }

    static var appleModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    private func watchPower() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<Autocomplete>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.updatePower() }
        }, ctx)?.takeRetainedValue() else { return }
        powerSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    }

    private func updatePower() {
        let battery = Self.isOnBattery
        if battery != onBattery { onBattery = battery }
        if enabled && !paused { applyEngineForPower() }
    }

    /// On battery: Apple's model (llama.cpp stopped), pause, or keep going. On power: the selected model.
    private func applyEngineForPower() {
        if onBattery && batteryMode == .apple && Self.appleModelAvailable {
            if !usingApple {
                usingApple = true
                stopServer()
                engine = .ready
                setStatus("On battery: using Apple's on-device model")
            }
        } else if onBattery && batteryMode == .pause {
            usingApple = false
            stopServer()
            engine = .off
            setStatus("Paused while on battery")
        } else if usingApple || engine != .ready || !onBattery {
            usingApple = false
            if engine != .ready || server == nil { restartServer() }
        }
    }

    /// Stops llama-server, including one left running by a previous launch, to save power and memory.
    private func stopServer() {
        server?.terminate(); server = nil
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "llama-server.*--port \(port)"]
        try? p.run()
    }

    /// Loads the style prompt into the model's cache so the first real suggestion is fast.
    private func warmUp() { complete(prompt: buildPrompt(prefix: "Hello", app: "Notes", window: nil, screen: nil), tokens: 4) { _, _ in } }

    // MARK: key handling

    private func installTap() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            setStatus("Waiting for Accessibility access")
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
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            setStatus("Couldn't watch the keyboard: check Accessibility access")
            return
        }
        tap = t
        tapSource = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        setStatus("Ready: start typing in any app")
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil; tapSource = nil
    }

    /// Returns true to swallow the event (only the accept / dismiss keys while a suggestion is showing).
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard type == .keyDown else { buffer = ""; hide(); return false }   // a click moves the caret
        if event.getIntegerValueField(.eventSourceUserData) == Paster.marker { return false }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])

        if let s = suggestion {
            let full = acceptKey == .tab ? (code == kVK_Tab && flags.isEmpty) : (code == kVK_RightArrow && flags.isEmpty)
            if full { accept(s, wordOnly: false); return true }
            if s.kind == .completion && code == kVK_RightArrow && flags == .maskAlternate { accept(s, wordOnly: true); return true }
            if code == kVK_Escape && flags.isEmpty { hide(); setStatus("Dismissed"); return true }
        }
        hide()
        track(event, code: code, flags: flags)
        guard enabled, !paused, engine == .ready else { return false }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { return false }
        switch code {
        case kVK_Return:
            DispatchQueue.main.async { self.rememberCurrentLine() }
            return false
        case kVK_Tab, kVK_Escape, kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow, kVK_Delete, kVK_ForwardDelete,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            return false
        default: break
        }
        scheduleSuggestion(force: false)
        return false
    }

    /// Keeps our own record of what's typed in the frontmost app, for apps (VS Code, some browsers,
    /// Electron) that don't expose their text through Accessibility.
    private func track(_ event: CGEvent, code: Int, flags: CGEventFlags) {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        if pid != bufferPID { buffer = ""; bufferPID = pid }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { buffer = ""; return }   // paste, undo…
        switch code {
        case kVK_Delete: if !buffer.isEmpty { buffer.removeLast() }
        case kVK_Return: buffer += "\n"
        case kVK_Tab, kVK_Escape, kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow, kVK_Home, kVK_End,
             kVK_PageUp, kVK_PageDown, kVK_ForwardDelete:
            buffer = ""
        default:
            if let c = NSEvent(cgEvent: event)?.characters, !c.isEmpty,
               c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) { buffer += c }
        }
        if buffer.count > 1500 { buffer.removeFirst(buffer.count - 1500) }
    }

    private func scheduleSuggestion(force: Bool) {
        debounce?.cancel()
        request?.cancel()
        // Emoji codes are local and instant; model suggestions wait for a short pause in typing.
        let quick = emoji && (buffer.last.map { $0.isLetter } ?? false) && buffer.split(separator: " ").last?.hasPrefix(":") == true
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(quick ? 60 : 220))
            guard !Task.isCancelled else { return }
            suggest(force: force)
        }
    }

    /// "Suggest now" shortcut: asks for a suggestion right away, even in the middle of a line.
    func suggestNow() {
        guard enabled, !paused, engine == .ready else { NSSound.beep(); return }
        hide()
        debounce?.cancel()
        suggest(force: true)
    }

    // MARK: context

    private struct Context {
        let element: AXUIElement?
        let value: String?        // the field's text, when the app exposes it
        let caret: Int
        let prefix: String
        let anchor: CGRect        // AX coordinates (top-left origin)
        let placement: GhostText.Placement
        let fromBuffer: Bool
        let app: String
        let window: String?
        let screen: String?
    }

    private func focusedContext(includeScreen: Bool = true, force: Bool = false) -> Context? {
        guard !IsSecureEventInputEnabled() else { setStatus("Paused: you're in a password field"); return nil }
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundle = front.bundleIdentifier ?? "", name = front.localizedName ?? "this app"
        guard !excludedApps.contains(bundle) else { setStatus("Off in \(name)"); return nil }
        noteApp(bundle, name)

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)   // a busy app must never stall typing
        let el: AXUIElement? = copy(system, kAXFocusedUIElementAttribute)
        if let el {
            AXUIElementSetMessagingTimeout(el, 0.25)
            let role: String? = copy(el, kAXRoleAttribute), sub: String? = copy(el, kAXSubroleAttribute)
            if sub == (kAXSecureTextFieldSubrole as String) || role == "AXSecureTextField" { return nil }
        }

        // 1. The app's own text and cursor (best).
        var prefix: String?, value: String?, caret = 0, fromBuffer = false
        if let el, let v: String = copy(el, kAXValueAttribute), !v.isEmpty,
           let rv: AXValue = copy(el, kAXSelectedTextRangeAttribute) {
            var range = CFRange()
            if AXValueGetValue(rv, .cfRange, &range), range.length == 0 {
                let ns = v as NSString
                caret = min(max(range.location, 0), ns.length)
                if !force, caret < ns.length,
                   ns.substring(with: NSRange(location: caret, length: 1)).rangeOfCharacter(from: .alphanumerics) != nil {
                    setStatus("Waiting until you're at the end of a word")
                    return nil
                }
                prefix = ns.substring(to: caret)
                value = v
            }
        }
        // 2. Our typing buffer, for apps that don't share their text.
        if prefix == nil, !buffer.isEmpty, bufferPID == front.processIdentifier {
            prefix = buffer
            fromBuffer = true
        }
        guard let p = prefix, p.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
            setStatus("Type a few words in \(name) to get suggestions")
            return nil
        }
        if !force, p.last?.isNewline == true { return nil }

        // Where to show it: at the cursor, under a small field, or as a bubble at the bottom of the window.
        let appEl = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.25)
        let windowEl: AXUIElement? = copy(appEl, kAXFocusedWindowAttribute)
        var anchor: CGRect?, placement = GhostText.Placement.inline
        if let el, value != nil, let r = caretRect(el, caret) {
            anchor = r
        } else if let el, let f = frame(el), f.height > 0, f.height < 120 {
            anchor = CGRect(x: f.minX, y: f.maxY + 4, width: 1, height: 18); placement = .below
        } else if let w = windowEl, let f = frame(w) {
            anchor = CGRect(x: f.midX, y: f.maxY - 64, width: 1, height: 18); placement = .centred
        }
        guard let a = anchor else { setStatus("\(name) doesn't say where its text is, so there's nowhere to show suggestions"); return nil }

        let title: String? = windowEl.flatMap { copy($0, kAXTitleAttribute) }
        let screen = useScreenContext && includeScreen ? windowEl.map { visibleText($0, excluding: value ?? p) } : nil
        return Context(element: el, value: value, caret: caret, prefix: String(p.suffix(1500)), anchor: a, placement: placement,
                       fromBuffer: fromBuffer, app: name, window: title, screen: screen)
    }

    private func copy<T>(_ el: AXUIElement, _ attr: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? T
    }

    private func frame(_ el: AXUIElement) -> CGRect? {
        guard let pv: AXValue = copy(el, kAXPositionAttribute), let sv: AXValue = copy(el, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv, .cgPoint, &p); AXValueGetValue(sv, .cgSize, &s)
        return s.width > 0 ? CGRect(origin: p, size: s) : nil
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

    private struct Suggestion {
        enum Kind { case completion, emoji, correction }
        let kind: Kind
        let insert: String      // text to type
        let display: String     // what the ghost shows
        let replace: Int        // characters before the cursor to replace first (emoji code, misspelt word)
        let ctx: Context
    }

    private func suggest(force: Bool) {
        guard let ctx = focusedContext(force: force) else { return }
        if emoji, let s = emojiSuggestion(ctx) { present(s); return }
        if autocorrect, let s = correctionSuggestion(ctx) { present(s); return }

        let prompt = buildPrompt(prefix: ctx.prefix, app: ctx.app, window: ctx.window, screen: ctx.screen)
        let started = Date()
        complete(prompt: prompt, tokens: length.tokens) { [weak self] text, hitLimit in
            guard let self else { return }
            self.lastLatency = Int(Date().timeIntervalSince(started) * 1000)
            guard var t = text else { self.setStatus("The model didn't answer: is it still loading?"); return }
            if hitLimit, let space = t.lastIndex(of: " ") { t = String(t[..<space]) }   // drop a cut-off last word
            if ctx.prefix.last?.isWhitespace == true { t = String(t.drop { $0 == " " }) }
            t = t.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .newlines)
            guard t.trimmingCharacters(in: .whitespaces).count >= 2 else { self.setStatus("No suggestion for that (\(self.lastLatency ?? 0) ms)"); return }
            guard self.stillCurrent(ctx) else { return }   // the user kept typing
            self.present(Suggestion(kind: .completion, insert: t, display: t, replace: 0, ctx: ctx))
        }
    }

    private func stillCurrent(_ ctx: Context) -> Bool {
        if ctx.fromBuffer { return buffer.hasSuffix(ctx.prefix.suffix(40)) }
        guard let el = ctx.element, let now: String = copy(el, kAXValueAttribute) else { return false }
        return now == ctx.value
    }

    private func present(_ s: Suggestion) {
        suggestion = s
        let hint: String
        switch s.kind {
        case .completion: hint = acceptKey == .tab ? "⇥" : "→"
        case .emoji: hint = acceptKey == .tab ? "⇥ emoji" : "→ emoji"
        case .correction: hint = acceptKey == .tab ? "⇥ fix" : "→ fix"
        }
        ghost.show(s.display, hint: hint, at: s.ctx.anchor, placement: s.ctx.placement)
        let how = s.ctx.fromBuffer ? " (from your typing)" : ""
        setStatus("Suggested in \(s.ctx.app)\(how)" + (s.kind == .completion ? " · \(lastLatency ?? 0) ms" : ""))
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

    private func complete(prompt: String, tokens: Int, done: @escaping (String?, Bool) -> Void) {
        request?.cancel()
        if usingApple { appleComplete(prompt: prompt, tokens: tokens, done: done); return }
        guard let url = URL(string: "http://127.0.0.1:\(port)/completion") else { return }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 4
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["prompt": prompt, "n_predict": tokens, "temperature": 0.2, "top_k": 20, "top_p": 0.9,
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

    /// Apple's on-device model is chat-tuned, so it's asked to fill a blank (▮) rather than to "continue",
    /// which stops it replying to the text instead of completing it.
    private func appleComplete(prompt: String, tokens: Int, done: @escaping (String?, Bool) -> Void) {
        appleTask?.cancel()
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { done(nil, false); return }
        let parts = prompt.components(separatedBy: "---\n")
        let context = parts.first ?? "", text = parts.dropFirst().joined(separator: "---\n")
        let instructions = """
        You complete unfinished text, like a phone keyboard's predictive text. The user's text is cut off at ▮. \
        Output only the words that belong at ▮ to continue it: 1 to \(max(tokens / 2, 4)) words, lowercase unless a name \
        or a new sentence, no quotes, no reply, nothing the text already says.
        \(context)
        """
        appleTask = Task {
            let session = LanguageModelSession(instructions: instructions)
            let r = try? await session.respond(to: "Text: \(text.suffix(1200))▮",
                                               options: GenerationOptions(temperature: 0.1, maximumResponseTokens: tokens))
            guard !Task.isCancelled else { return }
            var t = r?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”▮"))
            // Continue with a space unless the text ends in one (or the model returned punctuation).
            if let first = t.first, !first.isPunctuation, text.last?.isWhitespace == false { t = " " + t }
            done(t.isEmpty ? nil : t, false)
        }
        #else
        done(nil, false)
        #endif
    }

    // MARK: emoji & autocorrect

    /// `:smile`, `:thumbs`, `:fire` → the best-matching emoji (Cotypist-style emoji completion).
    private func emojiSuggestion(_ ctx: Context) -> Suggestion? {
        let p = ctx.prefix
        guard let colon = p.lastIndex(of: ":") else { return nil }
        let code = p[p.index(after: colon)...]
        guard code.count >= 2, code.count <= 24, code.allSatisfy({ $0.isLetter || $0 == "_" }) else { return nil }
        if colon > p.startIndex, !p[p.index(before: colon)].isWhitespace { return nil }   // "10:30", "http:"
        guard let (e, name) = Self.emoji(for: code.lowercased()) else { return nil }
        return Suggestion(kind: .emoji, insert: e, display: "\(e)  \(name)", replace: code.count + 1, ctx: ctx)
    }

    private static let emojiAliases: [String: String] = [
        "smile": "😄", "grin": "😁", "laugh": "😂", "lol": "😂", "joy": "😂", "rofl": "🤣", "wink": "😉", "blush": "😊",
        "heart": "❤️", "love": "😍", "kiss": "😘", "cool": "😎", "think": "🤔", "thinking": "🤔", "shrug": "🤷",
        "cry": "😢", "sob": "😭", "angry": "😠", "sad": "😞", "sweat": "😅", "scream": "😱", "sleep": "😴",
        "thumbsup": "👍", "thumbs": "👍", "yes": "👍", "thumbsdown": "👎", "clap": "👏", "wave": "👋", "pray": "🙏",
        "thanks": "🙏", "ok": "👌", "muscle": "💪", "eyes": "👀", "fire": "🔥", "tada": "🎉", "party": "🥳",
        "rocket": "🚀", "star": "⭐", "sparkles": "✨", "check": "✅", "done": "✅", "x": "❌", "warning": "⚠️",
        "coffee": "☕", "beer": "🍺", "pizza": "🍕", "cake": "🎂", "gift": "🎁", "sun": "☀️", "rain": "🌧️",
        "hundred": "💯", "100": "💯", "bulb": "💡", "idea": "💡", "calendar": "📅", "phone": "📱", "laptop": "💻",
    ]

    private static let emojiIndex: [(emoji: String, name: String)] = {
        var out: [(String, String)] = []
        let ranges: [ClosedRange<UInt32>] = [0x1F300...0x1F5FF, 0x1F600...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1F9FF,
                                             0x1FA70...0x1FAFF, 0x2600...0x26FF, 0x2700...0x27BF]
        for r in ranges {
            for v in r {
                guard let s = Unicode.Scalar(v), s.properties.isEmojiPresentation, let n = s.properties.name else { continue }
                out.append((String(s), n.lowercased()))
            }
        }
        return out
    }()

    private static func emoji(for code: String) -> (String, String)? {
        if let e = emojiAliases[code] { return (e, ":" + code) }
        let q = code.replacingOccurrences(of: "_", with: " ")
        let ranked = emojiIndex.compactMap { e -> (String, String, Int)? in
            let words = e.name.split(separator: " ")
            if e.name == q { return (e.emoji, e.name, 0) }
            if words.contains(where: { $0 == q }) { return (e.emoji, e.name, 1) }
            if words.contains(where: { $0.hasPrefix(q) }) { return (e.emoji, e.name, 2) }
            return nil
        }
        guard let best = ranked.min(by: { ($0.2, $0.1.count) < ($1.2, $1.1.count) }) else { return nil }
        return (best.0, best.1)
    }

    /// After a space, offers a fix for a misspelt word (Cotypist-style autocorrect).
    private func correctionSuggestion(_ ctx: Context) -> Suggestion? {
        let p = ctx.prefix
        guard p.last == " " else { return nil }
        let trimmed = p.dropLast()
        guard let r = trimmed.range(of: "[A-Za-z']+$", options: .regularExpression) else { return nil }
        let word = String(trimmed[r])
        guard word.count >= 3, word.first?.isLowercase == true,
              !vocabulary.keys.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) else { return nil }
        let checker = NSSpellChecker.shared
        let lang = style.localizedCaseInsensitiveContains("british") ? "en_GB" : "en"
        let miss = checker.checkSpelling(of: word, startingAt: 0, language: lang, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        guard miss.location != NSNotFound else { return nil }
        let range = NSRange(location: 0, length: (word as NSString).length)
        var candidates = checker.guesses(forWordRange: range, in: word, language: lang, inSpellDocumentWithTag: 0) ?? []
        if let c = checker.correction(forWordRange: range, in: word, language: lang, inSpellDocumentWithTag: 0) { candidates.insert(c, at: 0) }
        // Prefer guesses that keep the first letter, then the fewest edits ("adress" → "address", not "dress").
        let ranked = candidates.enumerated().sorted {
            let a = ($0.element.first?.lowercased() == word.first?.lowercased() ? 0 : 1, Self.editDistance($0.element.lowercased(), word.lowercased()), $0.offset)
            let b = ($1.element.first?.lowercased() == word.first?.lowercased() ? 0 : 1, Self.editDistance($1.element.lowercased(), word.lowercased()), $1.offset)
            return a < b
        }
        guard let fix = ranked.first?.element, fix.caseInsensitiveCompare(word) != .orderedSame,
              Self.editDistance(fix.lowercased(), word.lowercased()) <= 2 else { return nil }
        return Suggestion(kind: .correction, insert: fix + " ", display: "\(word) → \(fix)", replace: word.count + 1, ctx: ctx)
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    // MARK: accepting

    private func accept(_ s: Suggestion, wordOnly: Bool) {
        var text = s.insert, rest = ""
        if wordOnly {
            let chars = Array(s.insert)
            var i = 0
            while i < chars.count, chars[i] == " " { i += 1 }
            while i < chars.count, chars[i] != " " { i += 1 }
            text = String(chars[..<i]); rest = String(chars[i...])
        }
        insert(text, replacing: s.replace, ctx: s.ctx)
        if s.ctx.fromBuffer || s.ctx.element == nil {
            if s.replace > 0 { buffer.removeLast(min(s.replace, buffer.count)) }
            buffer += text
        }
        hide()
        if s.kind == .completion { countWords(text) }
        if !rest.trimmingCharacters(in: .whitespaces).isEmpty {
            // Offer the rest of the suggestion straight away.
            let caret = s.ctx.caret + (text as NSString).length
            var anchor = s.ctx.anchor
            if s.ctx.placement == .inline, let el = s.ctx.element, let r = caretRect(el, caret) { anchor = r }
            let value: String? = s.ctx.element.flatMap { copy($0, kAXValueAttribute) }
            let ctx = Context(element: s.ctx.element, value: value, caret: caret, prefix: s.ctx.prefix + text, anchor: anchor,
                              placement: s.ctx.placement, fromBuffer: s.ctx.fromBuffer, app: s.ctx.app, window: s.ctx.window, screen: nil)
            present(Suggestion(kind: .completion, insert: rest, display: rest, replace: 0, ctx: ctx))
        } else if s.kind == .completion {
            remember(lineEnding: s.ctx.prefix, with: text)
            accepted += 1; defaults.set(accepted, forKey: "acAccepted")
            setStatus("Accepted in \(s.ctx.app)")
        }
    }

    /// Inserts at the cursor, first replacing `replacing` characters before it. Accessibility first
    /// (instant, native apps); otherwise backspaces + typing, which works everywhere.
    private func insert(_ text: String, replacing n: Int, ctx: Context) {
        if let el = ctx.element, !ctx.fromBuffer, let before: String = copy(el, kAXValueAttribute) {
            var selected = n == 0
            if n > 0 {
                var r = CFRange(location: max(ctx.caret - n, 0), length: min(n, ctx.caret))
                if let v = AXValueCreate(.cfRange, &r) {
                    selected = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success
                }
            }
            if selected, AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success,
               let after: String = copy(el, kAXValueAttribute), after != before {
                return
            }
            if selected && n > 0 { Self.type(text); return }   // typing replaces the selected characters
        }
        for _ in 0..<n { Paster.key(kVK_Delete) }
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

    // MARK: status, stats, apps

    private func setStatus(_ s: String) { if status != s { status = s } }

    private func countWords(_ text: String) {
        let n = text.split(whereSeparator: { $0.isWhitespace }).count
        guard n > 0 else { return }
        let today = Self.dayKey()
        if defaults.string(forKey: "acWordsDay") != today { wordsToday = 0; defaults.set(today, forKey: "acWordsDay") }
        wordsToday += n; wordsTotal += n
        defaults.set(wordsToday, forKey: "acWordsToday"); defaults.set(wordsTotal, forKey: "acWordsTotal")
    }

    private static func dayKey() -> String { Date().formatted(.iso8601.year().month().day()) }

    /// Remembers apps it has been used in, so Settings can offer a per-app on/off switch.
    private func noteApp(_ bundle: String, _ name: String) {
        guard !bundle.isEmpty, seenApps[bundle] == nil else { return }
        seenApps[bundle] = name
        defaults.set(seenApps, forKey: "acSeenApps")
    }

    func setApp(_ bundle: String, enabled on: Bool) {
        if on { excludedApps.removeAll { $0 == bundle } } else if !excludedApps.contains(bundle) { excludedApps.append(bundle) }
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
        guard learn, let ctx = focusedContext(includeScreen: false, force: true) else { return }
        let lines = ctx.prefix.split(separator: "\n", omittingEmptySubsequences: false)
        if let line = lines.dropLast().last ?? lines.last { add(String(line)) }
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

/// A click-through, non-activating panel that shows the suggestion: inline in grey right after the
/// cursor when the app reports where it is, otherwise as a small glass bubble under the field or at
/// the bottom of the window.
@MainActor
final class GhostText {
    enum Placement { case inline, below, centred }

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let bubble = NSVisualEffectView()

    func show(_ text: String, hint: String, at anchor: CGRect, placement: Placement) {
        let p = panel ?? make()
        panel = p
        let inline = placement == .inline
        let size = inline ? min(max(anchor.height * 0.78, 11), 30) : 14
        let attr = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: inline ? NSColor.secondaryLabelColor.withAlphaComponent(0.75) : NSColor.labelColor,
        ])
        attr.append(NSAttributedString(string: "  " + hint, attributes: [
            .font: NSFont.systemFont(ofSize: size * 0.72, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        label.attributedStringValue = attr
        label.sizeToFit()
        bubble.isHidden = inline
        let padX: CGFloat = inline ? 2 : 10, padY: CGFloat = inline ? 0 : 6
        let size2 = NSSize(width: min(label.frame.width, 720) + padX * 2, height: label.frame.height + padY * 2)
        // AX uses a top-left origin on the primary display; AppKit uses bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var origin: NSPoint
        switch placement {
        case .inline:
            origin = NSPoint(x: anchor.maxX + 1, y: primaryHeight - anchor.maxY + (anchor.height - size2.height) / 2)
        case .below:
            origin = NSPoint(x: anchor.minX, y: primaryHeight - anchor.minY - size2.height)
        case .centred:
            origin = NSPoint(x: anchor.midX - size2.width / 2, y: primaryHeight - anchor.minY - size2.height)
        }
        p.setFrame(NSRect(origin: origin, size: size2), display: true)
        bubble.frame = NSRect(origin: .zero, size: size2)
        label.frame = NSRect(x: padX, y: padY, width: size2.width - padX * 2, height: label.frame.height)
        p.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        bubble.material = .popover
        bubble.blendingMode = .behindWindow
        bubble.state = .active
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 9
        bubble.layer?.masksToBounds = true
        label.drawsBackground = false
        label.isBordered = false
        label.lineBreakMode = .byTruncatingTail
        p.contentView?.addSubview(bubble)
        p.contentView?.addSubview(label)
        return p
    }
}
