import Foundation
import IOKit

// Low-level access to the Apple System Management Controller (AppleSMC).
// Reading works as any user; writing (fan control) requires root.

public enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t, UInt8)
    case keyNotFound(String)
    case badType(String, String)

    public var description: String {
        switch self {
        case .serviceNotFound: return "AppleSMC service not found"
        case .openFailed(let r): return "IOServiceOpen failed (\(r))"
        case .callFailed(let r, let s): return "SMC call failed (kr=\(r), smc=\(s)) – writes need root"
        case .keyNotFound(let k): return "SMC key \(k) not found"
        case .badType(let k, let t): return "SMC key \(k) has unsupported type \(t)"
        }
    }
}

// Mirrors the C SMCKeyData_t struct used by the AppleSMC user client (80 bytes).
private struct SMCVersion { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
private struct SMCPLimitData { var version: UInt16 = 0, length: UInt16 = 0; var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0 }
private struct SMCKeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var dataAttributes: UInt8 = 0; var _pad: (UInt8, UInt8, UInt8) = (0, 0, 0) } // pad to C size (12)
private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)
private struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

private enum Cmd: UInt8 { case readBytes = 5, writeBytes = 6, keyFromIndex = 8, keyInfo = 9 }
private let kSMCHandleYPCEvent: UInt32 = 2

public struct SMCValue {
    public let key: String
    public let type: String
    public let bytes: [UInt8]

    /// Numeric interpretation of the common SMC data types.
    public var double: Double? {
        switch type {
        case "flt ": guard bytes.count >= 4 else { return nil }
            return Double(Float(bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24))
        case "ui8 ": return bytes.first.map(Double.init)
        case "ui16": guard bytes.count >= 2 else { return nil }; return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32": guard bytes.count >= 4 else { return nil }
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case "sp78": guard bytes.count >= 2 else { return nil }; return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2": guard bytes.count >= 2 else { return nil }; return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        default: return nil
        }
    }
}

private func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
private func fourCCString(_ v: UInt32) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? "????"
}

public final class SMC {
    private var conn: io_connect_t = 0
    private var infoCache: [String: SMCKeyInfo] = [:]
    private let lock = NSLock()

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        let r = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard r == kIOReturnSuccess else { throw SMCError.openFailed(r) }
    }

    deinit { IOServiceClose(conn) }

    private func call(_ input: inout SMCKeyData) throws -> SMCKeyData {
        var output = SMCKeyData()
        var outSize = MemoryLayout<SMCKeyData>.stride
        let r = IOConnectCallStructMethod(conn, kSMCHandleYPCEvent, &input, MemoryLayout<SMCKeyData>.stride, &output, &outSize)
        guard r == kIOReturnSuccess, output.result == 0 else { throw SMCError.callFailed(r, output.result) }
        return output
    }

    private func info(_ key: String) throws -> SMCKeyInfo {
        if let i = infoCache[key] { return i }
        var input = SMCKeyData()
        input.key = fourCC(key)
        input.data8 = Cmd.keyInfo.rawValue
        do {
            let out = try call(&input)
            infoCache[key] = out.keyInfo
            return out.keyInfo
        } catch { throw SMCError.keyNotFound(key) }
    }

    public func read(_ key: String) throws -> SMCValue {
        lock.lock(); defer { lock.unlock() }
        let i = try info(key)
        var input = SMCKeyData()
        input.key = fourCC(key)
        input.keyInfo.dataSize = i.dataSize
        input.data8 = Cmd.readBytes.rawValue
        let out = try call(&input)
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(i.dataSize))) }
        return SMCValue(key: key, type: fourCCString(i.dataType), bytes: bytes)
    }

    public func readDouble(_ key: String) -> Double? { (try? read(key))?.double }

    public func write(_ key: String, bytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        let i = try info(key)
        var input = SMCKeyData()
        input.key = fourCC(key)
        input.keyInfo.dataSize = i.dataSize
        input.data8 = Cmd.writeBytes.rawValue
        withUnsafeMutableBytes(of: &input.bytes) { buf in
            for (n, b) in bytes.prefix(min(Int(i.dataSize), 32)).enumerated() { buf[n] = b }
        }
        _ = try call(&input)
    }

    /// Writes a number using the key's native SMC type.
    public func write(_ key: String, value: Double) throws {
        let t = fourCCString(try { lock.lock(); defer { lock.unlock() }; return try info(key) }().dataType)
        switch t {
        case "flt ": let v = Float(value).bitPattern; try write(key, bytes: [0, 8, 16, 24].map { UInt8((v >> $0) & 0xff) })
        case "ui8 ": try write(key, bytes: [UInt8(clamping: Int(value))])
        case "ui16": let v = UInt16(clamping: Int(value)); try write(key, bytes: [UInt8(v >> 8), UInt8(v & 0xff)])
        case "fpe2": let v = UInt16(clamping: Int(value * 4)); try write(key, bytes: [UInt8(v >> 8), UInt8(v & 0xff)])
        default: throw SMCError.badType(key, t)
        }
    }

    public func keyCount() -> Int { Int(readDouble("#KEY") ?? 0) }

    public func key(at index: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        var input = SMCKeyData()
        input.data8 = Cmd.keyFromIndex.rawValue
        input.data32 = UInt32(index)
        return (try? call(&input)).map { fourCCString($0.key) }
    }

    public func allKeys() -> [String] { (0..<keyCount()).compactMap { key(at: $0) } }
}
