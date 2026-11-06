import Foundation
import IOKit
import IOKit.hid

public let radioVendorID = 0x10C4
public let radioProductID = 0x818A

public struct HIDError: Error, CustomStringConvertible {
    public let operation: String
    public let code: IOReturn
    public var description: String { "\(operation) failed: IOReturn 0x\(String(UInt32(bitPattern: code), radix: 16))" }
}

/// Minimal transport for Si470x register access, so the radio logic can be tested without hardware.
public protocol RadioTransport: AnyObject {
    /// GET_REPORT (feature). Returned buffer starts with the report ID.
    func getFeature(_ reportID: UInt8, length: Int) throws -> [UInt8]
    /// SET_REPORT (feature). `bytes[0]` is the report ID.
    func setFeature(_ bytes: [UInt8]) throws
}

/// One opened SiLabs FM radio HID interface.
public final class HIDRadioDevice: RadioTransport, @unchecked Sendable {
    public let device: IOHIDDevice
    /// Called on the HID queue for every input report (report 18, 13 bytes including the ID).
    public var onInputReport: (([UInt8]) -> Void)?

    init(device: IOHIDDevice) {
        self.device = device
    }

    func deliver(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: Int) {
        guard let cb = onInputReport else { return }
        var bytes = Array(UnsafeBufferPointer(start: report, count: length))
        // Numbered reports normally include the ID byte; normalize in case they don't.
        if bytes.first != UInt8(truncatingIfNeeded: reportID) {
            bytes.insert(UInt8(truncatingIfNeeded: reportID), at: 0)
        }
        cb(bytes)
    }

    public var locationID: Int {
        (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.intValue ?? 0
    }

    public func getFeature(_ reportID: UInt8, length: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: length)
        buf[0] = reportID
        var len = CFIndex(length)
        let r = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), &buf, &len)
        guard r == kIOReturnSuccess else { throw HIDError(operation: "GET_REPORT \(reportID)", code: r) }
        return Array(buf.prefix(Int(len)))
    }

    public func setFeature(_ bytes: [UInt8]) throws {
        let r = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(bytes[0]), bytes, bytes.count)
        guard r == kIOReturnSuccess else { throw HIDError(operation: "SET_REPORT \(bytes[0])", code: r) }
    }
}

/// Watches for the radio's HID interface being attached and removed.
public final class HIDRadioMonitor: @unchecked Sendable {
    private let manager: IOHIDManager
    private let queue = DispatchQueue(label: "fmradio.hid")
    private var devices: [IOHIDDevice: HIDRadioDevice] = [:]

    /// Called on the HID queue.
    public var onAttach: ((HIDRadioDevice) -> Void)?
    /// Called on the HID queue.
    public var onDetach: ((HIDRadioDevice) -> Void)?

    public init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: radioVendorID,
            kIOHIDProductIDKey: radioProductID,
        ] as CFDictionary)
    }

    /// The queue on which attach/detach and input-report callbacks run.
    public var callbackQueue: DispatchQueue { queue }

    public func start() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<HIDRadioMonitor>.fromOpaque(ctx).takeUnretainedValue().attached(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<HIDRadioMonitor>.fromOpaque(ctx).takeUnretainedValue().removed(device)
        }, ctx)
        // Per-device input callbacks can't be registered after activation, so register one on the
        // manager (before activation) and route reports to the matching device.
        IOHIDManagerRegisterInputReportCallback(manager, { ctx, result, sender, _, reportID, report, length in
            guard let ctx, let sender, result == kIOReturnSuccess else { return }
            let me = Unmanaged<HIDRadioMonitor>.fromOpaque(ctx).takeUnretainedValue()
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            me.devices[device]?.deliver(reportID: reportID, report: report, length: length)
        }, ctx)
        IOHIDManagerSetDispatchQueue(manager, queue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerActivate(manager)
    }

    private func attached(_ device: IOHIDDevice) {
        guard devices[device] == nil else { return }
        let d = HIDRadioDevice(device: device)
        devices[device] = d
        onAttach?(d)
    }

    private func removed(_ device: IOHIDDevice) {
        guard let d = devices.removeValue(forKey: device) else { return }
        d.onInputReport = nil
        onDetach?(d)
    }
}
