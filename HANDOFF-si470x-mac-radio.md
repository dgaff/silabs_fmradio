# Handoff: macOS app for the Silicon Labs USB FM Radio (Si470x)

## Goal
Build a native macOS app that replaces the Windows-only "Silicon Labs USB Radio" player for an old SiLabs USB FM radio reference design. It should do everything the Windows app does: tune, seek, 12 presets, signal and stereo indicators, RDS station name and RadioText, volume and mute, and the settings dialog (band, spacing, de-emphasis, seek threshold, force mono, scan time). Audio should play through the Mac's speakers.

There are two example screens from the windows app for inspiration: windows_players.png and windows_settings_screen.png.

## Status: feasibility proven
`si470x_probe.py` (Python, hidapi + sounddevice) has already been run on the Mac against the real hardware. These all worked:
- Opening the device over HID and reading DEVICEID (MFGID 0x242)
- Full register dump (report 17) and scratch page (report 20)
- Power-up and configuration, tuning (STC handshake) and RSSI/stereo readout
- Interrupt input reports (report 18)
- RDS station-name decoding
- Seek
- **Audio pass-through to the speakers**

> Assumed: this was the default hidapi/IOHID path (no `--raw`). If the probe needed `--raw`, the app must use libusb control transfers instead of IOHIDDeviceSetReport. See Risks.

The probe script is the reference implementation. Port its logic to Swift.

