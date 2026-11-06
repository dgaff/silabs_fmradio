import SwiftUI

/// Contents of the menu bar extra (menu style).
struct MenuBarContent: View {
    @Environment(RadioController.self) private var radio
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if radio.isConnected {
            Text("\(radio.format(radio.frequency)) MHz  \(radio.stationName)")
            if !radio.rds.radioText.isEmpty {
                Text(radio.rds.radioText)
            }
        } else {
            Text("Radio not connected")
        }
        Divider()
        Button(radio.muted ? "Unmute" : "Mute") { radio.muted.toggle() }
        Button("Seek Up") { radio.seek(up: true) }.disabled(!radio.isConnected)
        Button("Seek Down") { radio.seek(up: false) }.disabled(!radio.isConnected)
        Button(radio.isScanning ? "Stop Scan" : "Scan") { radio.toggleScan() }.disabled(!radio.isConnected)
        Menu("Presets") {
            ForEach(0..<12, id: \.self) { i in
                if let f = radio.settings.presets[i] {
                    Button("\(i + 1).  \(radio.format(f))  \(radio.settings.stationName(for: f) ?? "")") {
                        radio.selectPreset(i)
                    }
                }
            }
        }
        .disabled(!radio.isConnected)
        Divider()
        Button("Show FM Radio") {
            openWindow(id: "main")
            NSApp.activate()
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit FM Radio") { NSApp.terminate(nil) }
    }
}

struct MenuBarLabel: View {
    @Environment(RadioController.self) private var radio

    var body: some View {
        Image(systemName: radio.muted ? "radio" : "radio.fill")
    }
}
