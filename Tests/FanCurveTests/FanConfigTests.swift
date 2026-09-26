import Foundation
import Testing
@testable import SMCKit

@Suite("Fan curve")
struct FanConfigTests {
    @Test func interpolatesBetweenPoints() {
        var c = FanConfig()
        c.points = [.init(temp: 40, rpm: 2000), .init(temp: 60, rpm: 4000)]
        #expect(c.rpm(at: 50) == 3000)
        #expect(c.rpm(at: 30) == 2000)   // below the curve: first point
        #expect(c.rpm(at: 90) == 4000)   // above the curve: last point
    }

    @Test func pointOrderDoesNotMatter() {
        var c = FanConfig()
        c.points = [.init(temp: 60, rpm: 4000), .init(temp: 40, rpm: 2000)]
        #expect(c.rpm(at: 45) == 2500)
    }

    @Test func emptyCurveIsOff() {
        var c = FanConfig()
        c.points = []
        #expect(c.rpm(at: 70) == 0)
        #expect(c.startTemp(fanMin: 2317) == nil)
    }

    @Test(arguments: FanConfig.presetOrder)
    func presetsHaveFansOffZone(_ name: String) throws {
        var c = FanConfig()
        c.points = try #require(FanConfig.presets[name])
        #expect(c.rpm(at: 40) == 0, "laptop presets keep the fans off at idle")
        let start = try #require(c.startTemp(fanMin: 2317))
        #expect(start > 44 && start < 60)
        #expect(c.rpm(at: 100) == 7826)
    }

    @Test func presetsGetLouderInOrder() throws {
        let starts = try FanConfig.presetOrder.map { name -> Double in
            var c = FanConfig(); c.points = try #require(FanConfig.presets[name])
            return try #require(c.startTemp(fanMin: 2317))
        }
        #expect(starts == starts.sorted(by: >), "Quiet starts latest, Performance earliest")
    }

    @Test func oldConfigFilesStillLoad() throws {
        // A config.json from before spinUpDelay and criticalTemp existed.
        let json = #"{"enabled":true,"source":"cpuAvg","points":[{"temp":50,"rpm":0},{"temp":70,"rpm":5000}],"smoothing":4}"#
        let c = try JSONDecoder().decode(FanConfig.self, from: Data(json.utf8))
        #expect(c.enabled)
        #expect(c.source == .cpuAvg)
        #expect(c.smoothing == 4)
        #expect(c.spinUpDelay == FanConfig().spinUpDelay)
        #expect(c.criticalTemp == FanConfig().criticalTemp)
    }

    @Test func unknownSourceFallsBack() throws {
        let c = try JSONDecoder().decode(FanConfig.self, from: Data(#"{"source":"somethingNew"}"#.utf8))
        #expect(c.source == FanConfig().source)
    }

    @Test func roundTrips() throws {
        var c = FanConfig()
        c.enabled = true; c.spinUpDelay = 30; c.points = FanConfig.presets["Noctua Quiet"]!
        let back = try JSONDecoder().decode(FanConfig.self, from: JSONEncoder().encode(c))
        #expect(back == c)
    }
}
