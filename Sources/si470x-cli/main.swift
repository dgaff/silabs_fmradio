import Foundation
import Si470xKit

// Small hardware test tool, the Swift counterpart of tools/si470x_probe.py.
//
//   si470x-cli info                 identify the radio and dump registers
//   si470x-cli tune 90.9 [secs]     power up, tune, then watch status + RDS (default 10 s)
//   si470x-cli seek up|down         seek from the current channel
//   si470x-cli play 90.9 [secs]     tune and play audio through the default output (default 10 s)
//   si470x-cli off                  power the tuner down

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "info"

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

// --- Open the device
let monitor = HIDRadioMonitor()
let attached = DispatchSemaphore(value: 0)
var hidDevice: HIDRadioDevice?
monitor.onAttach = { d in
    hidDevice = d
    attached.signal()
}
monitor.start()
guard attached.wait(timeout: .now() + 3) == .success, let dev = hidDevice else {
    fail("Radio 10C4:818A not found")
}
print(String(format: "Opened HID device at location 0x%08X", dev.locationID))

let radio = Si470x(transport: dev)
var config = TunerConfig()
if args.contains("--mono") { config.forceMono = true }

func describe(_ st: RadioStatus) -> String {
    String(format: "%6.2f MHz  RSSI %3d dBµV  %@  STC=%d SF/BL=%d RDSS=%d RDSR=%d",
           config.frequency(for: st.channel), st.rssi, st.stereo ? "STEREO" : "mono  ",
           st.stc ? 1 : 0, st.seekFailOrBandLimit ? 1 : 0, st.rdsSynchronized ? 1 : 0, st.rdsReady ? 1 : 0)
}

func dumpRegisters() {
    for r in Reg.allCases {
        let v = radio.regs[r.rawValue]
        let bits = String(v, radix: 2)
        print(String(format: "  0x%02X ", r.rawValue) + r.name.padding(toLength: 11, withPad: " ", startingAt: 0) + String(format: " 0x%04X  ", v)
              + String(repeating: "0", count: 16 - bits.count) + bits)
    }
}

/// Watch input reports for `seconds`, printing status once a second and RDS changes as they happen.
func watch(seconds: Double, audio: RadioAudio? = nil) {
    let rds = RDSDecoder()
    let lock = NSLock()
    var latest: RadioStatus?
    var reports = 0
    var lastRDS = RDSState()
    dev.onInputReport = { bytes in
        guard bytes.first == ReportID.rds, let st = RadioStatus(registerBytes: bytes[1...]) else { return }
        lock.lock(); defer { lock.unlock() }
        reports += 1
        latest = st
        if rds.process(st) {
            let s = rds.state
            if s.programService != lastRDS.programService { print("  PS: [\(s.programService)]") }
            if s.radioText != lastRDS.radioText { print("  RT: \(s.radioText)") }
            if s.pi != lastRDS.pi, let pi = s.pi {
                print(String(format: "  PI: 0x%04X %@", pi, s.callLetters ?? ""))
            }
            if s.pty != lastRDS.pty, let p = s.pty { print("  PTY: \(p) \(RDSDecoder.ptyName(p, rbds: true))") }
            if s.clockTime != lastRDS.clockTime, let t = s.clockTime {
                print("  CT: \(t) (offset \(s.clockOffsetMinutes ?? 0) min)")
            }
            lastRDS = s
        }
    }
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        lock.lock()
        let st = latest, n = reports
        reports = 0
        lock.unlock()
        var line = st.map(describe) ?? "no input reports"
        line += "  [\(n) reports/s]"
        if let audio {
            line += String(format: "  peak %.3f  ", audio.takePeakLevel()) + audio.diagnostics
        }
        print(line)
    }
    dev.onInputReport = nil
    print("  groups decoded: \(rds.state.groupsDecoded)")
}

do {
    let id = try radio.identify()
    print("Identity: \(id)  → \(id.chipName)")

    switch command {
    case "info":
        dumpRegisters()

    case "tune", "play":
        guard args.count >= 2, let mhz = Double(args[1]) else { fail("usage: \(command) <MHz> [seconds]") }
        let secs = args.count >= 3 ? Double(args[2]) ?? 10 : 10
        try radio.powerUp(config: config)
        let t0 = Date()
        let st = try radio.tune(mhz: mhz)
        print(String(format: "Tuned in %.0f ms: ", Date().timeIntervalSince(t0) * 1000) + describe(st))
        var audio: RadioAudio?
        if command == "play" {
            let a = RadioAudio()
            a.onStateChange = { print("  audio: \($0)") }
            a.volume = args.contains("--quiet") ? 0.3 : 0.8
            a.start()
            audio = a
        }
        watch(seconds: secs, audio: audio)
        audio?.stop()

    case "seek":
        let up = args.count < 2 || args[1] != "down"
        try radio.powerUp(config: config)
        try radio.readAll()
        let from = Int(radio.regs[Reg.readChan.rawValue] & ChannelReg.chanMask)
        print(String(format: "Seeking %@ from %.2f MHz", up ? "up" : "down", config.frequency(for: from)))
        let t0 = Date()
        let r = try radio.seek(up: up, timeout: 8) { ch in
            print(String(format: "\r  … %.2f", config.frequency(for: ch)), terminator: "")
        }
        print(String(format: "\n%@ in %.1f s: ", r.found ? "Found" : "Not found", Date().timeIntervalSince(t0))
              + describe(r.status))

    case "off":
        try radio.readAll()
        try radio.powerDown()
        print("Powered down")

    default:
        fail("unknown command \(command)")
    }
} catch {
    fail("Error: \(error)")
}
