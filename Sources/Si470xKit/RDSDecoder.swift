import Foundation

/// Everything decoded from RDS / RBDS so far for the current station.
public struct RDSState: Equatable, Sendable {
    public var pi: UInt16?
    public var pty: Int?
    public var trafficProgram = false
    public var trafficAnnouncement = false
    /// Program Service name (8 chars), empty until all four segments have been received.
    public var programService = ""
    /// Last complete RadioText message.
    public var radioText = ""
    /// Clock time from group 4A, in UTC.
    public var clockTime: Date?
    /// Local offset from group 4A, in minutes.
    public var clockOffsetMinutes: Int?
    public var groupsDecoded = 0

    public init() {}

    /// RBDS call letters derived from the PI code (US stations, PI 0x1000–0x9EFF).
    public var callLetters: String? {
        guard let pi else { return nil }
        return RDSDecoder.callLetters(fromPI: pi)
    }
}

/// Decodes RDS groups from Si470x RDSA–RDSD registers.
public final class RDSDecoder {
    public private(set) var state = RDSState()
    /// When true, a change of the RadioText A/B flag does not clear the text buffer.
    public var ignoreABFlag = false

    // Program Service name: two-pass validation (a char is accepted when received twice in a row).
    private var psCandidate = [UInt8](repeating: 0, count: 8)
    private var psCurrent = [UInt8](repeating: 0x20, count: 8)
    private var psSegmentsSeen: UInt8 = 0

    // RadioText
    private var rtBuffer = [UInt8](repeating: 0x20, count: 64)
    private var rtSegmentsSeen: UInt16 = 0
    private var rtCandidates = [[UInt8]?](repeating: nil, count: 16)
    private var rtABFlag: Bool?
    private var rtIsVersionB = false

    private var lastGroup: (UInt16, UInt16, UInt16, UInt16)?
    // PI / PTY validation. Rev B Si4701/03 chips have no verbose RDS mode, so block errors are
    // never reported and mis-corrected blocks get through. Require repeats before accepting.
    private var piCandidate: UInt16?
    private var piCandidateCount = 0
    private var ptyCandidate: Int?
    private var clockCandidate: (date: Date, offset: Int)?

    public init() {}

    public func reset() {
        state = RDSState()
        psCandidate = .init(repeating: 0, count: 8)
        psCurrent = .init(repeating: 0x20, count: 8)
        psSegmentsSeen = 0
        resetRadioTextBuffer()
        rtABFlag = nil
        lastGroup = nil
        piCandidate = nil
        piCandidateCount = 0
        ptyCandidate = nil
        clockCandidate = nil
    }

    private func resetRadioTextBuffer() {
        rtBuffer = .init(repeating: 0x20, count: 64)
        rtSegmentsSeen = 0
        rtCandidates = .init(repeating: nil, count: 16)
    }

    /// Feed one status snapshot. Returns true if `state` changed.
    @discardableResult
    public func process(_ st: RadioStatus) -> Bool {
        guard st.rdsReady else { return false }
        let g = st.rds
        // The firmware reports every ~20 ms and RDSR stays set for ~40 ms, so the same
        // group is usually seen twice. Ignore exact repeats.
        if let l = lastGroup, l == (g.a, g.b, g.c, g.d) { return false }
        lastGroup = (g.a, g.b, g.c, g.d)
        let bler = st.bler
        return process(a: bler.a < 3 ? g.a : nil, b: bler.b < 3 ? g.b : nil,
                       c: bler.c < 3 ? g.c : nil, d: bler.d < 3 ? g.d : nil)
    }

