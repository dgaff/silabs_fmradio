import Foundation

/// Snapshot of registers 0x0A–0x0F (status, channel and RDS blocks).
public struct RadioStatus: Equatable, Sendable {
    public var statusRSSI: UInt16
    public var readChan: UInt16
    public var rds: (a: UInt16, b: UInt16, c: UInt16, d: UInt16)

    public init(statusRSSI: UInt16, readChan: UInt16, rds: (UInt16, UInt16, UInt16, UInt16)) {
        self.statusRSSI = statusRSSI
        self.readChan = readChan
        self.rds = rds
    }

    /// Parse registers 0x0A–0x0F from big-endian bytes (12 bytes).
    public init?(registerBytes b: ArraySlice<UInt8>) {
        guard b.count >= 12 else { return nil }
        let s = b.startIndex
        func w(_ i: Int) -> UInt16 { UInt16(b[s + 2 * i]) << 8 | UInt16(b[s + 2 * i + 1]) }
        self.init(statusRSSI: w(0), readChan: w(1), rds: (w(2), w(3), w(4), w(5)))
    }

    public var rssi: Int { Int(statusRSSI & StatusRSSI.rssiMask) }
    public var stereo: Bool { statusRSSI.has(StatusRSSI.stereo) }
    public var stc: Bool { statusRSSI.has(StatusRSSI.stc) }
    public var seekFailOrBandLimit: Bool { statusRSSI.has(StatusRSSI.sfbl) }
    public var rdsReady: Bool { statusRSSI.has(StatusRSSI.rdsr) }
    public var rdsSynchronized: Bool { statusRSSI.has(StatusRSSI.rdss) }
    public var channel: Int { Int(readChan & ChannelReg.chanMask) }

    /// Block error rates 0–3 for A, B, C, D (3 = uncorrectable).
    public var bler: (a: Int, b: Int, c: Int, d: Int) {
        (Int(statusRSSI >> 9) & 3, Int(readChan >> 14) & 3, Int(readChan >> 12) & 3, Int(readChan >> 10) & 3)
    }

    public static func == (l: RadioStatus, r: RadioStatus) -> Bool {
        l.statusRSSI == r.statusRSSI && l.readChan == r.readChan
            && l.rds.a == r.rds.a && l.rds.b == r.rds.b && l.rds.c == r.rds.c && l.rds.d == r.rds.d
    }
}

public enum Si470xError: Error, CustomStringConvertible {
    case shortReport(UInt8, Int)
    case timeout(String)
    case cancelled
    case unexpectedDevice(UInt16)

    public var description: String {
        switch self {
        case let .shortReport(id, n): "Report \(id) returned only \(n) bytes"
        case let .timeout(what): "Timed out waiting for \(what)"
        case .cancelled: "Cancelled"
        case let .unexpectedDevice(id): String(format: "Unexpected DEVICEID 0x%04X (expected MFGID 0x242)", id)
        }
    }
}

public struct SeekResult: Sendable {
    public var found: Bool
    public var channel: Int
    public var status: RadioStatus
}

/// Register-level driver for the Si470x behind the SiLabs USB radio firmware.
///
/// Not thread safe: call it from a single serial queue. All methods block on USB transfers.
public final class Si470x {
    public let transport: RadioTransport
    public private(set) var regs = [UInt16](repeating: 0, count: 16)
    public private(set) var config = TunerConfig()

    public init(transport: RadioTransport) {
        self.transport = transport
    }

    // MARK: Register access

    @discardableResult
    public func read(_ r: Reg) throws -> UInt16 {
        let d = try transport.getFeature(ReportID.register(r), length: 3)
        guard d.count >= 3 else { throw Si470xError.shortReport(ReportID.register(r), d.count) }
        regs[r.rawValue] = UInt16(d[1]) << 8 | UInt16(d[2])
        return regs[r.rawValue]
    }

    public func write(_ r: Reg, _ value: UInt16) throws {
        try transport.setFeature([ReportID.register(r), UInt8(value >> 8), UInt8(value & 0xFF)])
        regs[r.rawValue] = value
    }

    @discardableResult
    public func readAll() throws -> [UInt16] {
        let d = try transport.getFeature(ReportID.entire, length: 33)
        guard d.count >= 33 else { throw Si470xError.shortReport(ReportID.entire, d.count) }
        for i in 0..<16 { regs[i] = UInt16(d[1 + 2 * i]) << 8 | UInt16(d[2 + 2 * i]) }
        return regs
    }

