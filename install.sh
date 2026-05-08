#!/usr/bin/env bash
# install.sh — install multi-device RGB static color + optional temperature service.
#
# Must be run as root (sudo ./install.sh).
# Run from the repo root (rgb-rescue/).
#
# Usage:
#   sudo ./install.sh                    # static color (keyboard only for now)
#   sudo ./install.sh --with-temp-watch  # temperature-based color changes
#
# No external dependencies beyond the Python standard library and apt packages.
#
# After install, edit the color in the service file:
#   sudo systemctl edit --full rgb-static.service
#   # change ExecStart line, then:
#   sudo systemctl daemon-reload && sudo systemctl restart rgb-static.service
#
# Or run directly at any time:
#   /usr/local/bin/rgb-set-all RRGGBB [1-5]

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
WITH_TEMP=0
[[ "${1:-}" == "--with-temp-watch" ]] && WITH_TEMP=1

echo "==> Installing apt dependencies..."
apt-get install -y --no-install-recommends i2c-tools usbutils python3 python3-smbus

echo "==> Installing RGB scripts..."

install -m 0755 "$REPO_DIR/scripts/gk50-set-color"           /usr/local/bin/gk50-set-color
install -m 0755 "$REPO_DIR/scripts/mystic-light-set-color"   /usr/local/bin/mystic-light-set-color
install -m 0755 "$REPO_DIR/scripts/ene-dram-set-color"       /usr/local/bin/ene-dram-set-color
install -m 0755 "$REPO_DIR/scripts/rgb-set-all"              /usr/local/bin/rgb-set-all
install -m 0755 "$REPO_DIR/scripts/probe-rgb-hardware"       /usr/local/bin/probe-rgb-hardware

if [[ $WITH_TEMP -eq 1 ]]; then
    install -m 0755 "$REPO_DIR/scripts/rgb-temp-watch" /usr/local/bin/rgb-temp-watch
fi

echo "==> Installing udev rules..."
install -m 0644 "$REPO_DIR/udev/60-rgb-devices.rules" /etc/udev/rules.d/60-rgb-devices.rules

echo "==> Loading i2c-dev module (needed for future MB/RAM RGB drivers)..."
install -m 0644 "$REPO_DIR/modules-load.d/i2c-dev.conf" /etc/modules-load.d/i2c-dev.conf
modprobe i2c-dev 2>/dev/null || true

udevadm control --reload-rules
udevadm trigger

echo "==> Adding current user to plugdev and i2c groups..."
REAL_USER="${SUDO_USER:-$USER}"
for GRP in plugdev i2c; do
    if ! id -nG "$REAL_USER" | grep -qw "$GRP"; then
        getent group "$GRP" &>/dev/null || groupadd --system "$GRP"
        usermod -aG "$GRP" "$REAL_USER"
        echo "    Added $REAL_USER to $GRP — log out and back in for this to take effect."
    else
        echo "    $REAL_USER is already in $GRP."
    fi
done

echo "==> Installing systemd units..."
install -m 0644 "$REPO_DIR/systemd/rgb-static.service" /etc/systemd/system/rgb-static.service

if [[ $WITH_TEMP -eq 1 ]]; then
    install -m 0644 "$REPO_DIR/systemd/rgb-temp.service" /etc/systemd/system/rgb-temp.service
    install -m 0644 "$REPO_DIR/systemd/rgb-temp.timer"   /etc/systemd/system/rgb-temp.timer
fi

systemctl daemon-reload

if [[ $WITH_TEMP -eq 1 ]]; then
    systemctl disable --now rgb-static.service 2>/dev/null || true
    systemctl enable  --now rgb-temp.timer
    echo
    echo "==> Temperature-based RGB enabled (keyboard)."
    echo "    Colors: <45°C blue  <60°C cyan  <72°C green  <82°C orange  >=82°C red"
    echo "    Edit bands in /usr/local/bin/rgb-temp-watch to taste."
else
    systemctl enable --now rgb-static.service
    echo
    echo "==> Static RGB enabled (keyboard)."
    echo "    Current color: see ExecStart in /etc/systemd/system/rgb-static.service"
    echo "    To change:     sudo systemctl edit --full rgb-static.service"
fi

echo
echo
echo "Done. Test with:"
echo "  /usr/local/bin/rgb-set-all 00BFFF 4"
