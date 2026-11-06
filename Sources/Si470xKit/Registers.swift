import Foundation

/// Si470x register addresses (AN230). Each register is 16 bits, big-endian on the wire.
public enum Reg: Int, CaseIterable, Sendable {
    case deviceID = 0x00, chipID, powerCfg, channel, sysConfig1, sysConfig2, sysConfig3,
         test1, test2, bootConfig, statusRSSI, readChan, rdsA, rdsB, rdsC, rdsD

    public var name: String {
        ["DEVICEID", "CHIPID", "POWERCFG", "CHANNEL", "SYSCONFIG1", "SYSCONFIG2", "SYSCONFIG3",
         "TEST1", "TEST2", "BOOTCONFIG", "STATUSRSSI", "READCHAN", "RDSA", "RDSB", "RDSC", "RDSD"][rawValue]
    }
}

/// HID report IDs used by the SiLabs C8051F321 firmware.
public enum ReportID {
    /// Reports 1...16 carry one register each: report ID = register + 1, 3 bytes.
    public static func register(_ r: Reg) -> UInt8 { UInt8(r.rawValue + 1) }
    /// All 16 registers, 33 bytes.
    public static let entire: UInt8 = 17
    /// Interrupt input report with registers 0x0A–0x0F, 13 bytes, ~every 20 ms.
    public static let rds: UInt8 = 18
    /// Scratch page: byte 1 = SW version, byte 2 = HW version. 64 bytes.
    public static let scratch: UInt8 = 20
    // 19 = LED/stream command, 21–23 = bootloader / flash. Never written by this code.
}

public enum PowerCfg {
    public static let dsmute: UInt16 = 1 << 15
    public static let dmute: UInt16 = 1 << 14   // 1 = audio unmuted
    public static let mono: UInt16 = 1 << 13
    public static let rdsm: UInt16 = 1 << 11    // RDS verbose mode (Si4703 rev C+)
    public static let skmode: UInt16 = 1 << 10  // 1 = stop seeking at band limit
    public static let seekUp: UInt16 = 1 << 9
    public static let seek: UInt16 = 1 << 8
    public static let disable: UInt16 = 1 << 6
    public static let enable: UInt16 = 1 << 0
}

public enum ChannelReg {
    public static let tune: UInt16 = 1 << 15
    public static let chanMask: UInt16 = 0x03FF
}

public enum SysConfig1 {
    public static let rdsien: UInt16 = 1 << 15
    public static let stcien: UInt16 = 1 << 14
    public static let rds: UInt16 = 1 << 12
    public static let de50us: UInt16 = 1 << 11
}

public enum StatusRSSI {
    public static let rdsr: UInt16 = 1 << 15
    public static let stc: UInt16 = 1 << 14
    public static let sfbl: UInt16 = 1 << 13
    public static let afcrl: UInt16 = 1 << 12
    public static let rdss: UInt16 = 1 << 11
    public static let stereo: UInt16 = 1 << 8
    public static let rssiMask: UInt16 = 0x00FF
}

// MARK: - User-facing configuration

public enum Band: Int, CaseIterable, Codable, Sendable, Identifiable {
    case usEurope = 0    // 87.5–108 MHz
    case japanWide = 1   // 76–108 MHz
    case japan = 2       // 76–90 MHz

    public var id: Int { rawValue }
    public var bottomMHz: Double { self == .usEurope ? 87.5 : 76.0 }
    public var topMHz: Double { self == .japan ? 90.0 : 108.0 }
    public var label: String {
        switch self {
        case .usEurope: "87.5–108 MHz (USA, Europe)"
        case .japanWide: "76–108 MHz (Japan wide band)"
        case .japan: "76–90 MHz (Japan)"
        }
    }
}

public enum Spacing: Int, CaseIterable, Codable, Sendable, Identifiable {
    case khz200 = 0, khz100 = 1, khz50 = 2

    public var id: Int { rawValue }
    public var mhz: Double { [0.2, 0.1, 0.05][rawValue] }
    public var label: String {
        switch self {
        case .khz200: "200 kHz (USA)"
        case .khz100: "100 kHz (Europe, Japan)"
        case .khz50: "50 kHz"
        }
    }
}

public enum Deemphasis: Int, CaseIterable, Codable, Sendable, Identifiable {
    case us75 = 0, us50 = 1

    public var id: Int { rawValue }
    public var label: String {
        switch self {
        case .us75: "75 µs (USA, Japan)"
        case .us50: "50 µs (Europe, Australia)"
        }
    }
}

/// Tuner settings that are written to the chip.
public struct TunerConfig: Equatable, Sendable, Codable {
    public var band: Band = .usEurope
    public var spacing: Spacing = .khz200
    public var deemphasis: Deemphasis = .us75
    public var seekThreshold: Int = 15   // 0–63, SYSCONFIG2[15:8]
    public var forceMono: Bool = false

    public init() {}

    public func channel(for mhz: Double) -> Int {
        let ch = ((mhz - band.bottomMHz) / spacing.mhz).rounded()
        return max(0, min(maxChannel, Int(ch)))
    }

    public func frequency(for channel: Int) -> Double {
        band.bottomMHz + Double(channel) * spacing.mhz
    }

    public var maxChannel: Int {
        Int(((band.topMHz - band.bottomMHz) / spacing.mhz).rounded())
    }

    /// Snap an arbitrary frequency to the nearest valid channel frequency in the band.
    public func snap(_ mhz: Double) -> Double { frequency(for: channel(for: mhz)) }
}

extension UInt16 {
    @inlinable func has(_ bit: UInt16) -> Bool { self & bit != 0 }
}
