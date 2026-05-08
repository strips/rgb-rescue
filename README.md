# rgb-rescue

Set a static colour on all MSI RGB hardware at boot — keyboard, motherboard,
and RAM — using no OpenRGB at runtime, no GUI, no desktop daemon.

Everything is pure Python (stdlib) + one apt package for SMBus, wired into
systemd and udev so it fires automatically.

---

## Hardware this was built for

| Device | ID / bus | Driver script |
|--------|----------|---------------|
| MSI Vigor GK50 Low Profile keyboard | USB HID VID `0x0DB0` PID `0x0B5A` | `gk50-set-color` |
| MSI MAG Z390 TOMAHAWK (Mystic Light) | USB HID VID `0x1462` PID `0x7B18` | `mystic-light-set-color` |
| ENE DRAM sticks × 4 | i2c-0 addresses `0x70`–`0x73` | `ene-dram-set-color` |

---

## Repo layout

```
install.sh                       single sudo installer
scripts/
    gk50-set-color               keyboard driver (Python, no deps)
    mystic-light-set-color       MB Mystic Light driver (Python, no deps)
    ene-dram-set-color           DRAM driver (needs python3-smbus)
    rgb-set-all                  wrapper — calls all three devices
    rgb-temp-watch               CPU-temp → colour band watcher
    probe-rgb-hardware           diagnostic dump (USB HID + i2c)
systemd/
    rgb-static.service           oneshot: set colour at boot
    rgb-temp.service             oneshot: called by timer
    rgb-temp.timer               fires at boot+30s, then every 60s
udev/
    60-rgb-devices.rules         hidraw + i2c-dev group access rules
modules-load.d/
    i2c-dev.conf                 loads i2c-dev at boot
```

---

## Quick install

```bash
git clone <your-repo> rgb-rescue
cd rgb-rescue

# Static colour only (keyboard + MB + RAM, same colour at boot):
sudo ./install.sh

# Static colour + temperature-based colour changes every 60s:
sudo ./install.sh --with-temp-watch
```

Then **log out and back in** so your user picks up the `plugdev` and `i2c`
group memberships added by the installer.

### apt dependencies installed automatically

- `i2c-tools` — provides `i2cdetect`, useful for diagnostics
- `usbutils` — provides `lsusb`
- `python3` — runtime
- `python3-smbus` — SMBus bindings for `ene-dram-set-color`

---

## Changing the colour

Edit one line in the service file:

```bash
sudo systemctl edit --full rgb-static.service
# change ExecStart=/usr/local/bin/rgb-set-all 00BFFF 4
# e.g.:  ExecStart=/usr/local/bin/rgb-set-all FF0000 5
sudo systemctl daemon-reload && sudo systemctl restart rgb-static.service
```

Or apply immediately without restarting the service:

```bash
sudo /usr/local/bin/rgb-set-all RRGGBB [brightness 1-5]
```

---

## Temperature-based colour watcher

If installed with `--with-temp-watch`, `rgb-temp.timer` fires `rgb-temp-watch`
at boot+30s and every 60s after that. The watcher reads the highest CPU sensor
via sysfs and maps it to a colour band:

| CPU temp | Colour |
|----------|--------|
| < 45°C | blue `#0044FF` |
| < 60°C | cyan `#00DDCC` |
| < 72°C | green `#00FF44` |
| < 82°C | orange `#FF6600` |
| ≥ 82°C | red `#FF0000` |

The watcher only writes to hardware when the band changes (state in
`/run/rgb-temp-watch.band`), so the keyboard does not flicker every minute.

Customise bands in `/usr/local/bin/rgb-temp-watch` under the `BANDS` list.

---

## Device driver reference

### 1. MSI Vigor GK50 Low Profile — `gk50-set-color`

**Protocol:** 64-byte raw HID interrupt OUT writes to hidraw. No report-ID
prefix. Each write gets a 64-byte IN ACK — always drain it (0.3 s timeout).

**Finding the device:** scan `/sys/class/hidraw/hidraw*/device/uevent` for VID
`0db0`, PID `0b5a`, and `input1` (interface 1, usage page `0xFF00`).

**Static colour sequence:**

```
Step 1 — stop any active animation:
  → 41 80 00...  (x2)          BEGIN (twice, required)
  → 51 28 00 00 0C 00...       COMMIT mode=0x0C (off)
  → 50 55 00...                SAVE TO FLASH
  → 41 00 00...                END

Step 2 — apply colour:
  → 41 80 00...                BEGIN
  → 56 20 01 00...             READ group-01
  ← firmware returns 64-byte state
  patch: byte[1]=0x21, byte[48]=R, byte[49]=G, byte[50]=B, byte[51]=brightness
  → patched 64 bytes           WRITE group-01
  → 51 28 00 00 01 00...       COMMIT mode=0x01 (static)
  → 50 55 00...                SAVE TO FLASH
  → 41 00 00...                END
```

Brightness byte: `0x33`=20%, `0x66`=40%, `0x99`=60%, `0xCC`=80%, `0xFF`=100%.
SAVE TO FLASH is permanent — the keyboard retains the colour across power
cycles with no host software running.

