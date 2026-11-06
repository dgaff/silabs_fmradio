import Foundation
import Si470xKit
import os

struct NotConnectedError: Error, CustomStringConvertible {
    var description: String { "Radio not connected" }
}

/// Owns the Si470x and runs every USB register operation on one serial queue.
final class RadioWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fmradio.radio", qos: .userInitiated)
    private var chip: Si470x?           // only touched on `queue`
    private let cancelCounter = OSAllocatedUnfairLock(initialState: 0)

    func attach(_ transport: RadioTransport) {
        queue.async { self.chip = Si470x(transport: transport) }
    }

    func detach() {
        queue.async { self.chip = nil }
    }

    /// Ask any seek requested before this call to stop at its next poll.
    func cancelSeek() { cancelCounter.withLock { $0 += 1 } }

    /// Take a token when requesting a seek; it reports cancelled once `cancelSeek()` is called.
    func cancellationToken() -> @Sendable () -> Bool {
        let start = cancelCounter.withLock { $0 }
        return { [cancelCounter] in cancelCounter.withLock { $0 } != start }
    }

    /// Run `body` on the radio queue with the chip.
    func run<T: Sendable>(_ body: @escaping @Sendable (Si470x) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard let chip = self.chip else { return cont.resume(throwing: NotConnectedError()) }
                cont.resume(with: Result { try body(chip) })
            }
        }
    }

    /// Synchronous variant for app termination.
    func runSync(_ body: (Si470x) throws -> Void) {
        queue.sync {
            guard let chip = self.chip else { return }
            try? body(chip)
        }
    }
}

/// Turns the ~36/s interrupt reports into UI updates. Runs on the HID queue; the lock guards
/// state shared with the main thread (reset / suppress).
final class StatusProcessor: @unchecked Sendable {
    struct Update: Sendable {
        var rssi: Int
        var stereo: Bool
        var channel: Int
        var rds: RDSState?
    }

    private let lock = NSLock()
    private let decoder = RDSDecoder()
    private var suppressed = true
    private var last: (rssi: Int, stereo: Bool, channel: Int)?

    /// Stop reporting (during tune/seek) or resume with a fresh RDS state.
    func setSuppressed(_ on: Bool, ignoreABFlag: Bool) {
        lock.withLock {
            suppressed = on
            decoder.ignoreABFlag = ignoreABFlag
            decoder.reset()
            last = nil
        }
    }

    func setIgnoreABFlag(_ on: Bool) { lock.withLock { decoder.ignoreABFlag = on } }

    /// Returns an update when something visible changed.
    func handle(_ bytes: [UInt8]) -> Update? {
        guard bytes.first == ReportID.rds, let st = RadioStatus(registerBytes: bytes[1...]) else { return nil }
        return lock.withLock {
            guard !suppressed else { return nil }
            let rdsChanged = decoder.process(st)
            let now = (st.rssi, st.stereo, st.channel)
            let statusChanged = last.map { $0 != now } ?? true
            guard rdsChanged || statusChanged else { return nil }
            last = now
            return Update(rssi: st.rssi, stereo: st.stereo, channel: st.channel,
                          rds: rdsChanged ? decoder.state : nil)
        }
    }
}
