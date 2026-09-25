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

/// Checks the LAN update server started with `./serve.sh on` and installs newer builds.
/// Shares its URL with update.sh (~/.fancurve-update-url), so setting it up once covers both.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate, available(String), downloading, installing, failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
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

    var availableVersion: String? { if case .available(let v) = state { return v } else { return nil } }

    init() {
        serverURL = ((try? String(contentsOf: Self.urlFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Quiet background checks: shortly after launch, then every 6 hours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.check(userInitiated: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(userInitiated: false) }
        }
        timer?.tolerance = 600
    }

    private var base: URL? {
        let s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : URL(string: s.hasSuffix("/") ? String(s.dropLast()) : s)
    }

    func check(userInitiated: Bool) {
        guard let base, state != .checking, state != .downloading, state != .installing else { return }
        state = .checking
        Task {
            do {
                var req = URLRequest(url: base.appendingPathComponent("VERSION"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
                req.httpMethod = "GET"
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let remote = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                lastChecked = Date()
                // Versions are date stamps (YYYY.MM.DD.HHMM), so string order is release order.
                state = (currentVersion == "dev" || remote > currentVersion) ? .available(remote) : .upToDate
            } catch {
                // Background checks stay quiet when the server is off; manual checks explain.
                state = userInitiated ? .failed("Couldn't reach the update server. Is ./serve.sh on running on the other Mac?") : .idle
            }
        }
    }

    /// Downloads, verifies and installs the update. install.sh needs root (fan service), so it runs
    /// through the standard macOS administrator password dialog, detached so it can relaunch the app.
    func install() {
        guard let base, let version = availableVersion else { return }
        state = .downloading
        Task {
            do {
                let (zipURL, _) = try await URLSession.shared.download(from: base.appendingPathComponent("FanCurve.zip"))
                let (shaData, _) = try await URLSession.shared.data(from: base.appendingPathComponent("FanCurve.zip.sha256"))
                let expected = String(decoding: shaData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let actual = SHA256.hash(data: try Data(contentsOf: zipURL)).map { String(format: "%02x", $0) }.joined()
                guard expected == actual else { throw UpdateError("The download was corrupted (checksum mismatch).") }

                let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("FanCurveUpdate-\(version)")
                try? FileManager.default.removeItem(at: dir)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try await run("/usr/bin/ditto", ["-x", "-k", zipURL.path, dir.path])

                state = .installing
                let root = dir.appendingPathComponent("FanCurve").path
                let shell = "xattr -dr com.apple.quarantine \(quoted(root)); nohup \(quoted(root + "/install.sh")) > /tmp/fancurve-update.log 2>&1 &"
                let script = "do shell script \"\(shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges with prompt \"FanCurve wants to install version \(version).\""
                try await run("/usr/bin/osascript", ["-e", script])
                // install.sh quits and relaunches the app when it's done.
            } catch let e as UpdateError {
                state = .failed(e.message)
            } catch {
                state = .failed(error.localizedDescription.contains("-128") ? "Update cancelled." : "Update failed: \(error.localizedDescription)")
            }
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

struct UpdateError: Error { let message: String; init(_ m: String) { message = m } }
