# MSI Vigor GK50 Low Profile — Keyboard RGB Color on Boot / USB Reconnect

## Purpose

Set a static color and brightness on the MSI Vigor GK50 Low Profile keyboard
automatically at every boot and USB reconnect, without needing OpenRGB or any
GUI. Self-contained Python script + udev + systemd.

---

## Hardware

| Property        | Value                          |
|-----------------|-------------------------------|
| USB VID         | `0x0DB0`                      |
| USB PID         | `0x0B5A`                      |
| HID interface   | 1 (usage page `0xFF00`, usage `0x01`) |
| hidraw device   | whichever `/dev/hidrawN` maps to `input1` for this VID/PID |
| Report size     | 64 bytes, NO HID report-ID prefix |
| Write method    | `hid_write()` (plain 64-byte interrupt OUT) |

---

## Protocol — Static Color Transaction

All packets are 64 bytes. Bytes not listed are `0x00`.

### 1. Stop any active animation (OFF)
Send `41 80` **twice**, then commit, save, end:

```
→ 41 80 00 00 ... (64 bytes)        BEGIN (repeat twice)
→ 41 80 00 00 ... (64 bytes)        BEGIN (again — required by firmware)
→ 51 28 00 00 0C 00 ... (64 bytes)  COMMIT mode=0x0C (Off)
→ 50 55 00 00 ... (64 bytes)        SAVE TO FLASH
→ 41 00 00 00 ... (64 bytes)        END
```

After each write the firmware sends a 64-byte IN response — drain it with a
read (0.3 s timeout). Ignore the content.

### 2. Apply static color
```
→ 41 80 00 00 ... (64 bytes)        BEGIN
→ 56 20 01 00 ... (64 bytes)        READ group-01 (current steady state)
← 56 20 01 ...   (64 bytes)        firmware responds with current state
  (patch the response:)
    byte[1]  = 0x21                 change read (0x20) → write (0x21)
    byte[48] = R                    red   0x00–0xFF
    byte[49] = G                    green 0x00–0xFF
    byte[50] = B                    blue  0x00–0xFF
    byte[51] = brightness           0x33=20%, 0x66=40%, 0x99=60%, 0xCC=80%, 0xFF=100%
→ send modified 64-byte packet      WRITE group-01
→ 51 28 00 00 01 00 ... (64 bytes)  COMMIT mode=0x01 (Static)
→ 50 55 00 00 ... (64 bytes)        SAVE TO FLASH
→ 41 00 00 00 ... (64 bytes)        END
```

The SAVE TO FLASH (`50 55`) writes to the keyboard's own flash. The color
persists across USB power cycles with no host software running.

---

## Minimal Python Script

Save as `/usr/local/bin/gk50-set-color`:

```python
#!/usr/bin/env python3
"""Set a static color on the MSI Vigor GK50 Low Profile keyboard.

Usage:
    gk50-set-color RRGGBB [brightness]
    gk50-set-color FF0000       # red, full brightness
    gk50-set-color 0000FF 3     # blue, 60% brightness

Brightness levels 1–5:
    1 = 20%  (0x33)
    2 = 40%  (0x66)
    3 = 60%  (0x99)
    4 = 80%  (0xCC)
    5 = 100% (0xFF)  [default]
"""

import os
import sys
import glob
import select
import time

VID = "0db0"
PID = "0b5a"
IFACE = "input1"
REPORT_SIZE = 64
READ_TIMEOUT = 0.3

BRIGHTNESS = [0x33, 0x66, 0x99, 0xCC, 0xFF]


def find_device():
    for path in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        try:
            ue = open(f"{path}/device/uevent").read().lower()
            if VID in ue and PID in ue and IFACE in ue:
                return f"/dev/{os.path.basename(path)}"
        except OSError:
            pass
    return None


def pkt(buf):
    b = bytes(buf)
    return b + bytes(REPORT_SIZE - len(b))


def write_drain(fd, buf):
    os.write(fd, pkt(buf))
    r, _, _ = select.select([fd], [], [], READ_TIMEOUT)
    if r:
        os.read(fd, REPORT_SIZE)


def set_color(r, g, b, brightness_level=5):
    bri = BRIGHTNESS[max(1, min(5, brightness_level)) - 1]

    dev = find_device()
    if dev is None:
        print("ERROR: GK50 LP not found", file=sys.stderr)
        sys.exit(1)

    fd = os.open(dev, os.O_RDWR | os.O_NONBLOCK)

    # --- stop any active animation (OFF) ---
    write_drain(fd, [0x41, 0x80])
    write_drain(fd, [0x41, 0x80])
    write_drain(fd, [0x51, 0x28, 0x00, 0x00, 0x0C])
    write_drain(fd, [0x50, 0x55])
    write_drain(fd, [0x41, 0x00])

    # --- apply static color ---
    write_drain(fd, [0x41, 0x80])

    # read current group-01 state
    os.write(fd, pkt([0x56, 0x20, 0x01]))
    rr, _, _ = select.select([fd], [], [], 0.5)
    cur = bytearray(os.read(fd, REPORT_SIZE)) if rr else bytearray(REPORT_SIZE)

    cur[1]  = 0x21
    cur[48] = r
    cur[49] = g
    cur[50] = b
    cur[51] = bri

    write_drain(fd, cur)
    write_drain(fd, [0x51, 0x28, 0x00, 0x00, 0x01])
    write_drain(fd, [0x50, 0x55])
    write_drain(fd, [0x41, 0x00])

    os.close(fd)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    hex_color = sys.argv[1].lstrip("#")
    r = int(hex_color[0:2], 16)
    g = int(hex_color[2:4], 16)
    b = int(hex_color[4:6], 16)
    level = int(sys.argv[2]) if len(sys.argv) > 2 else 5

    set_color(r, g, b, level)
```

