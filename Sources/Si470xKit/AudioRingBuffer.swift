import Foundation
import Synchronization

/// Single-producer / single-consumer ring buffer of interleaved stereo Float32 frames.
/// Lock-free and allocation-free after init, so it's safe on real-time audio threads.
final class StereoRingBuffer: @unchecked Sendable {
    let capacity: Int   // frames
    private let data: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)   // total frames ever written
    private let readIndex = Atomic<Int>(0)    // total frames ever read

    init(capacityFrames: Int) {
        capacity = capacityFrames
        data = .allocate(capacity: capacityFrames * 2)
        data.initialize(repeating: 0, count: capacityFrames * 2)
    }

    deinit { data.deallocate() }

    var availableToRead: Int { writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .relaxed) }

    /// Producer: append frames from non-interleaved channel buffers. Returns frames written.
    @discardableResult
    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) -> Int {
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let n = min(frames, capacity - (w - r))
        guard n > 0 else { return 0 }
        for i in 0..<n {
            let slot = ((w + i) % capacity) * 2
            data[slot] = left[i]
            data[slot + 1] = right[i]
        }
        writeIndex.store(w + n, ordering: .releasing)
        return n
    }

    /// Consumer: read frame `offset` frames past the read index without consuming it.
    @inline(__always)
    func peek(_ offset: Int, base: Int) -> (Float, Float) {
        let slot = ((base + offset) % capacity) * 2
        return (data[slot], data[slot + 1])
    }

    /// Consumer: current read index (pass to `peek` as `base`).
    var readBase: Int { readIndex.load(ordering: .relaxed) }

    /// Consumer: mark frames as consumed.
    func advance(_ frames: Int) {
        readIndex.store(readIndex.load(ordering: .relaxed) + frames, ordering: .releasing)
    }

    /// Consumer: drop everything except the newest `keep` frames.
    func discard(keeping keep: Int) {
        let avail = availableToRead
        if avail > keep { advance(avail - keep) }
    }
}

/// Pulls stereo audio from a ring buffer at one rate and produces it at another, nudging the
/// ratio to hold the buffer near a target fill level. That absorbs the clock drift between the
/// radio's USB audio clock and the Mac's output device. Only touched from the render thread.
final class DriftCompensatingResampler {
    let ring: StereoRingBuffer
    var inputRate: Double
    var outputRate: Double
    /// Target latency held in the ring, in input frames.
    var targetFill: Int

    private var frac: Double = 0
    private var prev: (Float, Float) = (0, 0)
    private var smoothedFill: Double = 0
    private var priming = true
    private(set) var underruns = 0
    private(set) var correctionPPM: Double = 0

    init(ring: StereoRingBuffer, inputRate: Double, outputRate: Double, targetFill: Int) {
        self.ring = ring
        self.inputRate = inputRate
        self.outputRate = outputRate
        self.targetFill = targetFill
        smoothedFill = Double(targetFill)
    }

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        var avail = ring.availableToRead

        if priming {
            if avail < targetFill {
                for i in 0..<frames { left[i] = 0; right[i] = 0 }
                return
            }
            priming = false
            smoothedFill = Double(avail)
        }
        // Way too much buffered (e.g. after a stall): jump back to the target.
        if avail > targetFill * 4 {
            ring.discard(keeping: targetFill)
            avail = ring.availableToRead
            smoothedFill = Double(avail)
        }

        smoothedFill += (Double(avail) - smoothedFill) * 0.02
        let error = (smoothedFill - Double(targetFill)) / Double(targetFill)
        let correction = max(-0.005, min(0.005, error * 0.004))
        correctionPPM = correction * 1_000_000
        let step = inputRate / outputRate * (1 + correction)

        var base = ring.readBase
        var consumed = 0
        var x0 = ring.peek(0, base: base)
        var x1 = ring.peek(1, base: base)
        var x2 = ring.peek(2, base: base)
        for i in 0..<frames {
            if avail - consumed < 3 {
                // Underrun: fade to silence and re-prime.
                for j in i..<frames { left[j] = 0; right[j] = 0 }
                underruns += 1
                priming = true
                break
            }
            let t = Float(frac)
            left[i] = Self.hermite(prev.0, x0.0, x1.0, x2.0, t)
            right[i] = Self.hermite(prev.1, x0.1, x1.1, x2.1, t)
            frac += step
            while frac >= 1 {
                frac -= 1
                prev = x0
                x0 = x1
                x1 = x2
                consumed += 1
                base += 1
                x2 = ring.peek(2, base: base)
            }
        }
        ring.advance(consumed)
    }

    @inline(__always)
    static func hermite(_ xm1: Float, _ x0: Float, _ x1: Float, _ x2: Float, _ t: Float) -> Float {
        let c0 = x0
        let c1 = 0.5 * (x1 - xm1)
        let c2 = xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2
        let c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
        return ((c3 * t + c2) * t + c1) * t + c0
    }
}