    /// Feed one group; pass nil for blocks with uncorrectable errors. Returns true if `state` changed.
    @discardableResult
    public func process(a: UInt16?, b: UInt16?, c: UInt16?, d: UInt16?) -> Bool {
        let before = state
        guard let b else {   // Block B identifies the group; nothing else is usable.
            if let a { _ = observePI(a) }
            return state != before
        }
        let versionB = b.has(1 << 11)
        // Version B groups repeat PI in block C.
        let piSeen = a ?? (versionB ? c : nil)
        if let piSeen, !observePI(piSeen) {
            return state != before   // Group doesn't belong to the established station: likely corrupt.
        }
        state.groupsDecoded += 1

        let groupType = Int(b >> 12)
        state.trafficProgram = b.has(1 << 10)
        let pty = Int(b >> 5) & 0x1F
        if pty == ptyCandidate { state.pty = pty }
        ptyCandidate = pty

        switch (groupType, versionB) {
        case (0, _):
            state.trafficAnnouncement = b.has(1 << 4)
            if let d { handlePS(segment: Int(b & 3), d: d) }
        case (2, _):
            handleRadioText(b: b, c: versionB ? nil : c, d: d, versionB: versionB)
        case (4, false):
            if let c, let d { handleClock(b: b, c: c, d: d) }
        default:
            break
        }
        return state != before
    }

    /// Track the PI code. Returns false if the group should be discarded.
    private func observePI(_ pi: UInt16) -> Bool {
        guard pi != 0 else { return false }
        if pi == state.pi {
            piCandidate = nil
            piCandidateCount = 0
            return true
        }
        if pi == piCandidate { piCandidateCount += 1 } else { piCandidate = pi; piCandidateCount = 1 }
        // First PI needs 2 matching receptions; changing an established PI needs 4.
        if piCandidateCount >= (state.pi == nil ? 2 : 4) {
            state.pi = pi
            piCandidate = nil
            piCandidateCount = 0
            return true
        }
        return state.pi == nil
    }

    // MARK: Group 0: Program Service name

    private func handlePS(segment: Int, d: UInt16) {
        let chars = [UInt8(d >> 8), UInt8(d & 0xFF)]
        let i = segment * 2
        // Two-pass validation: a segment is accepted when received identically twice in a row.
        let confirmed = psCandidate[i] == chars[0] && psCandidate[i + 1] == chars[1]
        psCandidate[i] = chars[0]
        psCandidate[i + 1] = chars[1]
        guard confirmed else { return }
        psCurrent[i] = chars[0]
        psCurrent[i + 1] = chars[1]
        // Publish only after all four segments have been (re)confirmed, so scrolling ("dynamic")
        // PS messages update as whole words rather than two characters at a time.
        psSegmentsSeen |= 1 << segment
        if psSegmentsSeen == 0xF {
            state.programService = Self.decodeText(psCurrent)
            psSegmentsSeen = 0
        }
    }

    // MARK: Group 2: RadioText

    private func handleRadioText(b: UInt16, c: UInt16?, d: UInt16?, versionB: Bool) {
        let ab = b.has(1 << 4)
        if versionB != rtIsVersionB {
            rtIsVersionB = versionB
            resetRadioTextBuffer()
        }
        if let prev = rtABFlag, prev != ab, !ignoreABFlag {
            resetRadioTextBuffer()
        }
        rtABFlag = ab

        let seg = Int(b & 0xF)
        let chars: [UInt8]
        if versionB {
            guard let d else { return }
            chars = [UInt8(d >> 8), UInt8(d & 0xFF)]
        } else {
            guard let c, let d else { return }   // Need the whole segment.
            chars = [UInt8(c >> 8), UInt8(c & 0xFF), UInt8(d >> 8), UInt8(d & 0xFF)]
        }
        // Two-pass validation per segment, as for PS.
        let confirmed = rtCandidates[seg] == chars
        rtCandidates[seg] = chars
        guard confirmed else { return }

        let width = chars.count
        for (k, ch) in chars.enumerated() { rtBuffer[seg * width + k] = ch }
        rtSegmentsSeen |= 1 << seg

        // Complete when every segment up to the one holding the terminator (or all of them) arrived.
        let capacity = versionB ? 32 : 64
        let end = rtBuffer[0..<capacity].firstIndex(of: 0x0D) ?? capacity
        let lastSeg = max(0, (end - 1) / width)
        let needed: UInt16 = lastSeg >= 15 ? 0xFFFF : UInt16((1 << (lastSeg + 1)) - 1)
        if rtSegmentsSeen & needed == needed {
            let text = Self.decodeText(Array(rtBuffer[0..<end]))
            if !text.isEmpty { state.radioText = text }
        }
    }

