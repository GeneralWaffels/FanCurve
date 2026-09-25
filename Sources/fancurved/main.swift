import Foundation
import SMCKit

// fancurved — applies the fan curve from /Library/Application Support/FanCurve/config.json.
// Runs as root via launchd. Any exit path hands the fans back to macOS.

setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ msg: String) -> Never { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); exit(1) }

let hw: Hardware
do { hw = try Hardware() } catch { fail("cannot open SMC: \(error)") }

let args = CommandLine.arguments.dropFirst()

switch args.first {
case "sensors":
    print("CPU sensors (\(hw.cpuKeys.count)):", hw.cpuKeys.joined(separator: " "))
    print("GPU sensors (\(hw.gpuKeys.count)):", hw.gpuKeys.joined(separator: " "))
    for s in TempSource.allCases { print(String(format: "%-34@ %.1f °C", s.label as NSString, hw.temperature(s) ?? .nan)) }
    for f in hw.fans() { print("Fan \(f.id): \(Int(f.actual)) rpm (target \(Int(f.target)), range \(Int(f.min))–\(Int(f.max)), \(f.manual ? "manual" : "auto"))") }
    exit(0)

case "auto":
    hw.setAllAuto()
    print("fans returned to macOS control")
    exit(0)

case "set":
    guard let rpm = args.dropFirst().first.flatMap(Double.init) else { fail("usage: fancurved set <rpm>") }
    do { for i in 0..<hw.fanCount { try hw.setManual(fan: i, rpm: rpm) } } catch { fail("\(error)") }
    print("fans set to \(Int(rpm)) rpm — run `fancurved auto` to undo")
    exit(0)

case "run", nil:
    break

default:
    fail("usage: fancurved [run | sensors | auto | set <rpm>]")
}

// MARK: - daemon loop

let interval = 2.0
let hysteresis = 3.0          // °C below the activation point before handing back to macOS
var smoothed: Double?
var active = false            // true while we hold manual control
var wantedSince: Date?        // when the curve first asked for fans while idle (spin-up delay)

func log(_ msg: String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("\(f.string(from: Date())) \(msg)")
}
var lastConfigMTime: Date?
var config = Paths.loadConfig()

func handBack(_ reason: String? = nil) {
    if active || hw.fans().contains(where: \.manual) {
        hw.setAllAuto()
        if active { log("fans → macOS\(reason.map { " (\($0))" } ?? "")") }
    }
    active = false
    wantedSince = nil
}

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { handBack("signal \(sig)"); log("stopped"); exit(0) }
    src.resume()
    signalSources.append(src)
}

func reloadConfigIfChanged() {
    let mtime = (try? FileManager.default.attributesOfItem(atPath: Paths.config.path))?[.modificationDate] as? Date
    guard mtime != lastConfigMTime else { return }
    lastConfigMTime = mtime
    config = Paths.loadConfig()
    log("config loaded: enabled=\(config.enabled) source=\(config.source.rawValue) points=\(config.points.map { "\(Int($0.temp))°:\(Int($0.rpm))" })")
}

func tick() {
    reloadConfigIfChanged()
    let raw = hw.temperature(config.source)

    guard config.enabled else {
        handBack("curve disabled")
        Paths.save(DaemonStatus(updated: Date(), temp: raw, smoothedTemp: nil, targetRPM: nil, mode: "auto", message: "curve disabled"))
        return
    }
    guard let temp = raw else {
        handBack()
        Paths.save(DaemonStatus(updated: Date(), temp: nil, smoothedTemp: nil, targetRPM: nil, mode: "error", message: "no temperature reading — macOS in control"))
        return
    }

    // Exponential smoothing; rising temps react 3× faster than falling ones so we never lag behind a heat spike.
    let tau = max(config.smoothing, 0.1) / (temp > (smoothed ?? temp) ? 3 : 1)
    let alpha = 1 - exp(-interval / tau)
    smoothed = smoothed.map { $0 + alpha * (temp - $0) } ?? temp
    let t = smoothed!

    let fans = hw.fans()
    let fanMin = fans.map(\.min).max() ?? 0
    let fanMax = fans.map(\.max).min() ?? 0
    var mode = "curve"
    var target: Double

    if temp >= config.criticalTemp {
        target = fanMax; mode = "critical"
        if !active { log(String(format: "critical %.1f °C → fans max", temp)) }
    } else {
        target = config.rpm(at: t)
        // Below the fan's minimum spin speed the curve means "let macOS idle the fans".
        let wantActive = active ? config.rpm(at: t + hysteresis) >= fanMin : target >= fanMin
        if !wantActive {
            handBack(String(format: "%.1f °C, below curve minimum", t))
            Paths.save(DaemonStatus(updated: Date(), temp: temp, smoothedTemp: t, targetRPM: nil, mode: "auto", message: "below curve minimum — macOS idle"))
            return
        }
        // Spin-up delay: from idle, the curve must want fans continuously for spinUpDelay seconds.
        if !active {
            let since = wantedSince ?? Date()
            wantedSince = since
            let waited = Date().timeIntervalSince(since)
            if waited < config.spinUpDelay {
                if active || hw.fans().contains(where: \.manual) { hw.setAllAuto() }
                Paths.save(DaemonStatus(updated: Date(), temp: temp, smoothedTemp: t, targetRPM: nil, mode: "auto",
                                        message: String(format: "waiting — fans start in %.0f s if it stays warm", config.spinUpDelay - waited)))
                return
            }
            log(String(format: "%.1f °C → fans on (%.0f rpm)", t, max(target, fanMin)))
        }
    }
    target = min(max(target, fanMin), fanMax)

    do {
        for f in fans { try hw.setManual(fan: f.id, rpm: target) }
        active = true
        Paths.save(DaemonStatus(updated: Date(), temp: temp, smoothedTemp: t, targetRPM: target, mode: mode, message: nil))
    } catch {
        handBack()
        Paths.save(DaemonStatus(updated: Date(), temp: temp, smoothedTemp: t, targetRPM: nil, mode: "error", message: "\(error)"))
    }
}

try? FileManager.default.createDirectory(at: Paths.dir, withIntermediateDirectories: true)
log("fancurved started — \(hw.fanCount) fans, \(hw.cpuKeys.count) CPU sensors, \(hw.gpuKeys.count) GPU sensors")
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now(), repeating: interval)
timer.setEventHandler(handler: tick)
timer.resume()
dispatchMain()
