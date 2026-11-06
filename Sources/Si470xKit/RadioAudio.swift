import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// Plays the radio's USB audio input through the default output device.
///
/// Input: an AUHAL unit bound to the radio's Core Audio device (96 kHz stereo) writes into a
/// lock-free ring buffer. Output: an AVAudioEngine source node pulls from the ring through a
/// drift-compensating resampler into the main mixer, which provides volume and mute.
public final class RadioAudio: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case waitingForDevice
        case running(inputRate: Double, outputRate: Double)
        case failed(String)
    }

    /// Called on the main queue whenever `state` changes.
    public var onStateChange: ((State) -> Void)?
    public private(set) var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
            let s = state
            DispatchQueue.main.async { self.onStateChange?(s) }
        }
    }

    /// Linear 0...1 slider value; mapped to a perceptual gain curve.
    public var volume: Float = 0.8 { didSet { applyGain() } }
    public var muted = false { didSet { applyGain() } }

    /// Target latency of the input ring, in seconds.
    public var targetLatency: Double = 0.08

    private let queue = DispatchQueue(label: "fmradio.audio")
    /// HAL property listeners get their own queue: calling into the HAL from the queue it
    /// delivers notifications on can deadlock.
    private let listenerQueue = DispatchQueue(label: "fmradio.audio.listener")
    private var wanted = false
    private var deviceID: AudioDeviceID = 0
    private var inputUnit: AudioUnit?
    private var inputBuffers: UnsafeMutableAudioBufferListPointer?
    private let maxInputFrames = 8192
    private var ring: StereoRingBuffer?
    private var resampler: DriftCompensatingResampler?
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var configObserver: NSObjectProtocol?
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private let peakBits = Atomic<UInt32>(0)
    private let inputCallbacks = Atomic<Int>(0)

    public init() {}

    deinit {
        if let l = deviceListListener {
            var addr = Self.address(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, listenerQueue, l)
        }
    }

    // MARK: Public control

    /// Start playback, now or as soon as the radio's audio device appears.
    public func start() {
        queue.async {
            self.wanted = true
            self.installDeviceListListener()
            self.startIfPossible()
        }
    }

    public func stop() {
        queue.sync {
            self.wanted = false
            self.teardown()
            self.state = .stopped
        }
    }

    /// Restart the pipeline (e.g. after wake from sleep).
    public func restart() {
        queue.async {
            guard self.wanted else { return }
            self.teardown()
            self.startIfPossible()
        }
    }

    /// Peak input level since the last call (0...1). Useful for meters and diagnostics.
    public func takePeakLevel() -> Float {
        Float(bitPattern: peakBits.exchange(0, ordering: .relaxed))
    }

    public var inputCallbackCount: Int { inputCallbacks.load(ordering: .relaxed) }

    public var diagnostics: String {
        queue.sync {
            guard let r = resampler, let ring else { return "not running" }
            return String(format: "fill %d frames, correction %+.0f ppm, underruns %d",
                          ring.availableToRead, r.correctionPPM, r.underruns)
        }
    }

    // MARK: Device discovery

    /// Find the radio's Core Audio input device (model UID "FM Radio:10C4:818A").
    public static func findRadioDevice() -> AudioDeviceID? {
        let wanted = String(format: ":%04X:%04X", radioVendorID, radioProductID)
        for id in allDevices() where inputChannelCount(id) > 0 {
            if let model = stringProperty(id, kAudioDevicePropertyModelUID), model.uppercased().hasSuffix(wanted) {
                return id
            }
        }
        // Fallback: match by name.
        return allDevices().first { id in
            inputChannelCount(id) > 0 && (stringProperty(id, kAudioObjectPropertyName) ?? "") == "FM Radio"
        }
    }

    static func allDevices() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate)
        return rate
    }

    static func address(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func installDeviceListListener() {
        guard deviceListListener == nil else { return }
        let l: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.queue.async {
                guard let self, self.wanted else { return }
                let present = Self.findRadioDevice()
                if self.inputUnit != nil, present != self.deviceID {
                    self.teardown()   // our device went away
                }
                self.startIfPossible()
            }
        }
        var addr = Self.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, listenerQueue, l)
        deviceListListener = l
    }

    // MARK: Pipeline

    private func startIfPossible() {
        guard wanted, inputUnit == nil else { return }
        guard let dev = Self.findRadioDevice() else {
            state = .waitingForDevice
            return
        }
        do {
            try build(device: dev)
        } catch {
            teardown()
            state = .failed("\(error)")
        }
    }

    private struct OSStatusError: Error, CustomStringConvertible {
        let what: String, status: OSStatus
        var description: String { "\(what) failed (OSStatus \(status))" }
    }

    private func check(_ s: OSStatus, _ what: String) throws {
        if s != noErr { throw OSStatusError(what: what, status: s) }
    }

    private func build(device: AudioDeviceID) throws {
        deviceID = device
        let inRate = Self.nominalSampleRate(device) > 0 ? Self.nominalSampleRate(device) : 96000

        // --- Output side first, so we know the output rate.
        let engine = AVAudioEngine()
        let outRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard outRate > 0 else { throw OSStatusError(what: "No output device", status: -1) }
        let ring = StereoRingBuffer(capacityFrames: Int(inRate * 2))
        let resampler = DriftCompensatingResampler(ring: ring, inputRate: inRate, outputRate: outRate,
                                                   targetFill: Int(inRate * targetLatency))
        let fmt = AVAudioFormat(standardFormatWithSampleRate: outRate, channels: 2)!
        let source = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard list.count >= 2,
                  let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            resampler.render(left: l, right: r, frames: Int(frameCount))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: fmt)
        self.engine = engine
        self.sourceNode = source
        self.ring = ring
        self.resampler = resampler
        applyGain()

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // Output device or its rate changed; rebuild everything.
            self?.restart()
        }

        // --- Input side: AUHAL bound to the radio.
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw OSStatusError(what: "Find AUHAL", status: -1) }
        var unitOpt: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &unitOpt), "AudioComponentInstanceNew")
        guard let unit = unitOpt else { throw OSStatusError(what: "AUHAL instance", status: -1) }
        inputUnit = unit

        var one: UInt32 = 1, zero: UInt32 = 0
        let u32 = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, u32), "Enable input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, u32), "Disable output")
        var dev = device
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &dev, UInt32(MemoryLayout<AudioDeviceID>.size)), "Set input device")

        var client = AudioStreamBasicDescription(
            mSampleRate: inRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32,
            mReserved: 0)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Set client format")
        var maxFrames = UInt32(maxInputFrames)
        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, u32)

        let abl = AudioBufferList.allocate(maximumBuffers: 2)
        for i in 0..<2 {
            abl[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(maxInputFrames * 4),
                                 mData: UnsafeMutableRawPointer.allocate(byteCount: maxInputFrames * 4, alignment: 16))
        }
        inputBuffers = abl

        var cb = AURenderCallbackStruct(inputProc: { refCon, flags, ts, bus, frames, _ -> OSStatus in
            let me = Unmanaged<RadioAudio>.fromOpaque(refCon).takeUnretainedValue()
            return me.inputCallback(flags: flags, timeStamp: ts, bus: bus, frames: frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                       &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Set input callback")
        try check(AudioUnitInitialize(unit), "AudioUnitInitialize")

        try engine.start()
        try check(AudioOutputUnitStart(unit), "AudioOutputUnitStart")
        state = .running(inputRate: inRate, outputRate: outRate)
    }

    /// Real-time thread.
    private func inputCallback(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                               timeStamp: UnsafePointer<AudioTimeStamp>, bus: UInt32, frames: UInt32) -> OSStatus {
        guard let unit = inputUnit, let abl = inputBuffers, let ring, Int(frames) <= maxInputFrames else { return noErr }
        for i in 0..<2 { abl[i].mDataByteSize = frames * 4 }
        let s = AudioUnitRender(unit, flags, timeStamp, bus, frames, abl.unsafeMutablePointer)
        guard s == noErr,
              let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
              let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return s }
        ring.write(left: l, right: r, frames: Int(frames))
        inputCallbacks.add(1, ordering: .relaxed)

        var peak: Float = 0
        for i in 0..<Int(frames) { peak = max(peak, abs(l[i]), abs(r[i])) }
        let old = Float(bitPattern: peakBits.load(ordering: .relaxed))
        if peak > old { peakBits.store(peak.bitPattern, ordering: .relaxed) }
        return noErr
    }

    private func teardown() {
        if let unit = inputUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        inputUnit = nil
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        engine?.stop()
        if let s = sourceNode { engine?.detach(s) }
        engine = nil
        sourceNode = nil
        if let abl = inputBuffers {
            for b in abl { b.mData?.deallocate() }
            free(abl.unsafeMutablePointer)
        }
        inputBuffers = nil
        resampler = nil
        ring = nil
        deviceID = 0
        if wanted { state = .waitingForDevice }
    }

    private func applyGain() {
        let v = max(0, min(1, volume))
        let gain = muted ? 0 : v * v   // rough perceptual taper
        engine?.mainMixerNode.outputVolume = gain
    }
}
