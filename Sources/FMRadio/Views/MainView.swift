import Si470xKit
import SwiftUI

struct MainView: View {
    @Environment(RadioController.self) private var radio
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 14) {
            DisplayPanel()
            TransportControls()
            PresetGrid()
            StatusFooter()
        }
        .padding(16)
        .frame(minWidth: 560, maxWidth: 760)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { openSettings() } label: { Label("Settings", systemImage: "gearshape") }
                    .help("Radio settings")
            }
        }
    }
}

// MARK: - Display

private struct DisplayPanel: View {
    @Environment(RadioController.self) private var radio
    @State private var editingFrequency = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Button { editingFrequency = true } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(radio.format(radio.frequency))
                            .font(.system(size: 52, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("MHz")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Click to enter a frequency")
                .popover(isPresented: $editingFrequency, arrowEdge: .bottom) {
                    FrequencyEntry(isPresented: $editingFrequency)
                }

                Text(radio.stationName)
                    .font(.system(size: 30, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .padding(.leading, 12)
                    .opacity(radio.rds.programService.isEmpty ? 0.45 : 1)

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 6) {
                    SignalBars(rssi: radio.rssi, active: radio.isConnected)
                    StereoBadge(stereo: radio.stereo && radio.isConnected,
                                forcedMono: radio.tuner.forceMono)
                }
            }

            Text(radio.rds.radioText.isEmpty ? " " : radio.rds.radioText)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                if let pty = radio.programTypeName { InfoChip(text: pty, systemImage: "music.note") }
                if let call = radio.rds.callLetters, call != radio.stationName {
                    InfoChip(text: call, systemImage: "antenna.radiowaves.left.and.right")
                }
                if radio.rds.trafficProgram { InfoChip(text: "TP", systemImage: "car") }
                if let clock = radio.stationClock { InfoChip(text: clock, systemImage: "clock") }
                Spacer()
                ActivityLabel()
            }
            .font(.caption)
            .frame(height: 18)
        }
        .padding(16)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .animation(.snappy, value: radio.frequency)
    }
}

private struct ActivityLabel: View {
    @Environment(RadioController.self) private var radio

    var body: some View {
        switch radio.activity {
        case .seeking: Label("Seeking…", systemImage: "magnifyingglass").foregroundStyle(.secondary)
        case .scanning: Label("Scanning…", systemImage: "dot.radiowaves.right").foregroundStyle(.tint)
        case .tuning, .idle: EmptyView()
        }
    }
}

private struct FrequencyEntry: View {
    @Environment(RadioController.self) private var radio
    @Binding var isPresented: Bool
    @State private var text = ""

