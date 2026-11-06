import AppKit
import SwiftUI

@main
struct FMRadioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        @Bindable var settings = appDelegate.radio.settings

        Window("FM Radio", id: "main") {
            MainView()
                .environment(appDelegate.radio)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 600, height: 400)
        .commands { RadioCommands(radio: appDelegate.radio) }

        Settings {
            SettingsView()
                .environment(appDelegate.radio)
        }

        MenuBarExtra(isInserted: $settings.showInMenuBar) {
            MenuBarContent()
                .environment(appDelegate.radio)
        } label: {
            MenuBarLabel()
                .environment(appDelegate.radio)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let radio = RadioController(settings: AppSettings())

    func applicationDidFinishLaunching(_ notification: Notification) {
        radio.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        radio.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !radio.settings.showInMenuBar
    }
}

struct RadioCommands: Commands {
    let radio: RadioController

    var body: some Commands {
        CommandMenu("Radio") {
            Button("Step Up") { radio.step(up: true) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Step Down") { radio.step(up: false) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Seek Up") { radio.seek(up: true) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Seek Down") { radio.seek(up: false) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Scan") { radio.toggleScan() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Play / Pause") { radio.togglePlayPause() }
            Button("Mute / Unmute") { radio.muted.toggle() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Volume Up") { radio.volume = min(1, radio.volume + 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Volume Down") { radio.volume = max(0, radio.volume - 0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Divider()
            ForEach(0..<9, id: \.self) { i in
                Button("Preset \(i + 1)") { radio.selectPreset(i) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Button("Next Preset") { radio.stepPreset(forward: true) }
                .keyboardShortcut("]", modifiers: .command)
            Button("Previous Preset") { radio.stepPreset(forward: false) }
                .keyboardShortcut("[", modifiers: .command)
        }
    }
}