    // MARK: Group 4A: Clock time

    private func handleClock(b: UInt16, c: UInt16, d: UInt16) {
        let mjd = Int(b & 3) << 15 | Int(c >> 1)
        let hour = Int(c & 1) << 4 | Int(d >> 12)
        let minute = Int(d >> 6) & 0x3F
        let offset = (d.has(1 << 5) ? -1 : 1) * Int(d & 0x1F) * 30
        // MJD 51544 = 2000-01-01, 88069 = 2100-01-01. Anything outside is a corrupt group.
        guard (51544..<88069).contains(mjd), hour < 24, minute < 60, abs(offset) <= 14 * 60 else { return }
        // MJD 40587 = 1970-01-01.
        let date = Date(timeIntervalSince1970: TimeInterval((mjd - 40587) * 86400 + hour * 3600 + minute * 60))
        // CT is sent once a minute. Accept it when two consecutive receptions agree (0–3 min apart).
        defer { clockCandidate = (date, offset) }
        guard let prev = clockCandidate, prev.offset == offset,
              (0...180).contains(date.timeIntervalSince(prev.date)) else { return }
        state.clockTime = date
        state.clockOffsetMinutes = offset
    }

    // MARK: Helpers

    /// RDS uses its own character table (EN 50067 Annex E); the printable ASCII range matches it
    /// closely enough for station names and RadioText. Everything else becomes a space.
    static func decodeText(_ bytes: [UInt8]) -> String {
        let s = String(bytes.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : " " })
        return s.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
    }

    /// NRSC-4 call-letter decoding for US PI codes.
    public static func callLetters(fromPI pi: UInt16) -> String? {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var v = Int(pi)
        let prefix: Character
        if (4096...21671).contains(v) { prefix = "K"; v -= 4096 }
        else if (21672...39247).contains(v) { prefix = "W"; v -= 21672 }
        else { return nil }
        let a = v / 676, b = (v % 676) / 26, c = v % 26
        return String([prefix, letters[a], letters[b], letters[c]])
    }

    /// Program type names. RBDS (North America) and RDS (Europe) use different tables.
    public static func ptyName(_ pty: Int, rbds: Bool) -> String {
        let rds = ["None", "News", "Current Affairs", "Information", "Sport", "Education", "Drama", "Culture",
                   "Science", "Varied", "Pop Music", "Rock Music", "Easy Listening", "Light Classical",
                   "Serious Classical", "Other Music", "Weather", "Finance", "Children's", "Social Affairs",
                   "Religion", "Phone-In", "Travel", "Leisure", "Jazz Music", "Country Music", "National Music",
                   "Oldies Music", "Folk Music", "Documentary", "Alarm Test", "Alarm"]
        let rbdsNames = ["None", "News", "Information", "Sports", "Talk", "Rock", "Classic Rock", "Adult Hits",
                         "Soft Rock", "Top 40", "Country", "Oldies", "Soft", "Nostalgia", "Jazz", "Classical",
                         "R&B", "Soft R&B", "Language", "Religious Music", "Religious Talk", "Personality",
                         "Public", "College", "Spanish Talk", "Spanish Music", "Hip Hop", "Unassigned",
                         "Unassigned", "Weather", "Emergency Test", "Emergency"]
        let table = rbds ? rbdsNames : rds
        return (0..<32).contains(pty) ? table[pty] : "?"
    }
}
