#!/usr/bin/env python3
"""
si470x_probe.py — probe the Silicon Labs USB FM Radio reference design
(VID 0x10C4 / PID 0x818A, Si470x + C8051F321) from macOS.

Protocol (from the Linux radio-si470x-usb driver):
  Reports 1-16  : feature report, one Si470x register each (report id = reg + 1), 3 bytes
  Report 17     : feature report, all 16 registers, 33 bytes
  Report 18     : input report on interrupt EP, regs 0x0A-0x0F (status + RDS), 13 bytes
  Report 19     : LED / stream command
  Report 20     : scratch page (byte1 = SW version, byte2 = HW version), 64 bytes

Install:
    pip3 install hidapi            # control path (required)
    pip3 install sounddevice numpy # only for --play
    brew install libusb && pip3 install pyusb   # only for --raw fallback

Usage:
    python3 si470x_probe.py                  # identify, power up, tune 90.9, watch status
    python3 si470x_probe.py -f 101.5 --play 15
    python3 si470x_probe.py --raw            # use libusb control transfers instead of IOHID
"""

import argparse
import struct
import sys
import time

VID, PID = 0x10C4, 0x818A

# Register addresses
DEVICEID, CHIPID, POWERCFG, CHANNEL, SYSCONFIG1, SYSCONFIG2, SYSCONFIG3, TEST1, \
    TEST2, BOOTCONFIG, STATUSRSSI, READCHAN, RDSA, RDSB, RDSC, RDSD = range(16)
REG_NAMES = ["DEVICEID", "CHIPID", "POWERCFG", "CHANNEL", "SYSCONFIG1", "SYSCONFIG2",
             "SYSCONFIG3", "TEST1", "TEST2", "BOOTCONFIG", "STATUSRSSI", "READCHAN",
             "RDSA", "RDSB", "RDSC", "RDSD"]

ENTIRE_REPORT, RDS_REPORT, SCRATCH_REPORT = 17, 18, 20

# POWERCFG bits
DSMUTE, DMUTE, MONO, SKMODE, SEEKUP, SEEK, PDISABLE, PENABLE = \
    1 << 15, 1 << 14, 1 << 13, 1 << 10, 1 << 9, 1 << 8, 1 << 6, 1 << 0
# CHANNEL bits
TUNE = 1 << 15
# SYSCONFIG1 bits
RDS_EN, DE_50US = 1 << 12, 1 << 11
# STATUSRSSI bits
RDSR, STC, SFBL, RDSS, ST = 1 << 15, 1 << 14, 1 << 13, 1 << 11, 1 << 8

BAND_BOTTOM = {0: 87.5, 1: 76.0, 2: 76.0}
SPACING_MHZ = {0: 0.2, 1: 0.1, 2: 0.05}


# --------------------------------------------------------------------------- transports

class HidTransport:
    """macOS IOHIDManager via hidapi. Sends report type 'Feature' (wValue = 0x03xx)."""
    name = "hidapi (IOHID)"

    def __init__(self):
        import hid
        infos = hid.enumerate(VID, PID)
        if not infos:
            raise RuntimeError("No HID interface for 10c4:818a found")
        for i in infos:
            print(f"  HID interface: if#{i.get('interface_number')} usage_page=0x{i.get('usage_page', 0):04x} "
                  f"usage=0x{i.get('usage', 0):04x} product={i.get('product_string')!r} "
                  f"manufacturer={i.get('manufacturer_string')!r}")
        self.dev = hid.device()
        self.dev.open_path(infos[0]["path"])
        self.dev.set_nonblocking(False)

    def get(self, report_id, size):
        data = self.dev.get_feature_report(report_id, size)
        if not data or len(data) < 2:
            raise IOError(f"GET_REPORT {report_id} returned {data!r}")
        return bytes(data)

    def set(self, payload):
        n = self.dev.send_feature_report(list(payload))
        if n < 0:
            raise IOError(f"SET_REPORT {payload[0]} failed")

    def read_input(self, size=64, timeout_ms=100):
        return bytes(self.dev.read(size, timeout_ms))

    def close(self):
        self.dev.close()


