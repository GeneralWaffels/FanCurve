import AppKit
import ApplicationServices
import Carbon.HIToolbox
import IOKit.ps
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// AI autocomplete that runs entirely on this Mac.
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
    @Published var paused = false { didSet { if paused { hide() }; updateWordCounter() } }
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
    @Published var onBattery = false
    /// True while suggestions come from Apple's on-device model instead of llama.cpp.
    @Published var usingApple = false
    var powerSource: CFRunLoopSource?
    private var appleTask: Task<Void, Never>?

    @Published var length: Length { didSet { save() } }
    @Published var acceptKey: AcceptKey { didSet { save() } }
    @Published var emoji: Bool { didSet { save() } }
    @Published var autocorrect: Bool { didSet { save() } }
    /// Writing style per app (bundle id → style), used instead of the main style in that app.
    @Published var appStyles: [String: String] { didSet { save() } }
    /// Shows today's completed-word count in the menu bar.
    @Published var menuBarWords: Bool { didSet { save(); updateWordCounter() } }

    // MARK: state
    @Published var engine: EngineState = .off
    @Published private(set) var accepted = 0
    @Published var historyCount = 0
    @Published var vocabulary: [String: Term] = [:]
    struct Term: Codable { var count: Int; var lastSeen: Date }
    var screenTimer: Timer?
    @Published private(set) var lastLatency: Int?
    /// Plain-English description of what autocomplete just did (shown in Settings).
    @Published private(set) var status = "Off"
    @Published private(set) var wordsToday = 0
    @Published private(set) var wordsTotal = 0
    /// Apps it has run in (bundle id → name), for the per-app switches in Settings.
    @Published private(set) var seenApps: [String: String] = [:]

    let folder: URL
    /// Downloads models from Hugging Face (Settings → Autocomplete → Model).
    let modelDownload: ModelDownload
    var modelsFolder: URL { folder.appendingPathComponent("Models") }
    private let defaults = UserDefaults.standard
    var server: Process?
    var stopping = false
    var healthTimer: Timer?
    var failedChecks = 0
    var crashes: [Date] = []
    let port = 18765
    nonisolated(unsafe) private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var debounce: Task<Void, Never>?
    private var stream: Task<Void, Never>?
    /// The last accepted suggestion, so Esc straight afterwards can undo it.
    private struct LastAccept { let typed: String; let removed: String; let at: Date }
    private var lastAccept: LastAccept?
    private var wordItem: NSStatusItem?
    private var suggestion: Suggestion?
    private var buffer = ""
    private var bufferPID: pid_t = 0
    private let ghost = GhostText()
    var history: [String] = []

    static let defaultExcluded = ["com.1password.1password", "com.bitwarden.desktop", "com.apple.Passwords",
                                  "com.apple.keychainaccess", "com.apple.Terminal", "com.googlecode.iterm2",
                                  "local.fancurve.app", "app.cotypist.Cotypist"]
    static let serverPaths = ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]

    init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FanCurve")
        modelDownload = ModelDownload(folder: folder.appendingPathComponent("Models"))
        enabled = defaults.bool(forKey: "acEnabled")
        style = defaults.string(forKey: "acStyle")
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
        appStyles = defaults.dictionary(forKey: "acAppStyles") as? [String: String] ?? [:]
        menuBarWords = defaults.bool(forKey: "acMenuBarWords")
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("Models"), withIntermediateDirectories: true)
        loadHistory()
        loadVocabulary()
        if modelFile.isEmpty { modelFile = availableModels.first ?? "" }
        modelDownload.onFinished = { [weak self] name in self?.modelFile = name }   // switch to it straight away
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.server?.terminate() }
        }
        watchPower()
        updateWordCounter()
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
        defaults.set(appStyles, forKey: "acAppStyles")
        defaults.set(menuBarWords, forKey: "acMenuBarWords")
    }

    // MARK: key handling

    func installTap() {
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

    func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil; tapSource = nil
    }

    /// Returns true to swallow the event (only the accept / dismiss keys while a suggestion is showing).
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard type == .keyDown else { buffer = ""; lastAccept = nil; hide(); return false }   // a click moves the caret
        if event.getIntegerValueField(.eventSourceUserData) == Paster.marker { return false }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])

        if let s = suggestion {
            let full = acceptKey == .tab ? (code == kVK_Tab && flags.isEmpty) : (code == kVK_RightArrow && flags.isEmpty)
            if full { accept(s, wordOnly: false); return true }
            if s.kind == .completion && code == kVK_RightArrow && flags == .maskAlternate { accept(s, wordOnly: true); return true }
            if code == kVK_Escape && flags.isEmpty { hide(); setStatus("Dismissed"); return true }
        }
        if code == kVK_Escape, flags.isEmpty, suggestion == nil, let u = lastAccept, Date().timeIntervalSince(u.at) < 5 {
            undo(u); return true
        }
        lastAccept = nil
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
        stream?.cancel()
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

    struct Context {
        let element: AXUIElement?
        let value: String?        // the field's text, when the app exposes it
        let caret: Int
        let prefix: String
        let anchor: CGRect        // AX coordinates (top-left origin)
        let placement: GhostText.Placement
        let fromBuffer: Bool
        let app: String
        let bundle: String
        let window: String?
        let screen: String?
    }

    /// - Parameters:
    ///   - allowEmpty: also works in an empty field (for reply drafts).
    ///   - screenLimit: always include this much visible text, even if "Use what's on screen" is off.
    func focusedContext(includeScreen: Bool = true, force: Bool = false, allowEmpty: Bool = false,
                                screenLimit: Int? = nil) -> Context? {
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
        if prefix == nil, allowEmpty {
            prefix = ""
            fromBuffer = el.flatMap { copy($0, kAXValueAttribute) as String? } == nil
        }
        guard let p = prefix, allowEmpty || p.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
            setStatus("Type a few words in \(name) to get suggestions")
            return nil
        }
        if !force, !allowEmpty, p.last?.isNewline == true { return nil }

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
        let screen: String?
        if let screenLimit { screen = windowEl.map { visibleText($0, excluding: value ?? p, limit: screenLimit) } }
        else { screen = useScreenContext && includeScreen ? windowEl.map { visibleText($0, excluding: value ?? p) } : nil }
        return Context(element: el, value: value, caret: caret, prefix: String(p.suffix(1500)), anchor: a, placement: placement,
                       fromBuffer: fromBuffer, app: name, bundle: bundle, window: title, screen: screen)
    }

    func copy<T>(_ el: AXUIElement, _ attr: String) -> T? {
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
    func visibleText(_ window: AXUIElement, excluding own: String, limit: Int = 1200) -> String {
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

    struct Suggestion {
        enum Kind { case completion, emoji, correction, draft }
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

        let prompt = buildPrompt(prefix: ctx.prefix, app: ctx.app, bundle: ctx.bundle, window: ctx.window, screen: ctx.screen)
        let started = Date()
        var checked = false
        // Words appear as the model produces them; the last, possibly unfinished word waits for the next one.
        let partial: (String) -> Void = { [weak self] raw in
            guard let self, let space = raw.lastIndex(of: " "), let t = Self.tidy(String(raw[..<space]), after: ctx.prefix) else { return }
            if !checked { guard self.stillCurrent(ctx) else { self.stream?.cancel(); return }; checked = true }
            if self.lastLatency == nil || self.suggestion == nil { self.lastLatency = Int(Date().timeIntervalSince(started) * 1000) }
            self.present(Suggestion(kind: .completion, insert: t, display: t, replace: 0, ctx: ctx))
        }
        complete(prompt: prompt, tokens: length.tokens, partial: partial) { [weak self] text, hitLimit in
            guard let self else { return }
            guard var raw = text else { self.setStatus("The model didn't answer: is it still loading?"); return }
            if hitLimit, let space = raw.lastIndex(of: " ") { raw = String(raw[..<space]) }   // drop a cut-off last word
            guard let t = Self.tidy(raw, after: ctx.prefix) else {
                if self.suggestion == nil { self.setStatus("No suggestion for that") }
                return
            }
            guard checked || self.stillCurrent(ctx) else { return }   // the user kept typing
            if self.suggestion == nil { self.lastLatency = Int(Date().timeIntervalSince(started) * 1000) }
            self.present(Suggestion(kind: .completion, insert: t, display: t, replace: 0, ctx: ctx))
        }
    }

    /// Cleans up model output for showing after `prefix`; nil if there's nothing worth suggesting.
    static func tidy(_ raw: String, after prefix: String) -> String? {
        var t = raw
        if prefix.last?.isWhitespace == true || prefix.isEmpty { t = String(t.drop { $0 == " " }) }
        t = t.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .newlines)
        return t.trimmingCharacters(in: .whitespaces).count >= 2 ? t : nil
    }

    // MARK: reply drafts

    /// "Draft a reply" shortcut: writes a reply to what's on screen (an email, a chat) in your style,
    /// shown in a bubble; Tab inserts it.
    func draftReply() {
        guard enabled, !paused, engine == .ready else { NSSound.beep(); return }
        hide()
        debounce?.cancel()
        guard var ctx = focusedContext(force: true, allowEmpty: true, screenLimit: 4000) else { NSSound.beep(); return }
        guard let screen = ctx.screen, screen.count > 20 else { setStatus("There's nothing on screen to reply to"); NSSound.beep(); return }
        if ctx.placement == .inline {
            let a = ctx.anchor
            ctx = Context(element: ctx.element, value: ctx.value, caret: ctx.caret, prefix: ctx.prefix,
                          anchor: CGRect(x: a.minX, y: a.maxY + 4, width: 1, height: 18), placement: .below,
                          fromBuffer: ctx.fromBuffer, app: ctx.app, bundle: ctx.bundle, window: ctx.window, screen: screen)
        }
        var p = "Below is what's on screen in \(ctx.app)"
        if let w = ctx.window, !w.isEmpty { p += " (window: \"\(w.prefix(80))\")" }
        p += ":\n\(screen)\n\nWriting style of the person replying: \(styleFor(ctx.bundle))\n"
        let examples = similarHistory(to: screen)
        if !examples.isEmpty { p += "Examples of how they phrase things:\n" + examples.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        p += "Write their reply to the most recent message above: short, natural, in their voice, no subject line.\n---\n"
        let prompt = p + "Reply:\n" + ctx.prefix
        setStatus("Drafting a reply…")
        ghost.show("Drafting a reply…", hint: "", at: ctx.anchor, placement: ctx.placement, multiline: true)
        let show: (String, Bool) -> Void = { [weak self] raw, final in
            guard let self else { return }
            var t = raw.trimmingCharacters(in: final ? .whitespacesAndNewlines : .newlines)
            if ctx.prefix.isEmpty || ctx.prefix.last?.isWhitespace == true { t = String(t.drop { $0 == " " }) }
            guard !t.isEmpty else { return }
            self.present(Suggestion(kind: .draft, insert: t, display: t, replace: 0, ctx: ctx))
        }
        complete(prompt: prompt, tokens: 160, stop: ["---", "\n\n\n"], temperature: 0.5, draft: true,
                 partial: { show($0, false) }) { [weak self] text, _ in
            guard let self else { return }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.ghost.hide(); self.setStatus("Couldn't draft a reply"); return
            }
            show(text, true)
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
        case .draft: hint = acceptKey == .tab ? "⇥ insert · esc" : "→ insert · esc"
        }
        ghost.show(s.display, hint: hint, at: s.ctx.anchor, placement: s.ctx.placement, multiline: s.kind == .draft)
        let how = s.ctx.fromBuffer ? " (from your typing)" : ""
        setStatus("Suggested in \(s.ctx.app)\(how)" + (s.kind == .completion ? " · \(lastLatency ?? 0) ms" : ""))
    }

    /// The style for an app: its own one if set, otherwise the main style.
    func styleFor(_ bundle: String) -> String {
        let own = appStyles[bundle]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return own.isEmpty ? style.trimmingCharacters(in: .whitespacesAndNewlines) : own
    }

    func buildPrompt(prefix: String, app: String, bundle: String = "", window: String?, screen: String?) -> String {
        var p = "Below is text being typed on a Mac in \(app)"
        if let w = window, !w.isEmpty { p += " (window: \"\(w.prefix(80))\")" }
        p += ". Continue it naturally with the next few words, in the writer's own voice.\n"
        p += "Writing style: \(styleFor(bundle))\n"
        if let s = screen, !s.isEmpty { p += "Also visible on screen: \(s)\n" }
        let terms = relevantTerms(for: prefix)
        if !terms.isEmpty { p += "Names and terms the writer often sees and uses: \(terms.joined(separator: ", "))\n" }
        let examples = similarHistory(to: prefix)
        if !examples.isEmpty { p += "Examples of how the writer phrases things:\n" + examples.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        return p + "---\n" + prefix
    }

    /// Asks the model for a continuation. `partial` gets the text so far as it streams in; `done` gets
    /// the whole text and whether it stopped at the token limit.
    func complete(prompt: String, tokens: Int, stop: [String] = ["\n", "---"], temperature: Double = 0.2,
                          draft: Bool = false, partial: ((String) -> Void)? = nil,
                          done: @escaping (String?, Bool) -> Void) {
        stream?.cancel()
        if usingApple { appleComplete(prompt: prompt, tokens: tokens, draft: draft, done: done); return }
        guard let url = URL(string: "http://127.0.0.1:\(port)/completion") else { return }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = draft ? 20 : 4
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["prompt": prompt, "n_predict": tokens, "temperature": temperature, "top_k": 20, "top_p": 0.9,
                                   "stop": stop, "cache_prompt": true, "stream": true]
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        stream = Task {
            var text = "", limit = false
            do {
                let (bytes, _) = try await URLSession.shared.bytes(for: r)
                for try await line in bytes.lines {
                    guard !Task.isCancelled else { return }
                    guard line.hasPrefix("data: "),
                          let j = try? JSONSerialization.jsonObject(with: Data(line.utf8.dropFirst(6))) as? [String: Any] else { continue }
                    if let c = j["content"] as? String, !c.isEmpty { text += c; partial?(text) }
                    if j["stop"] as? Bool == true { limit = (j["stop_type"] as? String) == "limit"; break }
                }
            } catch {
                guard !Task.isCancelled else { return }
                done(text.isEmpty ? nil : text, false); return
            }
            guard !Task.isCancelled else { return }
            done(text, limit)
        }
    }

    /// Apple's on-device model is chat-tuned, so it's asked to fill a blank (▮) rather than to "continue",
    /// which stops it replying to the text instead of completing it.
    private func appleComplete(prompt: String, tokens: Int, draft: Bool, done: @escaping (String?, Bool) -> Void) {
        appleTask?.cancel()
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { done(nil, false); return }
        let parts = prompt.components(separatedBy: "---\n")
        let context = parts.first ?? "", text = parts.dropFirst().joined(separator: "---\n")
        if draft {
            appleTask = Task {
                let session = LanguageModelSession(instructions: context)
                let r = try? await session.respond(to: "Write only the reply text.\n" + text,
                                                   options: GenerationOptions(temperature: 0.5, maximumResponseTokens: tokens))
                guard !Task.isCancelled else { return }
                done(r?.content, false)
            }
            return
        }
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
        let removed = String(s.ctx.prefix.suffix(s.replace))
        if s.replace == 0, let prev = lastAccept {   // ⌥→ word by word: undo takes back all of it
            lastAccept = LastAccept(typed: prev.typed + text, removed: prev.removed, at: Date())
        } else {
            lastAccept = LastAccept(typed: text, removed: removed, at: Date())
        }
        if s.ctx.fromBuffer || s.ctx.element == nil {
            if s.replace > 0 { buffer.removeLast(min(s.replace, buffer.count)) }
            buffer += text
        }
        hide()
        if s.kind == .completion || s.kind == .draft { countWords(text) }
        if !rest.trimmingCharacters(in: .whitespaces).isEmpty {
            // Offer the rest of the suggestion straight away.
            let caret = s.ctx.caret + (text as NSString).length
            var anchor = s.ctx.anchor
            if s.ctx.placement == .inline, let el = s.ctx.element, let r = caretRect(el, caret) { anchor = r }
            let value: String? = s.ctx.element.flatMap { copy($0, kAXValueAttribute) }
            let ctx = Context(element: s.ctx.element, value: value, caret: caret, prefix: s.ctx.prefix + text, anchor: anchor,
                              placement: s.ctx.placement, fromBuffer: s.ctx.fromBuffer, app: s.ctx.app, bundle: s.ctx.bundle,
                              window: s.ctx.window, screen: nil)
            present(Suggestion(kind: .completion, insert: rest, display: rest, replace: 0, ctx: ctx))
        } else if s.kind == .completion || s.kind == .draft {
            if s.kind == .completion { remember(lineEnding: s.ctx.prefix, with: text) }
            accepted += 1; defaults.set(accepted, forKey: "acAccepted")
            setStatus("Accepted in \(s.ctx.app) · Esc to undo")
        }
    }

    /// Esc right after accepting: removes what was inserted and puts back anything it replaced.
    private func undo(_ u: LastAccept) {
        lastAccept = nil
        for _ in 0..<u.typed.count { Paster.key(kVK_Delete) }
        if !u.removed.isEmpty { Self.type(u.removed) }
        if !buffer.isEmpty {
            buffer.removeLast(min(u.typed.count, buffer.count))
            buffer += u.removed
        }
        let n = u.typed.split(whereSeparator: { $0.isWhitespace }).count
        wordsToday = max(wordsToday - n, 0); wordsTotal = max(wordsTotal - n, 0)
        defaults.set(wordsToday, forKey: "acWordsToday"); defaults.set(wordsTotal, forKey: "acWordsTotal")
        updateWordCounter()
        setStatus("Undone")
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
        if text.contains("\n") { Paster.paste(text) } else { Self.type(text) }   // typed Returns could send a chat message
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
        stream?.cancel()
        appleTask?.cancel()
        ghost.hide()
    }

    // MARK: status, stats, apps

    func setStatus(_ s: String) { if status != s { status = s } }

    private func countWords(_ text: String) {
        let n = text.split(whereSeparator: { $0.isWhitespace }).count
        guard n > 0 else { return }
        let today = Self.dayKey()
        if defaults.string(forKey: "acWordsDay") != today { wordsToday = 0; defaults.set(today, forKey: "acWordsDay") }
        wordsToday += n; wordsTotal += n
        defaults.set(wordsToday, forKey: "acWordsToday"); defaults.set(wordsTotal, forKey: "acWordsTotal")
        updateWordCounter()
    }

    // MARK: menu bar word counter

    private func updateWordCounter() {
        guard menuBarWords else {
            if let wordItem { NSStatusBar.system.removeStatusItem(wordItem) }
            wordItem = nil
            return
        }
        let item = wordItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        wordItem = item
        if defaults.string(forKey: "acWordsDay") != Self.dayKey() { wordsToday = 0 }
        item.button?.image = NSImage(systemSymbolName: paused ? "text.cursor" : "sparkles", accessibilityDescription: "Autocomplete")
        item.button?.imagePosition = .imageLeading
        item.button?.title = " \(wordsToday)"
        item.button?.toolTip = "Words completed today: \(wordsToday) (\(wordsTotal) in total)"
        let menu = NSMenu()
        menu.addItem(withTitle: "\(wordsToday) words today · \(wordsTotal) in total", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let pause = menu.addItem(withTitle: paused ? "Resume Autocomplete" : "Pause Autocomplete",
                                 action: #selector(WordMenuTarget.toggle), keyEquivalent: "")
        pause.target = WordMenuTarget.shared
        WordMenuTarget.shared.action = { [weak self] in self?.paused.toggle() }
        item.menu = menu
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

}
