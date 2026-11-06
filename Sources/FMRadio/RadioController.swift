import AppKit
import AVFoundation
import Foundation
import Observation
import Si470xKit
import os

let log = Logger(subsystem: "local.fmradio.FMRadio", category: "radio")

/// App-wide radio state and actions. Everything here runs on the main actor; USB work is
/// delegated to `RadioWorker`, interrupt reports to `StatusProcessor`.
@MainActor @Observable
final class RadioController {
    enum Connection: Equatable {
        case searching
        case connecting
        case connected(String)
        case failed(String)
    }

    enum Activity: Equatable {
        case idle, tuning, seeking, scanning
    }

    let settings: AppSettings

    private(set) var connection: Connection = .searching
    private(set) var activity: Activity = .idle
    private(set) var frequency: Double
    private(set) var rssi = 0
    private(set) var stereo = false
    private(set) var rds = RDSState()
    private(set) var audioState: RadioAudio.State = .stopped
    private(set) var microphoneDenied = false
    /// False while the user has paused playback. Pausing stops the audio pipeline entirely
    /// (unlike mute, which keeps it running at zero gain); the tuner stays on.
    private(set) var isPlaying = true
    private(set) var lastError: String?

    var volume: Double {
        didSet { audio.volume = Float(volume); settings.volume = volume }
    }
    var muted: Bool {
        didSet { audio.muted = muted; settings.muted = muted }
    }

    var isConnected: Bool { if case .connected = connection { true } else { false } }
    var isScanning: Bool { activity == .scanning }
    var tuner: TunerConfig { settings.tuner }

    /// Station name to display: RDS PS if known, else one remembered for this frequency.
    var stationName: String {
        if !rds.programService.isEmpty { return rds.programService }
        return settings.stationName(for: frequency) ?? ""
    }

    @ObservationIgnored private let monitor = HIDRadioMonitor()
    @ObservationIgnored private let worker = RadioWorker()
    @ObservationIgnored private let processor = StatusProcessor()
    @ObservationIgnored private let audio = RadioAudio()
    @ObservationIgnored private var device: HIDRadioDevice?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var opTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var psSince = Date()

    init(settings: AppSettings) {
        self.settings = settings
        frequency = settings.tuner.snap(settings.lastFrequency)
        volume = settings.volume
        muted = settings.muteOnStartup ? true : settings.muted
        audio.volume = Float(volume)
        audio.muted = muted

        audio.onStateChange = { [weak self] s in
            log.info("audio state: \(String(describing: s), privacy: .public)")
            MainActor.assumeIsolated { self?.audioState = s }
        }
        monitor.onAttach = { [weak self] dev in
            DispatchQueue.main.async { self?.deviceAttached(dev) }
        }
        monitor.onDetach = { [weak self] dev in
            DispatchQueue.main.async { self?.deviceDetached(dev) }
        }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
    }

    func start() {
        monitor.start()
        startAudio()
    }

    /// Called on quit: power the tuner down (AN230 §2.6) and stop audio.
    func shutdown() {
        scanTask?.cancel()
        worker.cancelSeek()
        audio.stop()
        worker.runSync { try $0.powerDown() }
    }

    // MARK: Device lifecycle

    private func deviceAttached(_ dev: HIDRadioDevice) {
        log.info("radio attached at location \(UInt32(truncatingIfNeeded: dev.locationID), format: .hex)")
        device = dev
        worker.attach(dev)
        let processor = self.processor
        dev.onInputReport = { [weak self] bytes in
            guard let update = processor.handle(bytes) else { return }
            DispatchQueue.main.async { self?.apply(update) }
        }
        initializeChip()
    }

    private func deviceDetached(_ dev: HIDRadioDevice) {
        guard dev === device else { return }
        log.info("radio detached")
        device = nil
        generation += 1
        scanTask?.cancel()
        worker.cancelSeek()
        worker.detach()
        processor.setSuppressed(true, ignoreABFlag: settings.ignoreABFlag)
        connection = .searching
        activity = .idle
        rssi = 0
        stereo = false
        rds = RDSState()
    }

