import SwiftUI

/// Five-bar signal meter from RSSI in dBµV.
struct SignalBars: View {
    let rssi: Int
    let active: Bool

    private static let thresholds = [8, 18, 28, 38, 48]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(active && rssi >= Self.thresholds[i] ? Color.primary : Color.secondary.opacity(0.25))
                    .frame(width: 5, height: CGFloat(5 + i * 4))
            }
        }
        .frame(height: 21, alignment: .bottom)
        .help(active ? "Signal \(rssi) dBµV" : "No signal")
        .accessibilityLabel("Signal strength \(rssi) dB microvolts")
    }
}

struct StereoBadge: View {
    let stereo: Bool
    let forcedMono: Bool

    var body: some View {
        Text(forcedMono ? "MONO" : "STEREO")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(stereo && !forcedMono ? Color.accentColor : Color.secondary.opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(stereo && !forcedMono ? Color.accentColor : Color.secondary.opacity(0.3))
            )
            .help(forcedMono ? "Mono forced in Settings" : stereo ? "Stereo pilot detected" : "Mono reception")
    }
}

struct InfoChip: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.secondary)
    }
}
