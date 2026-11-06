import Si470xKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            RadioSettingsTab()
                .tabItem { Label("Radio", systemImage: "antenna.radiowaves.left.and.right") }
            PresetsSettingsTab()
                .tabItem { Label("Presets", systemImage: "list.number") }
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 500)
    }
}

private struct RadioSettingsTab: View {
    @Environment(RadioController.self) private var radio

    var body: some View {
        @Bindable var settings = radio.settings
        Form {
            Section {
                Picker("Band", selection: $settings.tuner.band) {
                    ForEach(Band.allCases) { Text($0.label).tag($0) }
                }
                Picker("Channel spacing", selection: $settings.tuner.spacing) {
                    ForEach(Spacing.allCases) { Text($0.label).tag($0) }
                }
                Picker("De-emphasis", selection: $settings.tuner.deemphasis) {
                    ForEach(Deemphasis.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Force mono", isOn: $settings.tuner.forceMono)
            }
            Section {
                LabeledContent("Seek threshold") {
                    HStack {
                        Slider(value: Binding(get: { Double(settings.tuner.seekThreshold) },
                                              set: { settings.tuner.seekThreshold = Int($0.rounded()) }),
                               in: 0...63)
                        Text("\(settings.tuner.seekThreshold)").monospacedDigit().frame(width: 24, alignment: .trailing)
                    }
                }
                Text("Minimum signal (RSSI) for seek to stop on a station. Lower finds weaker stations.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Scan time") {
                    HStack {
                        Slider(value: $settings.scanTime, in: 1...15, step: 1)
                        Text("\(Int(settings.scanTime)) s").monospacedDigit().frame(width: 34, alignment: .trailing)
                    }
                }
                Text("How long Scan plays each station before moving on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("RDS / RBDS") {
                Toggle("Ignore RadioText A/B flag", isOn: $settings.ignoreABFlag)
                Text("Some stations toggle the A/B flag incorrectly, which clears RadioText too often.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 540)
        .onChange(of: settings.tuner) { radio.applyTunerSettings() }
        .onChange(of: settings.ignoreABFlag) { radio.applyTunerSettings() }
    }
}

private struct PresetsSettingsTab: View {
    @Environment(RadioController.self) private var radio

    var body: some View {
        @Bindable var settings = radio.settings
        Form {
            Section {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    ForEach(0..<6, id: \.self) { row in
                        GridRow {
                            PresetField(index: row)
                            PresetField(index: row + 6)
                        }
                    }
                }
            } footer: {
                HStack {
                    Text("Right-click a preset in the main window to store the current station.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") { settings.presets = AppSettings.defaultPresets }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 380)
    }
}

private struct PresetField: View {
    @Environment(RadioController.self) private var radio
    let index: Int
    @State private var text = ""

    var body: some View {
        HStack {
            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
            TextField("", text: $text, prompt: Text("empty"))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .onSubmit(commit)
                .onChange(of: text) { commit() }
            Text(radio.settings.presets[index].flatMap { radio.settings.stationName(for: $0) } ?? "")
                .foregroundStyle(.secondary).font(.caption).frame(width: 80, alignment: .leading)
        }
        .onAppear { text = radio.settings.presets[index].map(radio.format) ?? "" }
        .onChange(of: radio.settings.presets[index]) { _, new in
            if Double(text) != new { text = new.map(radio.format) ?? "" }
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            radio.settings.presets[index] = nil
        } else if let f = Double(trimmed.replacingOccurrences(of: ",", with: ".")),
                  (radio.tuner.band.bottomMHz...radio.tuner.band.topMHz).contains(f) {
            let snapped = radio.tuner.snap(f)
            if radio.settings.presets[index] != snapped { radio.settings.presets[index] = snapped }
        }
    }
}

private struct GeneralSettingsTab: View {
    @Environment(RadioController.self) private var radio

    var body: some View {
        @Bindable var settings = radio.settings
        Form {
            Section("Startup") {
                Toggle("Mute on startup", isOn: $settings.muteOnStartup)
            }
            Section("Menu bar") {
                Toggle("Show in menu bar", isOn: $settings.showInMenuBar)
                Text("When shown, closing the window keeps the radio playing from the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Audio") {
                LabeledContent("Input") { Text(audioDescription) }
                if radio.microphoneDenied {
                    Button("Open Microphone Privacy Settings…") { radio.openMicrophoneSettings() }
                }
                Text("Audio from the radio's USB input is played through the system's default output device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
    }

    private var audioDescription: String {
        switch radio.audioState {
        case .stopped: radio.microphoneDenied ? "Audio input permission denied" : "Stopped"
        case .waitingForDevice: "Waiting for “FM Radio” audio device"
        case let .running(i, o): "FM Radio, \(Int(i)) Hz → output \(Int(o)) Hz"
        case let .failed(e): "Error: \(e)"
        }
    }
}