    /// Identify, power up, configure and tune. Used on attach and after wake.
    private func initializeChip() {
        generation += 1
        let gen = generation
        connection = .connecting
        let config = settings.tuner
        let freq = frequency
        processor.setSuppressed(true, ignoreABFlag: settings.ignoreABFlag)
        Task {
            do {
                let ident = try await worker.run { chip -> Si470x.Identity in
                    let id = try chip.identify()
                    try chip.powerUp(config: config)
                    try chip.tune(mhz: freq)
                    return id
                }
                guard gen == generation else { return }
                log.info("radio initialized: \(ident.description, privacy: .public)")
                connection = .connected("\(ident.chipName) · USB firmware v\(ident.softwareVersion ?? 0)")
                lastError = nil
                processor.setSuppressed(false, ignoreABFlag: settings.ignoreABFlag)
            } catch {
                guard gen == generation else { return }
                log.error("radio init failed: \(String(describing: error), privacy: .public)")
                connection = .failed("\(error)")
            }
        }
    }

    private func willSleep() {
        log.info("system will sleep")
        sleeping = true
        scanTask?.cancel()
        worker.cancelSeek()
        audio.stop()
        processor.setSuppressed(true, ignoreABFlag: settings.ignoreABFlag)
        worker.runSync { try $0.powerDown() }
    }

