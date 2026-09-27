import CryptoKit
import Foundation
import SwiftUI

/// Downloads a GGUF model for autocomplete from Hugging Face into the Models folder, with progress,
/// a free-space check and a SHA-256 check against the published checksum.
@MainActor
final class ModelDownload: NSObject, ObservableObject {
    struct Option: Identifiable {
        let id: String          // file name in the Models folder
        let name: String
        let detail: String
        let url: URL
        let size: Int64
        let sha256: String
    }

    static let options = [
        Option(id: "gemma-4-E2B_q4_0-it.gguf", name: "Gemma 4 E2B (Google, recommended)",
               detail: "Google's official quantisation-aware build: best quality for its size.",
               url: URL(string: "https://huggingface.co/google/gemma-4-E2B-it-qat-q4_0-gguf/resolve/main/gemma-4-E2B_q4_0-it.gguf")!,
               size: 3_349_516_256, sha256: "fa401b55b07ee70a54c6dae3903c783a6e65064312529ea57175cb5f8dec6634"),
        Option(id: "gemma-4-E2B-it-Q4_K_M.gguf", name: "Gemma 4 E2B Q4_K_M (Unsloth)",
               detail: "A slightly smaller community build of the same model.",
               url: URL(string: "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf")!,
               size: 3_106_738_272, sha256: "740185b21d22ceb83a11c3aa62ad5842ef32c70f6096d756bbee85a1e4ec34b8"),
    ]

    enum State: Equatable {
        case idle
        case downloading(fraction: Double, detail: String)
        case verifying
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var current: Option?
    /// Called with the file name once a model is downloaded and verified.
    var onFinished: ((String) -> Void)?

    private let folder: URL
    private var task: URLSessionDownloadTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    init(folder: URL) { self.folder = folder }

    var busy: Bool {
        switch state { case .downloading, .verifying: return true; default: return false }
    }

    func installed(_ o: Option) -> Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(o.id).path) }

    func start(_ o: Option) {
        guard !busy else { return }
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? .max
        guard free > o.size + 1_000_000_000 else {
            state = .failed("Not enough free space: \(Self.gb(o.size)) needed, plus 1 GB to spare.")
            return
        }
        current = o
        state = .downloading(fraction: 0, detail: "Starting…")
        let t = session.downloadTask(with: o.url)
        task = t
        t.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        current = nil
        state = .idle
    }

    static func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }

    private func finish(_ file: URL, for o: Option) {
        state = .verifying
        let dest = folder.appendingPathComponent(o.id)
        Task.detached(priority: .utility) {
            let ok = Self.sha256(of: file) == o.sha256
            await MainActor.run {
                guard self.current?.id == o.id else { try? FileManager.default.removeItem(at: file); return }
                if ok {
                    try? FileManager.default.removeItem(at: dest)
                    do {
                        try FileManager.default.moveItem(at: file, to: dest)
                        self.state = .idle
                        self.current = nil
                        self.onFinished?(o.id)
                    } catch {
                        self.state = .failed("Couldn't save the model: \(error.localizedDescription)")
                    }
                } else {
                    try? FileManager.default.removeItem(at: file)
                    self.state = .failed("The download was damaged (checksum mismatch). Try again.")
                }
            }
        }
    }

    nonisolated private static func sha256(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension ModelDownload: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            guard downloadTask === self.task, let o = self.current else { return }
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : o.size
            self.state = .downloading(fraction: Double(totalBytesWritten) / Double(total),
                                      detail: "\(Self.gb(totalBytesWritten)) of \(Self.gb(total))")
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns, so move it first.
        let kept = location.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".gguf")
        let moved = (try? FileManager.default.moveItem(at: location, to: kept)) != nil
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        Task { @MainActor in
            guard downloadTask === self.task, let o = self.current else { try? FileManager.default.removeItem(at: kept); return }
            self.task = nil
            guard moved, (200..<300).contains(status) else {
                try? FileManager.default.removeItem(at: kept)
                self.state = .failed("The download failed (HTTP \(status)).")
                return
            }
            self.finish(kept, for: o)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        Task { @MainActor in
            guard task === self.task else { return }
            self.task = nil
            self.state = .failed("The download stopped: \(error.localizedDescription)")
        }
    }
}

/// The "Download a model" list in Autocomplete settings.
struct ModelDownloadRows: View {
    @ObservedObject var download: ModelDownload
    @EnvironmentObject var ac: Autocomplete

    var body: some View {
        ForEach(ModelDownload.options) { o in
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.name)
                    Text("\(o.detail) \(ModelDownload.gb(o.size)).").font(.caption).foregroundStyle(.secondary)
                    if download.current?.id == o.id { progress }
                }
                Spacer()
                action(o)
            }
        }
        if case .failed(let message) = download.state { StatusRow(text: message, color: .red) }
    }

    @ViewBuilder private var progress: some View {
        switch download.state {
        case .downloading(let f, let detail):
            ProgressView(value: f) { EmptyView() } currentValueLabel: { Text(detail).monospacedDigit() }
                .controlSize(.small)
        case .verifying:
            ProgressView { Text("Checking the download…").font(.caption) }.progressViewStyle(.linear).controlSize(.small)
        default: EmptyView()
        }
    }

    @ViewBuilder private func action(_ o: ModelDownload.Option) -> some View {
        if download.current?.id == o.id {
            Button("Cancel") { download.cancel() }
        } else if download.installed(o) {
            if ac.modelFile == o.id {
                Label("In Use", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            } else {
                Button("Use") { ac.modelFile = o.id }
            }
        } else {
            Button("Download") { download.start(o) }.disabled(download.busy)
        }
    }
}
