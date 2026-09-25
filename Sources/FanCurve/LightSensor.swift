import Foundation

// Reads the MacBook's ambient light sensor (lux) through the private IOHIDEventSystemClient API.

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

final class LightSensor {
    private let client: AnyObject?
    private let service: AnyObject?
    private static let ambientLightEvent: Int64 = 12

    init() {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue()
        if let client {
            _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 4] as CFDictionary)
            service = (IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject])?.first
        } else {
            service = nil
        }
    }

    var available: Bool { service != nil }

    /// Current illuminance in lux (the sensor sits next to the camera, so a closed lid reads ~0).
    func lux() -> Double? {
        guard let service, let event = IOHIDServiceClientCopyEvent(service, Self.ambientLightEvent, 0, 0)?.takeRetainedValue() else { return nil }
        return IOHIDEventGetFloatValue(event, Int32(Self.ambientLightEvent << 16))
    }
}
