import SwiftUI

struct DisplaysView: View {
    @EnvironmentObject var displays: Displays

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("External displays").font(.headline)
                Spacer()
                Button("Rescan") { displays.rescan() }
            }

            if displays.monitors.isEmpty {
                Text("No external displays found. DDC works over USB-C, Thunderbolt and DisplayPort; some HDMI ports and docks don't pass it through.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            ForEach(displays.monitors) { m in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(m.name)
                        if !m.readable {
                            Text("(no DDC reply — brightness may still be settable)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Int(m.brightness))%").monospacedDigit()
                    }
                    Slider(value: Binding(get: { m.brightness }, set: { displays.setBrightness($0.rounded(), for: m.id) }), in: 0...100)
                }
            }

            Divider()

            Toggle("Match laptop light sensor", isOn: $displays.followSensor).toggleStyle(.switch)
            HStack(spacing: 24) {
                stat("Ambient light", displays.lux.map { "\(Int($0)) lux" } ?? (displays.sensor.available ? "--" : "no sensor"))
                stat("Sensor target", displays.lux.map {
                    "\(Int(Displays.brightness(forLux: $0, min: displays.minBrightness, max: displays.maxBrightness)))%"
                } ?? "--")
                if displays.sensorPaused {
                    Text("Lid closed — sensor is covered, brightness held").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
            }
            HStack(spacing: 24) {
                LabeledContent("Darkest") {
                    Slider(value: $displays.minBrightness, in: 0...100, step: 1).frame(width: 150)
                    Text("\(Int(displays.minBrightness))%").monospacedDigit().frame(width: 40)
                }
                LabeledContent("Brightest") {
                    Slider(value: $displays.maxBrightness, in: 0...100, step: 1).frame(width: 150)
                    Text("\(Int(displays.maxBrightness))%").monospacedDigit().frame(width: 40)
                }
                Spacer()
            }
            .font(.callout)
            Text("Dark room → Darkest, \(Int(Displays.fullBrightLux))+ lux (bright office / daylight) → Brightest. Moving a slider by hand switches sensor matching off.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
    }
}

struct KeyboardView: View {
    @EnvironmentObject var keyboard: KeyboardBlocker

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Keyboard cleaning mode", isOn: Binding(get: { keyboard.isOn }, set: { _ in keyboard.toggle() }))
                .toggleStyle(.switch)
            Text(keyboard.isOn
                 ? "All keys are ignored — use the trackpad to switch off (auto-off in \(keyboard.secondsLeft / 60):\(String(format: "%02d", keyboard.secondsLeft % 60)))"
                 : "Ignores every key press while the trackpad keeps working. Turns itself off after \(keyboard.timeout / 60) min.")
                .font(.callout).foregroundStyle(.secondary)
            if keyboard.needsPermission {
                Button("Grant Accessibility access…") { keyboard.openAccessibilitySettings() }
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

func stat(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.caption).foregroundStyle(.secondary)
        Text(value).font(.title3.monospacedDigit())
    }
}
