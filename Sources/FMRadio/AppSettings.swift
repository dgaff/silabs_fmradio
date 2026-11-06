import Foundation
import Observation
import Si470xKit

/// User preferences, persisted in UserDefaults. Mirrors the Windows settings dialog.
@MainActor @Observable
final class AppSettings {
    static let defaultPresets: [Double] = [90.9, 92.1, 93.3, 93.7, 94.7, 96.7, 100.7, 101.5, 102.3, 103.5, 105.9, 107.1]

    private let defaults: UserDefaults

    var tuner: TunerConfig { didSet { save(tuner, "tuner") } }
    /// Seconds each station plays during Scan (1–15).
    var scanTime: Double { didSet { defaults.set(scanTime, forKey: "scanTime") } }
    var muteOnStartup: Bool { didSet { defaults.set(muteOnStartup, forKey: "muteOnStartup") } }
    var showInMenuBar: Bool { didSet { defaults.set(showInMenuBar, forKey: "showInMenuBar") } }
    var ignoreABFlag: Bool { didSet { defaults.set(ignoreABFlag, forKey: "ignoreABFlag") } }
    /// 12 preset frequencies in MHz; nil = empty slot.
    var presets: [Double?] { didSet { save(presets, "presets") } }
    var volume: Double { didSet { defaults.set(volume, forKey: "volume") } }
    var muted: Bool { didSet { defaults.set(muted, forKey: "muted") } }
    var lastFrequency: Double { didSet { defaults.set(lastFrequency, forKey: "lastFrequency") } }
    /// Station names learned from RDS, keyed by frequency ("90.90").
    var stationNames: [String: String] { didSet { save(stationNames, "stationNames") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tuner = Self.load(TunerConfig.self, "tuner", defaults) ?? TunerConfig()
        scanTime = defaults.object(forKey: "scanTime") as? Double ?? 8
        muteOnStartup = defaults.bool(forKey: "muteOnStartup")
        showInMenuBar = defaults.object(forKey: "showInMenuBar") as? Bool ?? true
        ignoreABFlag = defaults.bool(forKey: "ignoreABFlag")
        presets = Self.load([Double?].self, "presets", defaults) ?? Self.defaultPresets
        volume = defaults.object(forKey: "volume") as? Double ?? 0.7
        muted = defaults.bool(forKey: "muted")
        lastFrequency = defaults.object(forKey: "lastFrequency") as? Double ?? Self.defaultPresets[0]
        stationNames = Self.load([String: String].self, "stationNames", defaults) ?? [:]
        if presets.count != 12 { presets = Array((presets + Array(repeating: nil, count: 12)).prefix(12)) }
    }

    func stationName(for mhz: Double) -> String? { stationNames[Self.key(mhz)] }

    func remember(name: String, for mhz: Double) {
        let k = Self.key(mhz)
        if stationNames[k] != name { stationNames[k] = name }
    }

    static func key(_ mhz: Double) -> String { String(format: "%.2f", mhz) }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, _ d: UserDefaults) -> T? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