## Hardware
| Item | Value |
|---|---|
| USB VID:PID | `0x10C4:0x818A` ("FM Radio", Silicon Laboratories) |
| USB | 1.1, full speed |
| Chips | Si470x FM tuner (Si4701/03 class, with RDS) + C8051F321 USB MCU |
| Interfaces | USB Audio Class (control + streaming) and a HID interface (probably interface #2) |
| Audio | Standard UAC1 input: **96 kHz, 2 ch, 16-bit**. Shows up in Audio MIDI Setup with no driver. |
| Linux driver (protocol reference) | `drivers/media/radio/si470x/radio-si470x-usb.c` + `radio-si470x-common.c` |
| Chip programming guide | SiLabs **AN230** "Si4700/01/02/03 Programming Guide" (rev 0.9). SparkFun hosts a copy. |

## HID protocol (C8051 firmware)
All control goes over endpoint 0 as HID GET_REPORT / SET_REPORT. The first byte of every buffer is the report ID. Registers are 16-bit, big-endian.

| Report ID | Direction | Size | Meaning |
|---|---|---|---|
| 1–16 | feature get/set | 3 | One Si470x register. **report ID = register + 1**. Bytes: `[id, hi, lo]` |
| 17 | feature get/set | 33 | All 16 registers |
| 18 | input (interrupt IN EP) | 13 | Registers 0x0A–0x0F (STATUSRSSI, READCHAN, RDSA–D), sent every ~20 ms |
| 19 | feature set | 3 | LED command (`[19, LED_COMMAND, state]`) or stream command (`STREAM_COMMAND 0x36`, `STREAM_AUDIO 0xFF`). Neither has been needed so far. |
| 20 | feature get | 64 | Scratch page: byte1 = SW version, byte2 = HW version |
| 21–23 | — | — | Bootloader / flash / unused. **Do not touch.** |

The Linux driver sends wValue = report ID with a type byte of 0 and wIndex = 2. macOS IOHID sends a Feature type (0x03xx), and the firmware accepted it in the probe.

## Si470x registers used
| Addr | Name | Bits of interest |
|---|---|---|
| 0x00 | DEVICEID | PN[15:12], MFGID[11:0] = 0x242 |
| 0x01 | CHIPID | REV[15:10], DEV[9:6], FIRMWARE[5:0] |
| 0x02 | POWERCFG | DSMUTE 15, **DMUTE 14** (1 = unmute), **MONO 13**, SKMODE 10 (1 = stop at band edge), SEEKUP 9, **SEEK 8**, DISABLE 6, **ENABLE 0** |
| 0x03 | CHANNEL | **TUNE 15**, CHAN[9:0] |
| 0x04 | SYSCONFIG1 | RDSIEN 15, STCIEN 14, **RDS 12**, **DE 11** (0 = 75 µs USA, 1 = 50 µs EU) |
| 0x05 | SYSCONFIG2 | **SEEKTH[15:8]** (0–63 in the Windows UI), **BAND[7:6]** (0 = 87.5–108, 1 = 76–108, 2 = 76–90), **SPACE[5:4]** (0 = 200 k, 1 = 100 k, 2 = 50 k), **VOLUME[3:0]** |
| 0x06 | SYSCONFIG3 | SKSNR / SKCNT (seek tuning, AN230 appendix) |
| 0x0A | STATUSRSSI | **RDSR 15**, **STC 14**, **SF/BL 13**, RDSS 11, BLERA[10:9], **ST 8** (stereo), **RSSI[7:0]** |
| 0x0B | READCHAN | BLERB[15:14], BLERC[13:12], BLERD[11:10], READCHAN[9:0] |
| 0x0C–0x0F | RDSA–RDSD | RDS blocks |

Frequency (MHz) = band bottom + CHAN × spacing. US: 87.5 + CHAN × 0.2.

## Sequences (all verified in the probe)
**Power up:** read all registers. Set POWERCFG `|= DMUTE | ENABLE`, clear DISABLE and SEEK (0x4001 from cold). Wait about 110 ms. Then set SYSCONFIG1 (RDS = 1, DE) and SYSCONFIG2 (SEEKTH, BAND, SPACE, VOLUME = 15). Do volume in software and leave the chip at 15.

**Tune:**
1. Write CHANNEL = TUNE | chan.
2. Poll STATUSRSSI (or watch report 18) until STC = 1.
3. Write CHANNEL with TUNE cleared.
4. Wait for STC = 0.
5. Read READCHAN to get the actual channel.

**Seek:**
1. Set POWERCFG `|= SEEK | SEEKUP(or not) | SKMODE`.
2. Wait for STC; this takes up to the scan time.
3. Clear SEEK and wait for STC = 0.
4. If SF/BL = 1, the seek failed or hit the band limit.

**RDS:** when RDSR = 1, read B/C/D. Skip any block whose BLER = 3.
- **Group 0 (station name):** group type = B[15:12], segment = B[1:0]. Block D holds 2 PS chars.
- **Group 2A (RadioText):** segment = B[3:0]. Blocks C and D hold 4 RT chars.
- The A/B text flag is B[4]. When it changes, clear the RadioText buffer, unless the "Ignore AB Flag" setting is on.

**Power down (on quit):** set POWERCFG ENABLE = 1 and DISABLE = 1 (AN230 §2.6).

## Proposed app architecture (Swift / SwiftUI, no kext, no DriverKit)
1. **`RadioDevice`**
   - Use IOHIDManager to match VID/PID and handle hot-plug.
   - Send feature reports with `IOHIDDeviceSetReport` / `IOHIDDeviceGetReport` (`kIOHIDReportTypeFeature`).
   - Register `IOHIDDeviceRegisterInputReportCallback` for report 18 status and RDS. This replaces polling.
   - Run everything on a serial queue.
2. **`Si470x`**: a register model plus the tune, seek, power and config operations above, exposed as async/await methods. Use a `@Observable` state object holding frequency, RSSI, stereo, PS and RT.
3. **`RDSDecoder`**: PS and RadioText decoding (later maybe PTY, CT, PI).
4. **`AudioEngine`**
   - AVAudioEngine with the radio's Core Audio device set as the input node's device (via `kAudioOutputUnitProperty_CurrentDevice` on the input unit). Connect input to the main mixer; the engine resamples 96 k to the output rate.
   - Volume and mute go on the mixer.
   - Find the device by matching the USB audio device's name or model UID (`AudioObject` properties) to "FM Radio" / the SiLabs VID.
5. **UI**: a compact window echoing the original (big frequency readout, PS, scrolling RT, signal bars, stereo icon, `<<` `<` `>` `>>`, 12 preset buttons, volume slider), plus a Settings window with the same controls as the Windows dialog. Store presets and settings in UserDefaults. A menu bar extra is optional ("Show in tray").
6. **Entitlements**: the app needs **microphone permission** (`NSMicrophoneUsageDescription`, plus `com.apple.security.device.audio-input` if sandboxed) because it captures audio input. If sandboxed, it also needs `com.apple.security.device.usb`.

Windows dialog defaults to mirror: band 87.5–108, spacing 200 kHz, de-emphasis 75 µs, seek threshold 15, scan time about 8 s, presets 90.9, 92.1, 93.3, 93.7, 94.7, 96.7, 100.7, 101.5, 102.3, 103.5, 105.9, 107.1.

## Risks / open questions
- **Transport fallback:** if `IOHIDDeviceSetReport` misbehaves (for example, a seek command ignored), fall back to libusb control transfers that match Linux exactly: `bmRequestType 0x21/0xA1`, `bRequest 0x09/0x01`, `wValue = reportID`, `wIndex = HID interface #`. libusb would need to be bundled.
- **Input report 18 and polling:** RDS can be read by polling registers. Avoid doing both at full rate, so the GET_REPORT traffic doesn't collide with the interrupt stream.
- **Sleep/wake and unplug:** re-run power-up and re-tune on reconnect. The Linux driver notes that suspend/resume was unreliable.
- **Audio clock drift:** the radio's clock and the output device's clock differ. AVAudioEngine handles this, but watch for slow buffer drift or glitches in long sessions. An aggregate device or a ring buffer with drift correction are the fallbacks.
- **Firmware update reports (20–22):** never write them; that's the bootloader path.

## Suggested first milestones
1. A Swift CLI or small app that reproduces the probe: open the device, read the ID, power up, tune, print RSSI/ST.
2. Input-report callback with live status and RDS.
3. Audio pass-through with volume and mute.
4. Main UI, presets, seek and scan.
5. Settings window, menu bar mode, hot-plug, sleep/wake handling.

## Files
- `si470x_probe.py`: the working Python reference (transport, register helpers, tune/seek/RDS/audio). Bring it into the repo as `tools/si470x_probe.py`.
- Screenshots of the original Windows main window and settings dialog are useful as UI references.
