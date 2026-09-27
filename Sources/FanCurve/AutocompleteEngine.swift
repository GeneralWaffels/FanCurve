import AppKit
import ApplicationServices
import IOKit.ps
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The model engine: llama-server's lifecycle (start, health checks, crash recovery) and switching to
/// Apple's on-device model on battery.
extension Autocomplete {
    // MARK: models & engine

    var serverPath: String? { Self.serverPaths.first { FileManager.default.isExecutableFile(atPath: $0) } }
    var availableModels: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: modelsFolder.path)) ?? []).filter { $0.hasSuffix(".gguf") }.sorted()
    }
    func start() {
        guard !paused else { return }
        installTap()
        onBattery = Self.isOnBattery
        applyEngineForPower()
        watchHealth()
        updateScreenLearning()
    }

    func stop() {
        screenTimer?.invalidate(); screenTimer = nil
        healthTimer?.invalidate(); healthTimer = nil
        removeTap()
        hide()
        stopServer()
        usingApple = false
        engine = .off
        setStatus("Off")
    }

    func restartServer() {
        stopping = true
        server?.terminate(); server = nil
        stopping = false
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
            p.terminationHandler = { proc in   // Autocomplete lives as long as the app
                Task { @MainActor in self.serverExited(proc) }
            }
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

    /// Restarts llama-server if it crashes (not when FanCurve stopped it), backing off if it keeps failing.
    func serverExited(_ p: Process) {
        guard p === server, !stopping, enabled, !paused, !usingApple else { return }
        server = nil
        let now = Date()
        crashes = crashes.filter { now.timeIntervalSince($0) < 600 } + [now]
        guard crashes.count <= 5 else {
            engine = .failed("The model server keeps stopping. Try another model file.")
            setStatus("The model server crashed 5 times in 10 minutes, so it's off for now")
            return
        }
        engine = .starting
        setStatus("The model server stopped; restarting it")
        let delay = Double(crashes.count * crashes.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.enabled, !self.paused, !self.usingApple, self.server == nil else { return }
            self.restartServer()
        }
    }

    /// Every 30 s, checks the server still answers (it may be one reused from a previous launch, which
    /// FanCurve doesn't get exit notifications for) and restarts it after two failed checks.
    func watchHealth() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.enabled, !self.paused, !self.usingApple, self.engine == .ready else { return }
                Task {
                    if await self.health() { self.failedChecks = 0; return }
                    self.failedChecks += 1
                    if self.failedChecks >= 2 { self.failedChecks = 0; self.setStatus("The model server stopped answering; restarting it"); self.stopServer(); self.restartServer() }
                }
            }
        }
        healthTimer?.tolerance = 10
    }

    func health() async -> Bool {
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

    func watchPower() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<Autocomplete>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.updatePower() }
        }, ctx)?.takeRetainedValue() else { return }
        powerSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    }

    func updatePower() {
        let battery = Self.isOnBattery
        if battery != onBattery { onBattery = battery }
        if enabled && !paused { applyEngineForPower() }
    }

    /// On battery: Apple's model (llama.cpp stopped), pause, or keep going. On power: the selected model.
    func applyEngineForPower() {
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
    func stopServer() {
        stopping = true
        server?.terminate(); server = nil
        stopping = false
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "llama-server.*--port \(port)"]
        try? p.run()
    }

    /// Loads the style prompt into the model's cache so the first real suggestion is fast.
    func warmUp() { complete(prompt: buildPrompt(prefix: "Hello", app: "Notes", window: nil, screen: nil), tokens: 4) { _, _ in } }
}
