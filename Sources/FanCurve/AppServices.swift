import AppKit
import CryptoKit
import ServiceManagement

/// "Open at login" via SMAppService, so it also shows up in System Settings → General → Login Items.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var error: String?

    init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Installs newer FanCurve builds from GitHub Releases (published with ./release.sh) or from the
/// LAN server started with `./serve.sh on`. The LAN URL is shared with update.sh (~/.fancurve-update-url).
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate, available(String), downloading, installing, failed(String)
    }
    enum Source: String, CaseIterable, Identifiable {
        case github, lan
        var id: String { rawValue }
        var label: String { self == .github ? "GitHub Releases" : "Local network (serve.sh)" }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    @Published var source: Source { didSet { UserDefaults.standard.set(source.rawValue, forKey: "updateSource"); state = .idle } }
    @Published var repo: String { didSet { UserDefaults.standard.set(repo, forKey: "updateRepo"); state = .idle } }
    @Published private(set) var hasToken: Bool
    @Published var serverURL: String {
        didSet {
            let url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            try? (url.isEmpty ? nil : url + "\n").map { try $0.write(to: Self.urlFile, atomically: true, encoding: .utf8) }
            if url.isEmpty { try? FileManager.default.removeItem(at: Self.urlFile) }
        }
    }

    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    private static let urlFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".fancurve-update-url")
    private var timer: Timer?
    /// Where the latest release's files live (resolved during check).
    private var zipURL: URL?
    private var shaURL: URL?

    var availableVersion: String? { if case .available(let v) = state { return v } else { return nil } }
    var isConfigured: Bool { source == .github ? !repo.isEmpty : !serverURL.trimmingCharacters(in: .whitespaces).isEmpty }

    init() {
        let lan = ((try? String(contentsOf: Self.urlFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        serverURL = lan
        repo = UserDefaults.standard.string(forKey: "updateRepo") ?? "GeneralWaffels/FanCurve"
        source = Source(rawValue: UserDefaults.standard.string(forKey: "updateSource") ?? "") ?? .github
        hasToken = Keychain.read(Self.tokenAccount) != nil
        // Quiet background checks: shortly after launch, then every 6 hours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.check(userInitiated: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(userInitiated: false) }
        }
        timer?.tolerance = 600
    }

    // MARK: GitHub token (private repos) — stored in the login Keychain, never in files.

    private static let tokenAccount = "github-token"

    func setToken(_ token: String) {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { Keychain.delete(Self.tokenAccount) } else { Keychain.write(Self.tokenAccount, t) }
        hasToken = !t.isEmpty
        state = .idle
    }

    private func githubRequest(_ url: URL, accept: String = "application/vnd.github+json") -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let t = Keychain.read(Self.tokenAccount) { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        return r
    }

    // MARK: check

    func check(userInitiated: Bool) {
        guard isConfigured, state != .checking, state != .downloading, state != .installing else { return }
        state = .checking
        Task {
            do {
                let remote = try await (source == .github ? latestGitHub() : latestLAN())
                lastChecked = Date()
                // Versions are date stamps (YYYY.MM.DD.HHMM), so string order is release order.
                state = (currentVersion == "dev" || remote > currentVersion) ? .available(remote) : .upToDate
            } catch let e as UpdateError {
                state = userInitiated ? .failed(e.message) : .idle
            } catch {
                // Background checks stay quiet when offline; manual checks explain.
                state = userInitiated ? .failed(source == .github ? "Couldn't reach GitHub. Check your internet connection."
                                                                  : "Couldn't reach the update server. Is ./serve.sh on running on the other Mac?") : .idle
            }
        }
    }

    private func latestLAN() async throws -> String {
        guard let base = lanBase else { throw UpdateError("No update server set.") }
        let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: base.appendingPathComponent("VERSION"),
                                                                             cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        zipURL = base.appendingPathComponent("FanCurve.zip")
        shaURL = base.appendingPathComponent("FanCurve.zip.sha256")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func latestGitHub() async throws -> String {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { throw UpdateError("Invalid repository name.") }
        let (data, resp) = try await URLSession.shared.data(for: githubRequest(url))
        switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 401: throw UpdateError("GitHub rejected the token. Paste a new one below.")
        case 404: throw UpdateError(hasToken ? "No releases found, or the token can't read \(repo). Publish one with ./release.sh."
                                             : "No releases found for \(repo). If it's a private repository, add a GitHub token below.")
        case 403: throw UpdateError("GitHub rate limit reached. Try again later.")
        default: throw URLError(.badServerResponse)
        }
        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let url: URL }
            let tag_name: String
            let assets: [Asset]
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard let zip = release.assets.first(where: { $0.name == "FanCurve.zip" }) else {
            throw UpdateError("The latest release has no FanCurve.zip. Publish with ./release.sh.")
        }
        zipURL = zip.url
        shaURL = release.assets.first { $0.name == "FanCurve.zip.sha256" }?.url
        return release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
    }

    private var lanBase: URL? {
        let s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : URL(string: s.hasSuffix("/") ? String(s.dropLast()) : s)
    }

    // MARK: install

    /// Downloads, verifies and installs the update. install.sh needs root (fan service), so it runs
    /// through the standard macOS administrator password dialog, detached so it can relaunch the app.
    func install() {
        guard let version = availableVersion, let zipURL else { return }
        state = .downloading
        Task {
            do {
                let (zipFile, expected) = try await download(zipURL, sha: shaURL)
                if let expected {
                    let actual = SHA256.hash(data: try Data(contentsOf: zipFile)).map { String(format: "%02x", $0) }.joined()
                    guard expected == actual else { throw UpdateError("The download was corrupted (checksum mismatch).") }
                }

                let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("FanCurveUpdate-\(version)")
                try? FileManager.default.removeItem(at: dir)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try await run("/usr/bin/ditto", ["-x", "-k", zipFile.path, dir.path])

                state = .installing
                let root = dir.appendingPathComponent("FanCurve").path
                let shell = "xattr -dr com.apple.quarantine \(quoted(root)); nohup \(quoted(root + "/install.sh")) > /tmp/fancurve-update.log 2>&1 &"
                let script = "do shell script \"\(shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges with prompt \"FanCurve wants to install version \(version).\""
                try await run("/usr/bin/osascript", ["-e", script])
                // install.sh quits and relaunches the app when it's done.
            } catch let e as UpdateError {
                state = .failed(e.message)
            } catch {
                state = .failed("Update failed: \(error.localizedDescription)")
            }
        }
    }

    /// GitHub asset URLs are API URLs: they need the token and `Accept: application/octet-stream`, then
    /// redirect to storage that must *not* receive the token (the delegate strips it).
    private func download(_ url: URL, sha: URL?) async throws -> (URL, String?) {
        let session = URLSession(configuration: .ephemeral, delegate: RedirectStripper(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        func request(_ u: URL) -> URLRequest {
            source == .github ? githubRequest(u, accept: "application/octet-stream") : URLRequest(url: u)
        }
        let (file, resp) = try await session.download(for: request(url))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Download failed.") }
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("FanCurve-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: file, to: kept)
        var expected: String?
        if let sha {
            let (data, _) = try await session.data(for: request(sha))
            expected = String(decoding: data, as: UTF8.self).split(separator: " ").first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (kept, expected)
    }

    private final class RedirectStripper: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            var r = request
            if r.url?.host != "api.github.com" { r.setValue(nil, forHTTPHeaderField: "Authorization") }
            return r
        }
    }

    private func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func run(_ tool: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let err = Pipe()
            p.standardError = err
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 { cont.resume() }
                else {
                    let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    cont.resume(throwing: UpdateError(msg.contains("-128") ? "Update cancelled." : msg.isEmpty ? "\(tool) failed" : msg))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}

/// Minimal generic-password Keychain storage for FanCurve secrets.
enum Keychain {
    private static let service = "local.fancurve.app"

    static func read(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String) {
        delete(account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

struct UpdateError: Error { let message: String; init(_ m: String) { message = m } }
