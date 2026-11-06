# FM Radio for macOS

A native macOS player for the Silicon Labs USB FM Radio reference design (VID:PID `10C4:818A`, Si470x tuner and C8051F321 USB MCU). It replaces the Windows-only "Silicon Labs USB Radio" app. No driver or kext is needed: control runs over HID feature reports and audio over the standard USB Audio Class input.

**Features:** play/pause, tune, step, seek, scan, 12 presets, signal and stereo indicators, RDS/RBDS (station name, RadioText, program type, call letters, TP, clock time), volume and mute, and a menu bar extra. Settings cover band, spacing, de-emphasis, seek threshold, force mono, scan time, mute on startup and the RadioText A/B flag. The app handles hot-plug and sleep/wake, and powers the tuner down on quit.

## Build and run

Requires macOS 15+ and Xcode / Swift 6.

```sh
scripts/build-app.sh          # release build → build/FM Radio.app (ad-hoc signed)
scripts/build-app.sh debug    # debug build
open "build/FM Radio.app"
```

On first launch macOS asks for **microphone** permission. The radio's audio arrives as a USB audio *input*, so playing it requires that permission. Ad-hoc builds are signed with an identifier-based designated requirement, so the permission survives rebuilds. To sign with a real identity, set `SIGN_IDENTITY="Developer ID Application: …"`.

You can also open `Package.swift` in Xcode. Running the `FMRadio` scheme from Xcode runs an unbundled executable, so microphone permission is attributed to Xcode. Use the script when you need the real `.app`.

### Keyboard shortcuts

| Action | Keys |
|---|---|
| Play / pause | Space |
| Step down / up | ⌘← / ⌘→ |
| Seek down / up | ⌥⌘← / ⌥⌘→ |
| Scan | ⇧⌘S |
| Presets 1–9 | ⌘1 … ⌘9 |
| Previous / next preset | ⌘[ / ⌘] |
| Volume | ⌘↑ / ⌘↓ |
| Mute | ⇧⌘M |

Click the frequency to type one in. Right-click a preset to store the current station in it.

## Hardware test tool

```sh
swift build --product si470x-cli
.build/debug/si470x-cli info              # identify + register dump
.build/debug/si470x-cli tune 90.9 15      # tune, then watch status/RDS for 15 s
.build/debug/si470x-cli seek up
.build/debug/si470x-cli play 90.9 10      # tune + audio pass-through with level/drift stats
.build/debug/si470x-cli off               # power the tuner down
```

`tools/si470x_probe.py` is the original Python feasibility probe.

## Layout

```
Sources/Si470xKit/       hardware library (no UI)
  HIDTransport.swift     IOHIDManager matching, feature GET/SET, input-report routing
  Registers.swift        Si470x register map, band/spacing/de-emphasis, channel math
  Si470x.swift           register driver: identify, power up/down, configure, tune, seek
  RDSDecoder.swift       PI, PTY, TP/TA, PS (0A/0B), RadioText (2A/2B), clock time (4A)
  RadioAudio.swift       AUHAL capture from the radio → AVAudioEngine output
  AudioRingBuffer.swift  lock-free SPSC ring + drift-compensating Hermite resampler
Sources/FMRadio/         SwiftUI app
  RadioController.swift  @Observable app model: hot-plug, sleep/wake, tune/seek/scan, presets
  RadioWorker.swift      serial USB queue + interrupt-report → UI update processor
  AppSettings.swift      UserDefaults-backed settings and presets
  Views/                 main window, Settings, menu bar extra
Sources/si470x-cli/      hardware test tool
Tests/Si470xKitTests/    RDS decoder, channel math, resampler tests (`swift test`)
```

## Implementation notes

- **Transport.** Default IOHID path with `kIOHIDReportTypeFeature`. The libusb fallback from the handoff wasn't needed. With a dispatch-queue `IOHIDManager`, per-device input callbacks can't be registered after activation, so report 18 is received through a manager-level callback and routed to the device.
- **Status.** The firmware sends report 18 about 36 times a second. Live RSSI, stereo and RDS come from it. Tune and seek poll register report 17 for STC.
- **RDS on this chip.** The unit has an **Si4701 rev B**, which has no RDS verbose mode, so the block error (BLER) fields are always 0 and mis-corrected blocks get through on weak signals. The decoder therefore validates everything:
  - A PI needs repeats before it's accepted, and groups whose PI doesn't match the established one are dropped.
  - PTY, PS segments and RadioText segments each need two identical receptions.
  - Clock time needs two consistent, plausible receptions.
  - PS is published only after all four segments are re-confirmed, so scrolling ("dynamic") PS updates a word at a time.
- **Preset labels.** These use RBDS call letters decoded from PI (200 kHz spacing, US). Otherwise they use a PS that has stayed the same for 20 s. Many US stations scroll text through PS.
- **Audio.** The radio's clock and the output device's clock drift apart. Audio is captured at 96 kHz into a ring buffer. The output side resamples to the device rate with a cubic interpolator whose ratio is nudged (at most ±0.5%, typically a few hundred ppm) to hold about 80 ms buffered. An AVAudioEngine configuration change (for example, a new output device) rebuilds the pipeline.
- **Scan time** is how long Scan dwells on each station. Scan seeks upward, plays each station for that long, and stops after one lap of the band or when you press Scan again.
- **Never written:** reports 19 (LED/stream) and 20–23 (scratch/bootloader/flash). Report 20 is only read, for the firmware version.