    private func didWake() {
        guard sleeping else { return }
        log.info("system did wake")
        sleeping = false
        // The USB device may re-enumerate on wake, in which case attach handles it. Otherwise re-init.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            if self.device != nil { self.initializeChip() }
            if self.isPlaying { self.startAudio() }
        }
    }

    // MARK: Audio

    private func startAudio() {
        log.info("mic authorization: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneDenied = false
            audio.start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.microphoneDenied = !granted
                    if granted { self?.audio.start() }
                }
            }
        default:
            microphoneDenied = true
        }
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard !isPlaying else { return }
        isPlaying = true
        startAudio()
    }

    func pause() {
        guard isPlaying else { return }
        stopScan()
        isPlaying = false
        audio.stop()
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Status updates

    private func apply(_ u: StatusProcessor.Update) {
        guard activity == .idle || activity == .scanning else { return }
        rssi = u.rssi
        stereo = u.stereo
        if let r = u.rds {
            if r.programService != rds.programService { psSince = Date() }
            rds = r
            rememberStationName()
        }
    }

    /// Remember a name for preset labels. Many stations scroll text through the PS field, so
    /// prefer RBDS call letters (US) and otherwise only keep a PS that has been stable for 20 s.
    private func rememberStationName() {
        if let call = rds.callLetters, tuner.spacing == .khz200 {
            settings.remember(name: call, for: frequency)
        } else if !rds.programService.isEmpty, Date().timeIntervalSince(psSince) > 20 {
            settings.remember(name: rds.programService, for: frequency)
        }
    }

    // MARK: Tuning actions

    func tune(to mhz: Double) {
        stopScan()
        let target = tuner.snap(min(max(mhz, tuner.band.bottomMHz), tuner.band.topMHz))
        perform(.tuning) { worker in
            _ = try await worker.run { chip in try chip.tune(mhz: target) }
        }
    }

    /// Step one channel up or down, wrapping at the band edges.
    func step(up: Bool) {
        stopScan()
        let c = tuner
        var ch = c.channel(for: frequency) + (up ? 1 : -1)
        if ch > c.maxChannel { ch = 0 }
        if ch < 0 { ch = c.maxChannel }
        tune(to: c.frequency(for: ch))
    }

    func seek(up: Bool) {
        stopScan()
        perform(.seeking) { worker in
            _ = try await self.seekOnce(up: up, worker: worker)
        }
    }

    func toggleScan() {
        if isScanning { stopScan() } else { startScan() }
    }

    private func startScan() {
        guard isConnected else { return }
        worker.cancelSeek()
        let previous = opTask
        scanTask = Task {
            await previous?.value
            activity = .scanning
            defer { if activity == .scanning { activity = .idle } }
            let startFreq = frequency
            var lapped = false
            while !Task.isCancelled {
                do {
                    let before = frequency
                    rds = RDSState()
                    processor.setSuppressed(true, ignoreABFlag: settings.ignoreABFlag)
                    let found = try await seekOnce(up: true, worker: worker)
                    processor.setSuppressed(false, ignoreABFlag: settings.ignoreABFlag)
                    if !found || Task.isCancelled { break }
                    // Stop after one full lap of the band.
                    if frequency <= before { lapped = true }
                    if lapped && frequency >= startFreq { break }
                    try await Task.sleep(for: .seconds(settings.scanTime))
                } catch {
                    break
                }
            }
            processor.setSuppressed(false, ignoreABFlag: settings.ignoreABFlag)
        }
    }

    func stopScan() {
        guard scanTask != nil else { return }
        scanTask?.cancel()
        scanTask = nil
        worker.cancelSeek()
        if activity == .scanning { activity = .idle }
    }

    /// Returns true if a station was found.
    private func seekOnce(up: Bool, worker: RadioWorker) async throws -> Bool {
        let config = tuner
        let cancelled = worker.cancellationToken()
        let result = try await worker.run { [weak self] chip -> SeekResult in
            try chip.seek(up: up, wrap: true, timeout: 15, isCancelled: cancelled) { ch in
                let f = config.frequency(for: ch)
                DispatchQueue.main.async { self?.frequency = f }
            }
        }
        frequency = config.frequency(for: result.channel)
        rssi = result.status.rssi
        stereo = result.status.stereo
        settings.lastFrequency = frequency
        return result.found
    }

    func selectPreset(_ index: Int) {
        guard settings.presets.indices.contains(index), let f = settings.presets[index] else { return }
        tune(to: f)
    }

    func storePreset(_ index: Int) {
        guard settings.presets.indices.contains(index) else { return }
        settings.presets[index] = frequency
    }

    /// Index of the preset matching the current frequency.
    var currentPresetIndex: Int? {
        settings.presets.firstIndex { $0.map { abs($0 - frequency) < 0.001 } ?? false }
    }

    func stepPreset(forward: Bool) {
        let filled = settings.presets.enumerated().compactMap { i, f in f.map { (i, $0) } }
        guard !filled.isEmpty else { return }
        let sorted = filled.sorted { $0.1 < $1.1 }
        let next: (Int, Double)
        if forward {
            next = sorted.first { $0.1 > frequency + 0.001 } ?? sorted[0]
        } else {
            next = sorted.last { $0.1 < frequency - 0.001 } ?? sorted[sorted.count - 1]
        }
        tune(to: next.1)
    }

    /// Apply changed tuner settings to the chip and re-tune (the band or spacing may have changed).
    func applyTunerSettings() {
        let config = settings.tuner
        processor.setIgnoreABFlag(settings.ignoreABFlag)
        let target = config.snap(min(max(frequency, config.band.bottomMHz), config.band.topMHz))
        guard isConnected else { frequency = target; return }
        stopScan()
        perform(.tuning) { worker in
            _ = try await worker.run { chip in
                try chip.apply(config: config)
                return try chip.tune(mhz: target)
            }
        }
    }

    /// Run a tune-like operation: suppress status during it, then refresh state from the result.
    private func perform(_ kind: Activity, _ op: @escaping (RadioWorker) async throws -> Void) {
        guard isConnected else { return }
        worker.cancelSeek()
        let previous = opTask
        opTask = Task {
            await previous?.value   // operations run in order
            activity = kind
            rds = RDSState()
            processor.setSuppressed(true, ignoreABFlag: settings.ignoreABFlag)
            do {
                try await op(worker)
                let st = try await worker.run { chip in try chip.readStatus() }
                frequency = tuner.frequency(for: st.channel)
                rssi = st.rssi
                stereo = st.stereo
                settings.lastFrequency = frequency
                lastError = nil
            } catch Si470xError.cancelled {
                // Superseded by another action.
            } catch {
                lastError = "\(error)"
            }
            processor.setSuppressed(false, ignoreABFlag: settings.ignoreABFlag)
            if activity == kind { activity = .idle }
        }
    }

    // MARK: Display helpers

    func format(_ mhz: Double) -> String {
        tuner.spacing == .khz50 ? String(format: "%.2f", mhz) : String(format: "%.1f", mhz)
    }

    var programTypeName: String? {
        guard let p = rds.pty, p != 0 else { return nil }
        return RDSDecoder.ptyName(p, rbds: tuner.spacing == .khz200)
    }

    /// Station clock time (group 4A) shown in the station's local time.
    var stationClock: String? {
        guard let t = rds.clockTime, let off = rds.clockOffsetMinutes,
              let tz = TimeZone(secondsFromGMT: off * 60) else { return nil }
        let f = DateFormatter()
        f.timeZone = tz
        f.timeStyle = .short
        return f.string(from: t)
    }
}
