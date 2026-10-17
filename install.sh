#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="dev.zenmi.netledger"
OMARCHY_PLUGINS_DIR="${HOME}/.config/omarchy/plugins"
TARGET_DIR="${OMARCHY_PLUGINS_DIR}/${PLUGIN_ID}"

echo "=========================================================="
echo "  NetLedger — Omarchy Quattro Plugin Installer"
echo "=========================================================="

# 1. Install or Symlink Quickshell Plugin
mkdir -p "${OMARCHY_PLUGINS_DIR}"

if [ "${1:-}" = "--dev" ]; then
    echo "[+] Development mode: Symlinking plugin to ${TARGET_DIR}..."
    rm -rf "${TARGET_DIR}"
    ln -s "${SCRIPT_DIR}" "${TARGET_DIR}"
    echo "[✓] Symlink created successfully."
else
    echo "[+] Standard mode: Copying plugin files to ${TARGET_DIR}..."
    rm -rf "${TARGET_DIR}"
    mkdir -p "${TARGET_DIR}"
    cp "${SCRIPT_DIR}/manifest.json" "${TARGET_DIR}/"
    cp "${SCRIPT_DIR}/BarWidget.qml" "${TARGET_DIR}/"
    cp "${SCRIPT_DIR}/Panel.qml" "${TARGET_DIR}/"
    cp "${SCRIPT_DIR}/Model.js" "${TARGET_DIR}/"
    echo "[✓] Plugin files installed to ${TARGET_DIR}."
fi

# 2. Check for dependencies
echo ""
echo "[+] Checking system dependencies..."
if command -v nethogs >/dev/null 2>&1; then
    echo "[✓] nethogs is installed."
else
    echo "[!] Notice: nethogs is recommended for packet accounting."
    echo "    Install with: sudo pacman -S nethogs"
fi

if command -v sqlite3 >/dev/null 2>&1; then
    echo "[✓] sqlite3 is installed."
else
    echo "[!] sqlite3 is required: sudo pacman -S sqlite"
fi

# 3. Systemd Daemon Service Installation
echo ""
echo "=========================================================="
echo "  NetLedger Daemon (netledgerd) Setup"
echo "=========================================================="

if [ "${1:-}" = "--service" ] || [ "${2:-}" = "--service" ]; then
    echo "[+] Installing and enabling netledgerd service (requires sudo)..."
    sudo cp "${SCRIPT_DIR}/daemon/netledgerd.py" /usr/local/bin/netledgerd
    sudo chmod +x /usr/local/bin/netledgerd
    sudo cp "${SCRIPT_DIR}/daemon/netledgerd.service" /etc/systemd/system/netledgerd.service
    sudo systemctl daemon-reload
    sudo systemctl enable --now netledgerd
    echo "[✓] netledgerd is now enabled and running on boot!"
else
    echo "To enable netledgerd on boot automatically, run:"
    echo "  ./install.sh --service"
    echo ""
    echo "Or run manually:"
    echo "  sudo cp \"${SCRIPT_DIR}/daemon/netledgerd.py\" /usr/local/bin/netledgerd"
    echo "  sudo chmod +x /usr/local/bin/netledgerd"
    echo "  sudo cp \"${SCRIPT_DIR}/daemon/netledgerd.service\" /etc/systemd/system/netledgerd.service"
    echo "  sudo systemctl daemon-reload"
    echo "  sudo systemctl enable --now netledgerd"
fi

echo ""
echo "To summon or view NetLedger in the Omarchy bar:"
echo "  omarchy-shell shell summon ${PLUGIN_ID}"
echo "=========================================================="