Make it executable:
```bash
sudo chmod +x /usr/local/bin/gk50-set-color
```

Test it:
```bash
sudo /usr/local/bin/gk50-set-color FF0000      # red, full brightness
sudo /usr/local/bin/gk50-set-color 0000FF 3    # blue, 60%
```

---

## udev Rule — Non-root Access

Without this the script must run as root. Create
`/etc/udev/rules.d/60-gk50-rgb.rules`:

```
# MSI Vigor GK50 Low Profile — grant hidraw access to the plugdev group
# Interface 1 (RGB) is the second hidraw node enumerated for this device.
# The ATTRS{bInterfaceNumber}=="01" match pins it to the correct interface.
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="0db0", ATTRS{idProduct}=="0b5a", \
    ATTRS{bInterfaceNumber}=="01", TAG+="uaccess", GROUP="plugdev", MODE="0660"
```

Reload:
```bash
sudo udevadm control --reload-rules && sudo udevadm trigger
```

Add yourself to `plugdev` if not already a member:
```bash
sudo usermod -aG plugdev $USER   # log out and back in after this
```

---

## systemd Service — Run on Boot

`/etc/systemd/system/gk50-rgb.service`:

```ini
[Unit]
Description=Set MSI Vigor GK50 Low Profile keyboard color
After=systemd-udev-settle.service
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
# Edit color (RRGGBB) and brightness (1-5) here:
ExecStart=/usr/local/bin/gk50-set-color FF0000 5
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

Enable:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now gk50-rgb.service
```

---

## udev Rule — Re-apply on USB Reconnect

When the keyboard is unplugged and replugged, systemd can re-run the script.
The trick is to trigger only when the RGB hidraw interface (interface 1) appears.

Append to `/etc/udev/rules.d/60-gk50-rgb.rules` (same file as the access rule):

```
# Re-apply color when the keyboard is reconnected
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="0db0", ATTRS{idProduct}=="0b5a", \
    ATTRS{bInterfaceNumber}=="01", ACTION=="add", \
    RUN+="/bin/systemctl start gk50-rgb.service"
```

Reload rules again:
```bash
sudo udevadm control --reload-rules
```

No additional unit file needed — it reuses the boot service.

> **Note:** `systemctl start` from a udev rule is synchronous enough for a
> oneshot service. If the keyboard takes a moment to be ready after enumeration,
> add a short `ExecStartPre=/bin/sleep 1` to the service.

---

## Configuration Summary

To change the color, edit one line in the service file:

```bash
sudo systemctl edit --full gk50-rgb.service
# change: ExecStart=/usr/local/bin/gk50-set-color FF0000 5
# to e.g.: ExecStart=/usr/local/bin/gk50-set-color 00FF88 4
sudo systemctl daemon-reload
sudo systemctl restart gk50-rgb.service
```

Or run the script directly at any time:
```bash
/usr/local/bin/gk50-set-color RRGGBB [1-5]
```

---

## File Checklist

| File | Purpose |
|------|---------|
| `/usr/local/bin/gk50-set-color` | Python script, chmod +x |
| `/etc/udev/rules.d/60-gk50-rgb.rules` | hidraw access + USB reconnect trigger |
| `/etc/systemd/system/gk50-rgb.service` | Boot service + reconnect target |

---

## Context for a New Copilot Session

**Hardware:** MSI Vigor GK50 Low Profile keyboard. VID `0x0DB0`, PID `0x0B5A`.
RGB is controlled via HID interface 1 (usage page `0xFF00`, usage `0x01`).
The matching hidraw node is the one whose sysfs uevent contains both the
VID/PID and `input1`.

**Protocol:** 64-byte raw HID writes, no report-ID prefix. Each write gets a
64-byte IN response that must be drained. Static color requires: double-begin
OFF transaction to stop animations, then begin → read-modify-write group-01
(bytes 48=R, 49=G, 50=B, 51=brightness) → commit 0x01 → save to flash → end.
Flash save is permanent — the keyboard retains color across power cycles.

**Working reference implementation:** the full OpenRGB C++ driver lives at
`Controllers/MSIVigorController/` in the OpenRGB fork at
`https://gitlab.com/strips1/OpenRGB` (branch `add-msi-vigor-gk50-low-profile`).
The Python logic in `/usr/local/bin/gk50-set-color` above is a direct
translation of `SetOff()` + `SetStatic()` from `MSIVigorGK50LPController.cpp`.