    var body: some View {
        let band = radio.tuner.band
        VStack(alignment: .leading, spacing: 8) {
            Text("Tune to frequency").font(.headline)
            HStack {
                TextField(radio.format(radio.frequency), text: $text)
                    .frame(width: 90)
                    .onSubmit(commit)
                Text("MHz").foregroundStyle(.secondary)
                Button("Tune", action: commit).keyboardShortcut(.defaultAction)
            }
            Text("\(radio.format(band.bottomMHz))–\(radio.format(band.topMHz)) MHz")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private func commit() {
        if let f = Double(text.replacingOccurrences(of: ",", with: ".")) {
            radio.tune(to: f)
        }
        isPresented = false
    }
}

// MARK: - Controls

private struct TransportControls: View {
    @Environment(RadioController.self) private var radio

    var body: some View {
        @Bindable var radio = radio
        HStack(spacing: 8) {
            ControlGroup {
                Button { radio.seek(up: false) } label: { Image(systemName: "backward.end.fill") }
                    .help("Seek down (⌥⌘←)")
                Button { radio.step(up: false) } label: { Image(systemName: "chevron.left") }
                    .help("Step down (⌘←)")
                Button { radio.step(up: true) } label: { Image(systemName: "chevron.right") }
                    .help("Step up (⌘→)")
                Button { radio.seek(up: true) } label: { Image(systemName: "forward.end.fill") }
                    .help("Seek up (⌥⌘→)")
            }
            .controlSize(.large)
            .frame(width: 200)

            Toggle(isOn: Binding(get: { radio.isScanning }, set: { _ in radio.toggleScan() })) {
                Label("Scan", systemImage: "dot.radiowaves.right")
            }
            .toggleStyle(.button)
            .controlSize(.large)
            .help("Seek up through the band, playing each station for the scan time")

            Spacer(minLength: 16)

            Button { radio.muted.toggle() } label: {
                Image(systemName: radio.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 22)
            }
            .buttonStyle(.borderless)
            .help(radio.muted ? "Unmute" : "Mute")

            Slider(value: $radio.volume, in: 0...1)
                .frame(minWidth: 100, maxWidth: 160)
                .disabled(radio.muted)
        }
        .disabled(!radio.isConnected)
    }
}

private struct PresetGrid: View {
    @Environment(RadioController.self) private var radio

    var body: some View {
        let current = radio.currentPresetIndex
        HStack(spacing: 6) {
            Button { radio.stepPreset(forward: false) } label: { Image(systemName: "chevron.backward.2") }
                .buttonStyle(.borderless)
                .help("Previous preset")
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(0..<2, id: \.self) { row in
                    GridRow {
                        ForEach(0..<6, id: \.self) { col in
                            PresetButton(index: row * 6 + col, selected: current == row * 6 + col)
                        }
                    }
                }
            }
            Button { radio.stepPreset(forward: true) } label: { Image(systemName: "chevron.forward.2") }
                .buttonStyle(.borderless)
                .help("Next preset")
        }
        .disabled(!radio.isConnected)
    }
}

private struct PresetButton: View {
    @Environment(RadioController.self) private var radio
    let index: Int
    let selected: Bool

    var body: some View {
        let freq = radio.settings.presets[index]
        Button { radio.selectPreset(index) } label: {
            VStack(spacing: 1) {
                Text(freq.map(radio.format) ?? "—")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text(freq.flatMap { radio.settings.stationName(for: $0) } ?? "Preset \(index + 1)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.bordered)
        .tint(selected ? .accentColor : nil)
        .disabled(freq == nil)
        .contextMenu {
            Button("Set to \(radio.format(radio.frequency)) MHz") { radio.storePreset(index) }
            Button("Clear") { radio.settings.presets[index] = nil }.disabled(freq == nil)
        }
        .help(freq == nil ? "Empty — right-click to store the current station"
                          : "Preset \(index + 1). Right-click to store the current station here.")
    }
}

private struct StatusFooter: View {
    @Environment(RadioController.self) private var radio

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(connectionText)
            if radio.microphoneDenied {
                Text("·")
                Button("Allow audio input…") { radio.openMicrophoneSettings() }
                    .buttonStyle(.link)
            } else if let audio = audioText {
                Text("·")
                Text(audio)
            }
            Spacer()
            if let err = radio.lastError {
                Text(err).foregroundStyle(.red).lineLimit(1).help(err)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var color: Color {
        switch radio.connection {
        case .connected: .green
        case .connecting: .yellow
        case .searching: .gray
        case .failed: .red
        }
    }

    private var connectionText: String {
        switch radio.connection {
        case .searching: "Radio not connected — plug in the Silicon Labs USB FM Radio"
        case .connecting: "Connecting…"
        case let .connected(desc): desc
        case let .failed(err): "Error: \(err)"
        }
    }

    private var audioText: String? {
        switch radio.audioState {
        case .stopped: nil
        case .waitingForDevice: "Waiting for radio audio device"
        case let .running(inRate, outRate): "Audio \(Int(inRate / 1000)) → \(Int(outRate / 1000)) kHz"
        case let .failed(err): "Audio error: \(err)"
        }
    }
}
