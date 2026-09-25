import Foundation
import IOKit

// DDC/CI over Apple Silicon's IOAVService (private IOKit API, same approach as MonitorControl / m1ddc).
// Works for monitors on USB-C/Thunderbolt/DisplayPort. The built-in HDMI port on some Macs doesn't pass DDC.

@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<AnyObject>?
@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(_ service: AnyObject, _ chipAddress: UInt32, _ offset: UInt32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: AnyObject, _ chipAddress: UInt32, _ dataAddress: UInt32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

final class DDCDisplay: @unchecked Sendable {
    let name: String
    private let service: AnyObject
    private static let chip: UInt32 = 0x37      // DDC/CI I2C address
    private static let host: UInt8 = 0x51       // source address byte
    private static let brightnessVCP: UInt8 = 0x10

    init(name: String, service: AnyObject) { self.name = name; self.service = service }

    /// Finds external displays and pairs each with the product name of the framebuffer that precedes it in the registry.
    static func scan() -> [DDCDisplay] {
        var iter: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(IORegistryGetRootEntry(kIOMainPortDefault), kIOServicePlane,
                                            IOOptionBits(kIORegistryIterateRecursively), &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }

        var found: [DDCDisplay] = []
        var lastName: String?
        while case let entry = IOIteratorNext(iter), entry != 0 {
            defer { IOObjectRelease(entry) }
            var cls = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(entry, &cls)
            let className = String(cString: cls)

            if className == "AppleCLCD2" || className == "IOMobileFramebufferShim" {
                let attrs = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any]
                lastName = (attrs?["ProductAttributes"] as? [String: Any])?["ProductName"] as? String
            } else if className == "DCPAVServiceProxy" {
                let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
                guard location == "External", let svc = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
                found.append(DDCDisplay(name: lastName ?? "External display \(found.count + 1)", service: svc))
                lastName = nil
            }
        }
        return found
    }

    private func checksum(_ bytes: [UInt8], seed: UInt8) -> UInt8 { bytes.reduce(seed, ^) }

    /// Sets a VCP value. Blocking (~50 ms) — call off the main thread.
    @discardableResult
    func write(vcp: UInt8, value: UInt16) -> Bool {
        var packet: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xff)]
        packet.append(checksum(packet, seed: 0x6E ^ Self.host))
        for _ in 0..<2 {   // some monitors drop the first packet
            let r = packet.withUnsafeMutableBytes { IOAVServiceWriteI2C(service, Self.chip, UInt32(Self.host), $0.baseAddress!, UInt32($0.count)) }
            if r == kIOReturnSuccess { return true }
            usleep(20_000)
        }
        return false
    }

    /// Reads (current, max) for a VCP code, or nil if the monitor doesn't answer.
    func read(vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        var request: [UInt8] = [0x82, 0x01, vcp]
        request.append(checksum(request, seed: 0x6E ^ Self.host))
        for _ in 0..<3 {
            _ = request.withUnsafeMutableBytes { IOAVServiceWriteI2C(service, Self.chip, UInt32(Self.host), $0.baseAddress!, UInt32($0.count)) }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 12)
            let r = reply.withUnsafeMutableBytes { IOAVServiceReadI2C(service, Self.chip, 0, $0.baseAddress!, UInt32($0.count)) }
            // reply: [src, len, 0x02 (VCP reply), result, vcp, type, maxHi, maxLo, curHi, curLo, checksum]
            if r == kIOReturnSuccess, reply[2] == 0x02, reply[3] == 0x00, reply[4] == vcp {
                return (UInt16(reply[8]) << 8 | UInt16(reply[9]), UInt16(reply[6]) << 8 | UInt16(reply[7]))
            }
            usleep(30_000)
        }
        return nil
    }

    func setBrightness(_ v: Int) -> Bool { write(vcp: Self.brightnessVCP, value: UInt16(clamping: v)) }
    func readBrightness() -> (current: UInt16, max: UInt16)? { read(vcp: Self.brightnessVCP) }
}
