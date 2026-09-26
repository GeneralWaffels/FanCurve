import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Personalisation: your own past lines and vocabulary from the screen, stored only on this Mac.
extension Autocomplete {
    // MARK: personalisation (local only)

    var historyURL: URL { folder.appendingPathComponent("autocomplete-history.json") }

    func loadHistory() {
        history = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: historyURL))) ?? []
        historyCount = history.count
    }

    func saveHistory() {
        try? JSONEncoder().encode(history).write(to: historyURL, options: [.atomic, .completeFileProtection])
        historyCount = history.count
    }

    func add(_ line: String) {
        let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard learn, l.count >= 16, l.count <= 400, !history.contains(l) else { return }
        history.append(l)
        if history.count > 3000 { history.removeFirst(history.count - 3000) }
        saveHistory()
    }

    /// When you press Return, the line you just finished is kept as an example of your writing.
    func rememberCurrentLine() {
        guard learn, let ctx = focusedContext(includeScreen: false, force: true) else { return }
        let lines = ctx.prefix.split(separator: "\n", omittingEmptySubsequences: false)
        if let line = lines.dropLast().last ?? lines.last { add(String(line)) }
    }

    func remember(lineEnding value: String, with completion: String) {
        let line = value.split(separator: "\n").last.map(String.init) ?? ""
        add(line + completion)
    }

    func forgetHistory() { history = []; saveHistory() }

    // MARK: learning from the screen (vocabulary only)

    var vocabURL: URL { folder.appendingPathComponent("autocomplete-vocabulary.json") }

    func loadVocabulary() {
        vocabulary = (try? JSONDecoder().decode([String: Term].self, from: Data(contentsOf: vocabURL))) ?? [:]
    }

    func saveVocabulary() {
        try? JSONEncoder().encode(vocabulary).write(to: vocabURL, options: [.atomic, .completeFileProtection])
    }

    func forgetVocabulary() { vocabulary = [:]; saveVocabulary() }

    /// Most-seen terms first (for Settings).
    var topTerms: [String] { vocabulary.sorted { ($0.value.count, $0.value.lastSeen) > ($1.value.count, $1.value.lastSeen) }.map(\.key) }

    func updateScreenLearning() {
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

    static var screenLocked: Bool {
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
    func relevantTerms(for prefix: String) -> [String] {
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
    func similarHistory(to prefix: String) -> [String] {
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
