import Testing
@testable import Si470xKit

struct RDSDecoderTests {
    /// Build a group 0A block B for segment `seg`.
    func g0B(seg: UInt16, pty: UInt16 = 10, tp: Bool = false) -> UInt16 {
        (0 << 12) | (tp ? 1 << 10 : 0) | (pty << 5) | seg
    }

    func chars(_ s: String) -> UInt16 {
        let b = Array(s.utf8)
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }

    func sendPS(_ d: RDSDecoder, _ name: String, times: Int = 2) {
        let padded = Array(name.padding(toLength: 8, withPad: " ", startingAt: 0))
        for _ in 0..<times {
            for seg in 0..<4 {
                d.process(a: 0x54A6, b: g0B(seg: UInt16(seg)), c: 0, d: chars(String(padded[seg * 2...seg * 2 + 1])))
            }
        }
    }

    @Test func programServiceNeedsTwoPasses() {
        let d = RDSDecoder()
        sendPS(d, "KQED FM", times: 1)
        #expect(d.state.programService == "")
        sendPS(d, "KQED FM", times: 1)
        #expect(d.state.programService == "KQED FM")
        #expect(d.state.pi == 0x54A6)
        // A one-off corrupted PI is ignored, and so is the rest of that group.
        d.process(a: 0x54A7, b: g0B(seg: 0, pty: 3), c: 0, d: chars("XX"))
        #expect(d.state.pi == 0x54A6)
        #expect(d.state.programService == "KQED FM")
        #expect(d.state.pty == 10)
    }

    @Test func corruptBlockDIgnored() {
        let d = RDSDecoder()
        sendPS(d, "SLAB")
        d.process(a: nil, b: g0B(seg: 0), c: nil, d: nil)
        #expect(d.state.programService == "SLAB")
    }

    func rt2A(_ d: RDSDecoder, _ text: String, ab: Bool = false) {
        rt2AOnce(d, text, ab: ab)
        rt2AOnce(d, text, ab: ab)
    }

    func rt2AOnce(_ d: RDSDecoder, _ text: String, ab: Bool = false) {
        var bytes = Array(text.utf8)
        if bytes.count < 64 { bytes.append(0x0D) }
        while bytes.count % 4 != 0 { bytes.append(0x20) }
        for seg in 0..<(bytes.count / 4) {
            let b = UInt16(2 << 12) | (ab ? 1 << 4 : 0) | UInt16(seg)
            let c = UInt16(bytes[seg * 4]) << 8 | UInt16(bytes[seg * 4 + 1])
            let dd = UInt16(bytes[seg * 4 + 2]) << 8 | UInt16(bytes[seg * 4 + 3])
            d.process(a: 0x1234, b: b, c: c, d: dd)
        }
    }

    @Test func radioTextWithTerminator() {
        let d = RDSDecoder()
        rt2AOnce(d, "Now playing: Something")
        #expect(d.state.radioText == "")
        rt2AOnce(d, "Now playing: Something")
        #expect(d.state.radioText == "Now playing: Something")
    }

    @Test func abFlagClearsBuffer() {
        let d = RDSDecoder()
        rt2A(d, "First message here")
        // Flip A/B and send only the first segment of a new message: old text stays displayed
        // until the new message is complete, but the old buffer must not leak into it.
        let b = UInt16(2 << 12) | (1 << 4) | 1   // segment 1 only
        d.process(a: 0x1234, b: b, c: 0x4142, d: 0x0D20)
        #expect(d.state.radioText == "First message here")
        rt2A(d, "Second", ab: true)
        #expect(d.state.radioText == "Second")
    }

    @Test func clockTime() {
        // 2024-01-01 12:30 UTC → MJD 60310, offset -5 h (-10 half hours).
        let mjd = 60310
        let b = UInt16(4 << 12) | UInt16(mjd >> 15)
        let c = UInt16((mjd & 0x7FFF) << 1) | UInt16(12 >> 4)
        let dd = UInt16((12 & 0xF) << 12) | UInt16(30 << 6) | (1 << 5) | 10
        let d = RDSDecoder()
        d.process(a: 0x1234, b: b, c: c, d: dd)
        d.process(a: 0x1234, b: b, c: c, d: dd)
        #expect(d.state.clockTime?.timeIntervalSince1970 == 1704112200)
        #expect(d.state.clockOffsetMinutes == -300)
    }

    @Test func callLetters() {
        #expect(RDSDecoder.callLetters(fromPI: 0x3AAB) == "KQED")
        #expect(RDSDecoder.callLetters(fromPI: 4096) == "KAAA")
        #expect(RDSDecoder.callLetters(fromPI: 21672) == "WAAA")
    }

    @Test func tunerChannelMath() {
        var c = TunerConfig()
        #expect(c.channel(for: 90.9) == 17)
        #expect(abs(c.frequency(for: 17) - 90.9) < 1e-9)
        #expect(c.maxChannel == 103)
        c.spacing = .khz100
        c.band = .japan
        #expect(c.channel(for: 80.0) == 40)
    }

    @Test func resamplerTracksTargetFill() {
        let ring = StereoRingBuffer(capacityFrames: 96000)
        let r = DriftCompensatingResampler(ring: ring, inputRate: 96000, outputRate: 48000, targetFill: 4800)
        var l = [Float](repeating: 0.5, count: 1024), rr = l
        // Feed 96 kHz worth of input in 960-frame chunks while pulling 480-frame output chunks.
        var outL = [Float](repeating: 0, count: 480), outR = outL
        for _ in 0..<1000 {
            ring.write(left: &l, right: &rr, frames: 960)
            r.render(left: &outL, right: &outR, frames: 480)
        }
        #expect(r.underruns == 0)
        #expect(abs(outL[100] - 0.5) < 1e-4)
        #expect(abs(ring.availableToRead - 4800) < 1500)
    }
}