class RawUsbTransport:
    """libusb control transfers, matching the Linux driver byte-for-byte
    (wValue = report id with type byte 0, wIndex = HID interface number)."""
    name = "libusb (raw control transfers)"

    def __init__(self):
        import usb.core
        self.dev = usb.core.find(idVendor=VID, idProduct=PID)
        if self.dev is None:
            raise RuntimeError("10c4:818a not found via libusb")
        cfg = self.dev.get_active_configuration()
        self.hid_if = None
        for intf in cfg:
            cls = intf.bInterfaceClass
            print(f"  USB interface #{intf.bInterfaceNumber} alt {intf.bAlternateSetting}: class 0x{cls:02x} "
                  f"subclass 0x{intf.bInterfaceSubClass:02x} endpoints={[hex(e.bEndpointAddress) for e in intf]}")
            if cls == 0x03 and self.hid_if is None:
                self.hid_if = intf.bInterfaceNumber
        if self.hid_if is None:
            raise RuntimeError("No HID interface in descriptor")
        print(f"  Using HID interface #{self.hid_if}")

    def get(self, report_id, size):
        return bytes(self.dev.ctrl_transfer(0xA1, 0x01, report_id, self.hid_if, size, timeout=500))

    def set(self, payload):
        self.dev.ctrl_transfer(0x21, 0x09, payload[0], self.hid_if, bytes(payload), timeout=500)

    def read_input(self, size=64, timeout_ms=100):
        return b""  # interrupt EP is owned by the macOS HID driver; not attempted here

    def close(self):
        pass


# --------------------------------------------------------------------------- radio helpers

class Radio:
    def __init__(self, t):
        self.t = t
        self.regs = [0] * 16

    def read_reg(self, reg):
        d = self.t.get(reg + 1, 3)
        self.regs[reg] = (d[1] << 8) | d[2]
        return self.regs[reg]

    def write_reg(self, reg, value):
        self.regs[reg] = value & 0xFFFF
        self.t.set(bytes([reg + 1, (value >> 8) & 0xFF, value & 0xFF]))

    def read_all(self):
        d = self.t.get(ENTIRE_REPORT, 33)
        self.regs = list(struct.unpack(">16H", d[1:33]))
        return self.regs

    def freq_from_chan(self, chan):
        band = (self.regs[SYSCONFIG2] >> 6) & 3
        space = (self.regs[SYSCONFIG2] >> 4) & 3
        return BAND_BOTTOM.get(band, 87.5) + chan * SPACING_MHZ.get(space, 0.2)

    def chan_from_freq(self, mhz):
        band = (self.regs[SYSCONFIG2] >> 6) & 3
        space = (self.regs[SYSCONFIG2] >> 4) & 3
        return round((mhz - BAND_BOTTOM.get(band, 87.5)) / SPACING_MHZ.get(space, 0.2))

    def status(self):
        s = self.read_reg(STATUSRSSI)
        r = self.read_reg(READCHAN)
        return s, r


def dump_regs(regs):
    for i, v in enumerate(regs):
        print(f"    0x{i:02X} {REG_NAMES[i]:<11} 0x{v:04X}  {v:016b}")


def fmt_status(radio, s, r):
    return (f"freq={radio.freq_from_chan(r & 0x3FF):6.2f} MHz  RSSI={s & 0xFF:3d} dBµV  "
            f"{'STEREO' if s & ST else 'mono  '}  STC={int(bool(s & STC))} SF/BL={int(bool(s & SFBL))} "
            f"RDSS={int(bool(s & RDSS))} RDSR={int(bool(s & RDSR))}")


# --------------------------------------------------------------------------- steps

def step(title):
    print(f"\n=== {title} " + "=" * max(0, 60 - len(title)))