**Reference:** OpenRGB C++ source: `Controllers/MSIVigorController/MSIVigorGK50LPController.cpp`
at `https://gitlab.com/strips1/OpenRGB` branch `add-msi-vigor-gk50-low-profile`.
The Python script is a direct translation of `SetOff()` + `SetStatic()` from that file.

---

### 2. MSI MAG Z390 TOMAHAWK Mystic Light — `mystic-light-set-color`

**Protocol:** USB HID **feature reports** (not interrupt writes).

**Finding the device:** scan hidraw sysfs for VID `1462`, PID `7b18`, `input0`
(interface 0, usage page `0x0001`). Interface 0 is the control interface.

**Packet:** 162-byte feature report, report-ID `0x52`.

```
byte 0        report ID = 0x52
bytes 1–160   zone data (10 bytes per zone × up to 16 zones)
byte 161      save_data  (1 = persist to flash)
```

Each 10-byte ZoneData block:
```
offset 0   effect          0x01 = static
offset 1–3 R, G, B
offset 4   speedAndBrightnessFlags  = (brightness_level << 2) | speed
           MSI_BRIGHTNESS_LEVEL_100 = 10  → 10<<2 = 0x28
offset 5–7 R2, G2, B2     (set to same colour)
offset 8   colorFlags      0x80 = fixed colour (bit 7); on_board_led also gets 0x81
offset 9   padding
```

Zone offsets for board `0x7B18` (MAG Z390 TOMAHAWK, `numof_onboard_leds=6`):

| Zone | Byte offset |
|------|------------|
| j_rgb_1 | 1 |
| j_rainbow_1 | 11 |
| on_board_led | 41 |
| on_board_led_1 | 51 |
| on_board_led_2 | 61 |
| on_board_led_3 | 71 |
| on_board_led_4 | 81 |
| on_board_led_5 | 91 |
| j_rgb_2 | 151 |

**ioctl numbers (64-bit Linux):**
```python
_HIDIOCGFEATURE(len) = 0xC0000000 | (len << 16) | (0x48 << 8) | 0x07
_HIDIOCSFEATURE(len) = 0xC0000000 | (len << 16) | (0x48 << 8) | 0x06
```
Both GET and SET use direction `0xC0` (`_IOC_WRITE|_IOC_READ`).

**Reference:** OpenRGB `Controllers/MSIMysticLight/MSIMysticLight162Controller.*`,
board config `{ 0x7B18, 6, &zones_set1 }`.

---

### 3. ENE DRAM sticks — `ene-dram-set-color`

**Protocol:** Linux SMBus (i2c-dev) via `python3-smbus`. The ENE chip uses
16-bit register addressing with a two-step write pattern.

**Addresses:** `/dev/i2c-0`, device addresses `0x70`–`0x73` (one per stick).

**Register access (16-bit address → byte value):**
```python
bus.write_word_data(addr, 0x00, byteswap(reg))   # set register pointer
bus.write_byte_data(addr, 0x01, val)              # write one byte
bus.write_block_data(addr, 0x03, [b0, b1, b2])   # write up to 3 bytes
bus.read_byte_data(addr,  0x81)                   # read one byte
```
`byteswap(reg)` = `((reg << 8) & 0xFF00) | ((reg >> 8) & 0x00FF)`.

**Key registers:**
```
0x1000  DEVICE_NAME     16 bytes — identifies V1 vs V2 controller
0x8010  COLORS_EFFECT   V1: R,B,G per LED × LED_COUNT  (e.g. Trident Z)
0x8160  COLORS_EFFECT_V2  V2: same layout  (e.g. Geil "AUDA0-E6K5-0101")
0x8021  MODE            0x01 = static
0x8022  SPEED           0x00
0x8023  DIRECTION       0x00
0x80A0  APPLY           write 0x01 to latch settings
```

**Color byte order: R, B, G** (blue and green are swapped vs normal RGB —
confirmed from OpenRGB source `SetLEDColorEffect`: `{red, blue, green}`).

**Sequence per stick:**
1. Read `DEVICE_NAME` → choose `COLORS_EFFECT` vs `COLORS_EFFECT_V2`
2. For each LED (0..7): `write_block` 3 bytes `[R, B, G]` at `effect_reg + led*3`
3. Write `APPLY=0x01` → `MODE=0x01` → `SPEED=0x00` → `DIRECTION=0x00` → `APPLY=0x01`

**Reference:** OpenRGB `Controllers/ENESMBusController/ENESMBusController.*`
and `ENESMBusInterface_i2c_smbus.*`.

---

## How to add a new RGB device

1. **Identify the hardware** — run `sudo /usr/local/bin/probe-rgb-hardware` and
   `sudo openrgb --list-devices` (OpenRGB for diagnostic use only).

2. **Find the protocol** — search the OpenRGB source for the VID/PID or chip
   name. The Python driver is a translation of the C++ controller's
   `SetMode()`/`SetLEDs()` methods.