    public func readStatus() throws -> RadioStatus {
        // Report 17 returns everything in one transfer; cheaper than six single-register reads.
        try readAll()
        return currentStatus
    }

    /// Status built from the register cache.
    public var currentStatus: RadioStatus {
        RadioStatus(statusRSSI: regs[Reg.statusRSSI.rawValue], readChan: regs[Reg.readChan.rawValue],
                    rds: (regs[Reg.rdsA.rawValue], regs[Reg.rdsB.rawValue], regs[Reg.rdsC.rawValue], regs[Reg.rdsD.rawValue]))
    }

    /// Update the register cache from an interrupt input report (ID 18). Returns the parsed status.
    @discardableResult
    public func ingestInputReport(_ bytes: [UInt8]) -> RadioStatus? {
        guard bytes.first == ReportID.rds, let st = RadioStatus(registerBytes: bytes[1...]) else { return nil }
        regs[Reg.statusRSSI.rawValue] = st.statusRSSI
        regs[Reg.readChan.rawValue] = st.readChan
        regs[Reg.rdsA.rawValue] = st.rds.a
        regs[Reg.rdsB.rawValue] = st.rds.b
        regs[Reg.rdsC.rawValue] = st.rds.c
        regs[Reg.rdsD.rawValue] = st.rds.d
        return st
    }

    // MARK: Identity

    public struct Identity: Sendable, CustomStringConvertible {
        public var deviceID: UInt16
        public var chipID: UInt16
        public var softwareVersion: Int?
        public var hardwareVersion: Int?

        public var partNumber: Int { Int(deviceID >> 12) }
        public var manufacturerID: Int { Int(deviceID & 0x0FFF) }
        public var revision: Int { Int(chipID >> 10) }
        public var device: Int { Int(chipID >> 6) & 0xF }
        public var firmware: Int { Int(chipID & 0x3F) }
        /// Si4703 (with RDS) reports DEV = 1 when powered up (AN230 Table 3).
        public var chipName: String {
            switch device {
            case 0: "Si4700"
            case 1: "Si4702"
            case 8: "Si4701"
            case 9: "Si4703"
            default: "Si470x"
            }
        }

        public var description: String {
            String(format: "DEVICEID 0x%04X (PN %d, MFGID 0x%03X), CHIPID 0x%04X (REV %d, DEV %d, FW %d)",
                   deviceID, partNumber, manufacturerID, chipID, revision, device, firmware)
                + (softwareVersion.map { ", USB SW v\($0)" } ?? "")
                + (hardwareVersion.map { " HW v\($0)" } ?? "")
        }
    }

    public func identify() throws -> Identity {
        try readAll()
        var id = Identity(deviceID: regs[Reg.deviceID.rawValue], chipID: regs[Reg.chipID.rawValue])
        if let scratch = try? transport.getFeature(ReportID.scratch, length: 64), scratch.count >= 3 {
            id.softwareVersion = Int(scratch[1])
            id.hardwareVersion = Int(scratch[2])
        }
        guard id.manufacturerID == 0x242 else { throw Si470xError.unexpectedDevice(id.deviceID) }
        return id
    }

    // MARK: Power and configuration

    public var isPoweredUp: Bool {
        let p = regs[Reg.powerCfg.rawValue]
        return p.has(PowerCfg.enable) && !p.has(PowerCfg.disable)
    }

    /// Power up (AN230 §2.5) and apply `config`. Chip volume is left at 15; volume is done in software.
    public func powerUp(config: TunerConfig) throws {
        try readAll()
        var p = regs[Reg.powerCfg.rawValue]
        let wasUp = isPoweredUp
        p = (p | PowerCfg.dmute | PowerCfg.enable) & ~PowerCfg.disable & ~PowerCfg.seek
        p = config.forceMono ? p | PowerCfg.mono : p & ~PowerCfg.mono
        try write(.powerCfg, p)
        if !wasUp { Thread.sleep(forTimeInterval: 0.11) }   // oscillator / power-up settle
        try apply(config: config)
    }