def run(args):
    step("1. Open device")
    t = None
    errors = []
    order = [RawUsbTransport] if args.raw else [HidTransport, RawUsbTransport]
    for cls in order:
        try:
            t = cls()
            print(f"  Opened with {cls.name}")
            break
        except Exception as e:  # noqa: BLE001
            errors.append(f"{cls.name}: {e}")
            print(f"  {cls.name} failed: {e}")
    if t is None:
        sys.exit("Could not open the radio. " + " | ".join(errors))

    radio = Radio(t)

    step("2. Identity (report 1 = DEVICEID)")
    try:
        dev_id = radio.read_reg(DEVICEID)
    except Exception as e:  # noqa: BLE001
        if isinstance(t, HidTransport) and not args.raw:
            print(f"  Feature GET failed via IOHID ({e}). Retry with --raw (needs libusb + pyusb).")
        raise
    mfg = dev_id & 0x0FFF
    print(f"  DEVICEID = 0x{dev_id:04X}  (part# {dev_id >> 12}, MFGID 0x{mfg:03X})")
    print("  ✅ Silicon Labs MFGID 0x242 — control path works" if mfg == 0x242
          else "  ⚠️  Unexpected MFGID (expected 0x242)")

    step("3. Full register map (report 17)")
    try:
        radio.read_all()
        dump_regs(radio.regs)
    except Exception as e:  # noqa: BLE001
        print(f"  Report 17 failed ({e}); reading registers one at a time")
        for i in range(16):
            radio.read_reg(i)
        dump_regs(radio.regs)
    chip = radio.regs[CHIPID]
    print(f"  CHIPID: REV={chip >> 10}  DEV={(chip >> 6) & 0xF}  FIRMWARE={chip & 0x3F}")

    step("4. Scratch page (report 20: firmware/hardware versions)")
    try:
        sp = t.get(SCRATCH_REPORT, 64)
        print(f"  SW version={sp[1]}  HW version={sp[2]}  raw[0:8]={sp[:8].hex(' ')}")
    except Exception as e:  # noqa: BLE001
        print(f"  Scratch read failed: {e} (non-fatal)")

    step("5. Power up / configure")
    p = radio.regs[POWERCFG]
    print(f"  POWERCFG before: 0x{p:04X} (ENABLE={p & 1}, DMUTE={int(bool(p & DMUTE))})")
    p = (p | DMUTE | PENABLE) & ~PDISABLE & ~(SEEK)
    if args.mono:
        p |= MONO
    else:
        p &= ~MONO
    radio.write_reg(POWERCFG, p)
    time.sleep(0.11)  # AN230: allow ~110 ms after ENABLE

    s1 = radio.read_reg(SYSCONFIG1)
    s1 |= RDS_EN
    s1 = (s1 | DE_50US) if args.de50 else (s1 & ~DE_50US)
    radio.write_reg(SYSCONFIG1, s1)

    space_code = {200: 0, 100: 1, 50: 2}[args.spacing]
    s2 = radio.read_reg(SYSCONFIG2)
    s2 = ((args.seekth & 0x3F) << 8) | (0 << 6) | (space_code << 4) | (args.volume & 0xF)
    radio.write_reg(SYSCONFIG2, s2)
    radio.read_all()
    print(f"  POWERCFG=0x{radio.regs[POWERCFG]:04X}  SYSCONFIG1=0x{radio.regs[SYSCONFIG1]:04X}  "
          f"SYSCONFIG2=0x{radio.regs[SYSCONFIG2]:04X}")

    step(f"6. Tune to {args.freq:.2f} MHz")
    chan = radio.chan_from_freq(args.freq)
    radio.write_reg(CHANNEL, (radio.regs[CHANNEL] & 0xFC00) | TUNE | (chan & 0x3FF))
    t0 = time.time()
    while True:
        s, r = radio.status()
        if s & STC:
            break
        if time.time() - t0 > 3:
            print("  ⚠️  STC never set (tune timeout)")
            break
        time.sleep(0.02)
    print(f"  Tune completed in {(time.time() - t0) * 1000:.0f} ms")
    radio.write_reg(CHANNEL, radio.regs[CHANNEL] & ~TUNE)   # clear TUNE → STC clears
    time.sleep(0.05)
    s, r = radio.status()
    print("  " + fmt_status(radio, s, r))

    step("7. Interrupt endpoint (report 18 every ~20 ms)")
    got = 0
    for _ in range(10):
        d = t.read_input(64, 100)
        if d:
            got += 1
            if got <= 3:
                print(f"  input report id={d[0]} len={len(d)} data={d[:13].hex(' ')}")
    print(f"  Received {got}/10 input reports" + ("" if got else
          "  (none — fine; polling registers works as a fallback)"))

    if args.rds > 0:
        step(f"8. RDS for {args.rds}s (Program Service name + RadioText)")
        watch_rds(radio, args.rds)

    if args.play > 0:
        step(f"9. Audio pass-through for {args.play}s")
        play(args)

    if args.seek:
        step("10. Seek up")
        p = radio.regs[POWERCFG] | SEEK | SEEKUP | SKMODE
        radio.write_reg(POWERCFG, p)
        t0 = time.time()
        while not (radio.status()[0] & STC) and time.time() - t0 < 15:
            time.sleep(0.05)
        radio.write_reg(POWERCFG, radio.regs[POWERCFG] & ~SEEK)
        time.sleep(0.05)
        s, r = radio.status()
        print("  " + fmt_status(radio, s, r) + ("  (band limit / fail)" if s & SFBL else ""))

    t.close()
    print("\nDone.")