3. **Write a script** in `scripts/` following the same pattern:
   - Takes one argument `RRGGBB` (plus optional extras)
   - Exits 0 on success, prints to stderr and exits 1 on error
   - Returns immediately if device not found (so `rgb-set-all` can skip it)

4. **Wire it in:**
   - `scripts/rgb-set-all` — add `if [[ -x /usr/local/bin/your-script ]]; then ...`
   - `scripts/rgb-temp-watch` — add `YOUR_BIN` constant and call in `apply_all()`
   - `udev/60-rgb-devices.rules` — add a hidraw or i2c-dev access rule
   - `install.sh` — add `install -m 0755 ...` line and any new apt dep

5. **Test standalone first:**
   ```bash
   sudo /usr/local/bin/your-script 00BFFF
   ```
   Then test via the wrapper:
   ```bash
   sudo /usr/local/bin/rgb-set-all 00BFFF 4
   ```

---

## Troubleshooting

**Device not found (keyboard/MB):**
```bash
ls /sys/class/hidraw/*/device/uevent | xargs grep -l "0db0\|1462"
```
If empty, the device is not enumerated. Check USB connection / power.

**ENE DRAM not responding:**
```bash
sudo modprobe i2c-dev
ls /dev/i2c-*
sudo i2cdetect -y 0
```
`i2cdetect` may show the addresses as free (ENE chips don't respond to quick
scan), but `ene-dram-set-color` will still reach them with the correct protocol.

**Permission denied on /dev/hidrawN or /dev/i2c-0:**
```bash
groups $USER   # should include plugdev and i2c
# If missing, log out and back in (group added during install)
```

**Check service status:**
```bash
systemctl status rgb-static.service
systemctl status rgb-temp.timer
journalctl -u rgb-temp.service -n 30
```

**Manual test of each driver:**
```bash
sudo /usr/local/bin/gk50-set-color 00BFFF 4
sudo /usr/local/bin/mystic-light-set-color 00BFFF
sudo /usr/local/bin/ene-dram-set-color 00BFFF
```

---

## Context for a future AI session

**What this project is:** A self-contained Linux tool (Python + systemd + udev)
that sets a static RGB colour on three MSI devices at every boot and USB
reconnect. No OpenRGB at runtime — OpenRGB was used only for hardware
identification during development.

**Installed file locations:**

| Source | Installed to |
|--------|-------------|
| `scripts/gk50-set-color` | `/usr/local/bin/gk50-set-color` |
| `scripts/mystic-light-set-color` | `/usr/local/bin/mystic-light-set-color` |
| `scripts/ene-dram-set-color` | `/usr/local/bin/ene-dram-set-color` |
| `scripts/rgb-set-all` | `/usr/local/bin/rgb-set-all` |
| `scripts/rgb-temp-watch` | `/usr/local/bin/rgb-temp-watch` |
| `scripts/probe-rgb-hardware` | `/usr/local/bin/probe-rgb-hardware` |
| `systemd/rgb-static.service` | `/etc/systemd/system/rgb-static.service` |
| `systemd/rgb-temp.service` | `/etc/systemd/system/rgb-temp.service` |
| `systemd/rgb-temp.timer` | `/etc/systemd/system/rgb-temp.timer` |
| `udev/60-rgb-devices.rules` | `/etc/udev/rules.d/60-rgb-devices.rules` |
| `modules-load.d/i2c-dev.conf` | `/etc/modules-load.d/i2c-dev.conf` |

**Active systemd units (with --with-temp-watch):**
- `rgb-temp.timer` enabled, fires `rgb-temp.service` at boot+30s + every 60s
- `rgb-static.service` disabled (superseded by timer)
- State file: `/run/rgb-temp-watch.band` (avoids writing hardware when band unchanged)

**Key protocol facts (gotchas):**
- Keyboard: each HID write must be followed by a read drain or the firmware buffers up
- Mystic Light ioctl: both GET and SET use direction `0xC0` (`_IOC_WRITE|_IOC_READ`),
  not `0x40`. Using `0x40` for SET returns `EINVAL`.
- ENE DRAM color byte order is **R, B, G** (blue and green swapped from RGB)
- ENE i2cdetect shows addresses as free — chips don't respond to quick scan but work fine
- SMBus max block write for ENE = 3 bytes (one LED at a time)

**OpenRGB diagnostic data (probe run during development):**
```
0: ENE DRAM  SMBus  /dev/i2c-0  addr 0x70  8 LEDs
1: ENE DRAM  SMBus  /dev/i2c-0  addr 0x71  8 LEDs
2: ENE DRAM  SMBus  /dev/i2c-0  addr 0x72  8 LEDs
3: ENE DRAM  SMBus  /dev/i2c-0  addr 0x73  8 LEDs
4: MSI MAG Z390 TOMAHAWK (MS-7B18)  HID  /dev/hidraw0  162-byte feature report
```
The keyboard does not appear in OpenRGB — its VID/PID was not in the OpenRGB
device list at the time. Protocol was reverse-engineered; see `gk50-rgb-setup.md`.