    /// Write band, spacing, de-emphasis, seek threshold and mono to the chip.
    public func apply(config: TunerConfig) throws {
        self.config = config
        var p = regs[Reg.powerCfg.rawValue]
        p = config.forceMono ? p | PowerCfg.mono : p & ~PowerCfg.mono
        if p != regs[Reg.powerCfg.rawValue] { try write(.powerCfg, p) }

        var s1 = try read(.sysConfig1)
        s1 |= SysConfig1.rds
        s1 = config.deemphasis == .us50 ? s1 | SysConfig1.de50us : s1 & ~SysConfig1.de50us
        try write(.sysConfig1, s1)

        let s2 = UInt16(clamping: config.seekThreshold & 0xFF) << 8
            | UInt16(config.band.rawValue) << 6
            | UInt16(config.spacing.rawValue) << 4
            | 0x000F
        try write(.sysConfig2, s2)
    }

    /// Power down (AN230 §2.6): ENABLE = 1 and DISABLE = 1 together.
    public func powerDown() throws {
        let s1 = regs[Reg.sysConfig1.rawValue] & ~SysConfig1.rds
        try? write(.sysConfig1, s1)
        let p = (regs[Reg.powerCfg.rawValue] & ~PowerCfg.seek & ~PowerCfg.dmute) | PowerCfg.enable | PowerCfg.disable
        try write(.powerCfg, p)
    }

    // MARK: Tuning

    /// Tune to a channel number and return the resulting status.
    @discardableResult
    public func tune(channel: Int, timeout: TimeInterval = 3) throws -> RadioStatus {
        let ch = UInt16(max(0, min(config.maxChannel, channel)))
        let c = (regs[Reg.channel.rawValue] & ~ChannelReg.chanMask & ~ChannelReg.tune) | ChannelReg.tune | ch
        try write(.channel, c)
        do {
            _ = try waitForSTC(true, timeout: timeout)
        } catch {
            try? write(.channel, regs[Reg.channel.rawValue] & ~ChannelReg.tune)
            throw error
        }
        try write(.channel, regs[Reg.channel.rawValue] & ~ChannelReg.tune)
        return try waitForSTC(false, timeout: 1)
    }

    @discardableResult
    public func tune(mhz: Double, timeout: TimeInterval = 3) throws -> RadioStatus {
        try tune(channel: config.channel(for: mhz), timeout: timeout)
    }

    /// Seek up or down, wrapping at band edges. `progress` gets each intermediate channel.
    public func seek(up: Bool, wrap: Bool = true, timeout: TimeInterval,
                     isCancelled: () -> Bool = { false },
                     progress: (Int) -> Void = { _ in }) throws -> SeekResult {
        var p = regs[Reg.powerCfg.rawValue] | PowerCfg.seek
        p = up ? p | PowerCfg.seekUp : p & ~PowerCfg.seekUp
        p = wrap ? p & ~PowerCfg.skmode : p | PowerCfg.skmode
        try write(.powerCfg, p)

        var cancelled = false
        do {
            _ = try waitForSTC(true, timeout: timeout, interval: 0.04) { st in
                progress(st.channel)
                if isCancelled() { cancelled = true; return true }
                return false
            }
        } catch Si470xError.timeout {
            // Fall through: clearing SEEK stops the seek wherever it is.
        } catch {
            try? write(.powerCfg, regs[Reg.powerCfg.rawValue] & ~PowerCfg.seek)
            throw error
        }
        let stcStatus = currentStatus
        try write(.powerCfg, regs[Reg.powerCfg.rawValue] & ~PowerCfg.seek)
        let st = try waitForSTC(false, timeout: 1)
        if cancelled { throw Si470xError.cancelled }
        let found = stcStatus.stc && !stcStatus.seekFailOrBandLimit
        return SeekResult(found: found, channel: st.channel, status: st)
    }

    /// Poll STATUSRSSI until STC equals `set`. `poll` may return true to stop early.
    private func waitForSTC(_ set: Bool, timeout: TimeInterval, interval: TimeInterval = 0.02,
                            poll: (RadioStatus) -> Bool = { _ in false }) throws -> RadioStatus {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let st = try readStatus()
            if st.stc == set { return st }
            if poll(st) { return st }
            if Date() > deadline { throw Si470xError.timeout(set ? "STC" : "STC to clear") }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    public func frequency(ofChannel ch: Int) -> Double { config.frequency(for: ch) }
}