def watch_rds(radio, seconds):
    ps = [" "] * 8
    rt = [" "] * 64
    t_end = time.time() + seconds
    last_ps = ""
    while time.time() < t_end:
        s = radio.read_reg(STATUSRSSI)
        if s & RDSR:
            r = radio.read_reg(READCHAN)
            b = radio.read_reg(RDSB)
            c = radio.read_reg(RDSC)
            d = radio.read_reg(RDSD)
            blerb, blerd = (r >> 14) & 3, (r >> 10) & 3
            if blerb < 3 and blerd < 3:
                gtype, ver = (b >> 12) & 0xF, (b >> 11) & 1
                if gtype == 0:
                    seg = b & 3
                    ps[seg * 2], ps[seg * 2 + 1] = chr((d >> 8) & 0x7F), chr(d & 0x7F)
                elif gtype == 2 and ver == 0:
                    seg = b & 0xF
                    for k, ch in enumerate([c >> 8, c & 0xFF, d >> 8, d & 0xFF]):
                        rt[seg * 4 + k] = chr(ch & 0x7F)
            cur = "".join(ps)
            if cur != last_ps:
                print(f"  PS: [{cur}]")
                last_ps = cur
        time.sleep(0.02)
    print(f"  RadioText: {''.join(rt).strip()!r}")


def play(args):
    try:
        import numpy as np
        import sounddevice as sd
    except ImportError:
        print("  pip3 install sounddevice numpy  to enable --play")
        return
    devs = sd.query_devices()
    want = [args.audio_device.lower()] if args.audio_device else ["fm", "radio", "silicon", "usb audio"]
    in_idx = next((i for i, d in enumerate(devs)
                   if d["max_input_channels"] >= 2 and any(k in d["name"].lower() for k in want)), None)
    if in_idx is None:
        print("  Couldn't find the radio's input. Devices:")
        for i, d in enumerate(devs):
            print(f"    [{i}] {d['name']} (in={d['max_input_channels']}, out={d['max_output_channels']})")
        print("  Re-run with --audio-device '<part of name>'")
        return
    out_idx = sd.default.device[1]
    out_rate = int(devs[out_idx]["default_samplerate"])
    print(f"  Input : [{in_idx}] {devs[in_idx]['name']} @ 96000")
    print(f"  Output: [{out_idx}] {devs[out_idx]['name']} @ {out_rate}")

    import collections, threading
    buf = collections.deque()
    lock = threading.Lock()
    ratio = out_rate / 96000.0
    peak = [0.0]

    def in_cb(indata, frames, time_info, status):
        x = indata.copy()
        peak[0] = max(peak[0], float(np.abs(x).max()))
        if ratio != 1.0:
            n = int(round(len(x) * ratio))
            idx = np.linspace(0, len(x) - 1, n)
            x = np.stack([np.interp(idx, np.arange(len(x)), x[:, ch]) for ch in range(2)], axis=1).astype(np.float32)
        with lock:
            buf.append(x)

    pending = [np.zeros((0, 2), np.float32)]

    def out_cb(outdata, frames, time_info, status):
        with lock:
            while len(pending[0]) < frames and buf:
                pending[0] = np.concatenate([pending[0], buf.popleft()])
        chunk = pending[0][:frames]
        pending[0] = pending[0][frames:]
        outdata[:len(chunk)] = chunk
        outdata[len(chunk):] = 0

    with sd.InputStream(device=in_idx, samplerate=96000, channels=2, dtype="float32", callback=in_cb), \
            sd.OutputStream(device=out_idx, samplerate=out_rate, channels=2, dtype="float32", callback=out_cb):
        t_end = time.time() + args.play
        while time.time() < t_end:
            time.sleep(1)
            print(f"  input peak level: {peak[0]:.3f}")
            peak[0] = 0.0
    print("  (peak ≈ 0.000 throughout means no audio is streaming from the radio)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-f", "--freq", type=float, default=90.9, help="MHz (default 90.9)")
    ap.add_argument("--spacing", type=int, choices=[200, 100, 50], default=200, help="kHz (default 200, USA)")
    ap.add_argument("--de50", action="store_true", help="50 µs de-emphasis (Europe); default 75 µs")
    ap.add_argument("--mono", action="store_true", help="force mono")
    ap.add_argument("--seekth", type=int, default=15, help="seek threshold 0-63 (default 15)")
    ap.add_argument("--volume", type=int, default=15, help="chip volume 0-15 (default 15)")
    ap.add_argument("--rds", type=float, default=8, help="seconds to watch RDS (0 to skip)")
    ap.add_argument("--play", type=float, default=0, help="seconds of audio pass-through (needs sounddevice)")
    ap.add_argument("--audio-device", help="substring of the radio's input device name for --play")
    ap.add_argument("--seek", action="store_true", help="finish with a seek-up test")
    ap.add_argument("--raw", action="store_true", help="use libusb control transfers instead of IOHID")
    run(ap.parse_args())


if __name__ == "__main__":
    main()
