import AppKit
import SwiftUI

/// Raycast-style quicklinks: a name, an optional keyword and a URL with `{query}` in it.
/// Typing "gh fancurve" in the palette opens GitHub's search for "fancurve".
struct Quicklink: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var keyword: String
    var url: String

    var takesQuery: Bool { url.contains("{query}") }

    /// The URL with `query` filled in (percent-encoded), or nil if it isn't a valid URL.
    func resolved(_ query: String) -> URL? {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? query
        var s = url.replacingOccurrences(of: "{query}", with: q)
        if !s.contains("://") { s = "https://" + s }
        return URL(string: s)
    }
}

@MainActor
final class Quicklinks: ObservableObject {
    @Published var links: [Quicklink] { didSet { if links != oldValue { save() } } }

    static let defaults = [
        Quicklink(name: "Google", keyword: "g", url: "https://www.google.com/search?q={query}"),
        Quicklink(name: "GitHub", keyword: "gh", url: "https://github.com/search?q={query}"),
        Quicklink(name: "YouTube", keyword: "yt", url: "https://www.youtube.com/results?search_query={query}"),
        Quicklink(name: "Maps", keyword: "map", url: "maps://?q={query}"),
        Quicklink(name: "Translate", keyword: "tr", url: "https://translate.google.com/?sl=auto&tl=en&text={query}"),
    ]

    init() {
        if let d = UserDefaults.standard.data(forKey: "quicklinks"), let l = try? JSONDecoder().decode([Quicklink].self, from: d) {
            links = l
        } else {
            links = Self.defaults
        }
    }

    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(links), forKey: "quicklinks") }

    func open(_ l: Quicklink, _ query: String) {
        if let u = l.resolved(query) { NSWorkspace.shared.open(u) }
    }

    /// Palette rows: a direct hit when the query starts with a keyword, plus every link by name.
    func items(for query: String) -> [PanelItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [PanelItem] = []
        if let space = q.firstIndex(of: " ") {
            let key = q[..<space].lowercased(), rest = q[q.index(after: space)...].trimmingCharacters(in: .whitespaces)
            for l in links where !l.keyword.isEmpty && l.keyword.lowercased() == key && l.takesQuery && !rest.isEmpty {
                out.append(PanelItem(id: "ql.hit." + l.id.uuidString, section: "Quicklinks", title: "\(l.name): \(rest)",
                                     subtitle: l.resolved(rest)?.absoluteString, accessory: "Quicklink", symbol: "link", boost: 40, tint: .blue,
                                     keywords: [q]) { [weak self] in self?.open(l, rest); return true })
            }
        }
        for l in links {
            out.append(PanelItem(id: "ql." + l.id.uuidString, section: "Quicklinks", title: l.name,
                                 subtitle: l.takesQuery ? "Type “\(l.keyword.isEmpty ? l.name.lowercased() : l.keyword) …” to search" : l.url,
                                 accessory: l.keyword.isEmpty ? "Quicklink" : l.keyword, symbol: "link", tint: .blue,
                                 keywords: [l.keyword, "quicklink", "link", "open"]) { [weak self] in
                if l.takesQuery {
                    // Put the keyword in the search field so the next thing typed is the query.
                    let prefix = (l.keyword.isEmpty ? l.name.lowercased() : l.keyword) + " "
                    DispatchQueue.main.async { LauncherPanel.shared.model.query = prefix }   // after the panel reopens
                    return false
                }
                self?.open(l, ""); return true
            })
        }
        return out
    }
}

/// Settings list of quicklinks.
struct QuicklinksSection: View {
    @EnvironmentObject var quicklinks: Quicklinks

    var body: some View {
        Section {
            ForEach($quicklinks.links) { $l in
                HStack(spacing: 8) {
                    TextField("Name", text: $l.name).frame(width: 110)
                    TextField("Keyword", text: $l.keyword).frame(width: 70)
                    TextField("URL", text: $l.url, prompt: Text("https://example.com/search?q={query}"))
                    Button { quicklinks.links.removeAll { $0.id == l.id } } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            }
            HStack {
                Button { quicklinks.links.append(Quicklink(name: "New Link", keyword: "", url: "https://")) } label: {
                    Label("Add Quicklink", systemImage: "plus")
                }
                Spacer()
                Button("Restore Defaults") { quicklinks.links = Quicklinks.defaults }
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Quicklinks")
        } footer: {
            Footer("Put {query} in the URL where your search should go, then type the keyword and a search in the palette, for example “gh fancurve”. Links without {query} just open.")
        }
    }
}
