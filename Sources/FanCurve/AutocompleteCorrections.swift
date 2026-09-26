import AppKit
import ApplicationServices

/// Emoji codes and spelling fixes, offered like suggestions.
extension Autocomplete {
    // MARK: emoji & autocorrect

    /// `:smile`, `:thumbs`, `:fire` → the best-matching emoji (Cotypist-style emoji completion).
    func emojiSuggestion(_ ctx: Context) -> Suggestion? {
        let p = ctx.prefix
        guard let colon = p.lastIndex(of: ":") else { return nil }
        let code = p[p.index(after: colon)...]
        guard code.count >= 2, code.count <= 24, code.allSatisfy({ $0.isLetter || $0 == "_" }) else { return nil }
        if colon > p.startIndex, !p[p.index(before: colon)].isWhitespace { return nil }   // "10:30", "http:"
        guard let (e, name) = Self.emoji(for: code.lowercased()) else { return nil }
        return Suggestion(kind: .emoji, insert: e, display: "\(e)  \(name)", replace: code.count + 1, ctx: ctx)
    }

    static let emojiAliases: [String: String] = [
        "smile": "😄", "grin": "😁", "laugh": "😂", "lol": "😂", "joy": "😂", "rofl": "🤣", "wink": "😉", "blush": "😊",
        "heart": "❤️", "love": "😍", "kiss": "😘", "cool": "😎", "think": "🤔", "thinking": "🤔", "shrug": "🤷",
        "cry": "😢", "sob": "😭", "angry": "😠", "sad": "😞", "sweat": "😅", "scream": "😱", "sleep": "😴",
        "thumbsup": "👍", "thumbs": "👍", "yes": "👍", "thumbsdown": "👎", "clap": "👏", "wave": "👋", "pray": "🙏",
        "thanks": "🙏", "ok": "👌", "muscle": "💪", "eyes": "👀", "fire": "🔥", "tada": "🎉", "party": "🥳",
        "rocket": "🚀", "star": "⭐", "sparkles": "✨", "check": "✅", "done": "✅", "x": "❌", "warning": "⚠️",
        "coffee": "☕", "beer": "🍺", "pizza": "🍕", "cake": "🎂", "gift": "🎁", "sun": "☀️", "rain": "🌧️",
        "hundred": "💯", "100": "💯", "bulb": "💡", "idea": "💡", "calendar": "📅", "phone": "📱", "laptop": "💻",
    ]

    static let emojiIndex: [(emoji: String, name: String)] = {
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

    static func emoji(for code: String) -> (String, String)? {
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
    func correctionSuggestion(_ ctx: Context) -> Suggestion? {
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
}
