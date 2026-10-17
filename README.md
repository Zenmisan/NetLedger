# NetLedger (`dev.zenmi.netledger`)

**System-Wide Process Lineage Bandwidth Ledger for Omarchy & Quickshell**

NetLedger provides real-time and arbitrary multi-month network telemetry with upward process-tree attribution (`PPID` + `systemd` cgroup resolution), SQLite time-series dual-rollups, and a high-signal Quickshell user interface for the Omarchy status bar.

---

## Key Features

- **Upward Process Lineage Attribution**: Automatically traces obscure network worker binaries (`curl`, `git-remote-https`, `alpm`, sandboxed browser utility helpers) up `/proc/<pid>/stat` and `/proc/<pid>/cgroup` so traffic is grouped under human-meaningful parents (e.g. `System Update (yay / pacman)`, `Brave Browser`, `Bun Runtime`) while preserving full child worker breakdowns on click.
- **Strict Privilege Separation (Omarchy Quattro Compliant)**:
  - **Frontend UI (Unprivileged)**: Quickshell QML (`BarWidget.qml`, `Panel.qml`) runs with user permissions, executing zero `sudo` commands and running sub-3ms read queries against `/var/lib/netledger/ledger.db` in SQLite WAL mode (`0644`).
  - **Backend Daemon (Privileged)**: `netledgerd` systemd service accounts for network packet deltas, walks the process lineage, and writes time-series rollups.
- **Dual-Tier SQLite Time-Series Rollup**:
  - `rollup_5min`: 5-minute buckets retained for 14 days; drives `LIVE`, `24H`, `2D`, and `7D` granular views and sparklines.
  - `rollup_1hour`: 1-hour buckets retained for 400+ days; drives `30D` and custom multi-month queries with sub-3ms query latency.
- **Signature UI / UX Details**:
  - **Status Bar Pill (`BarWidget.qml`)**: Compact 85px pill displaying stacked live rates (`↓` Cyan Download, `↑` Amber Upload) and a dynamic icon/name badge of the #1 active bandwidth hog when throughput exceeds 100 KB/s.
  - **Interactive Time-Brush Histogram**: Chronological sparkline buckets where clicking any bar immediately isolates that specific 5-minute or 1-hour window.
  - **Preset & Free-Form Range Bar**: 1-click toggles (`LIVE`, `24H`, `2D`, `7D`, `30D`) alongside a collapsible input supporting relative offsets (`-36h`, `-14d`, `this-month`) and ISO dates (`2026-10-01 00:00`).
  - **Dual-Segment Proportional Bars**: Each process row splits horizontally into Cyan (Download share) and Amber (Upload share) normalized against the top group.

---

## Repository Structure

```text
NetLedger/
├── manifest.json              # Omarchy Quattro plugin contract (dev.zenmi.netledger)
├── BarWidget.qml              # Status bar pill component & panel popup host
├── Panel.qml                  # Detailed interactive telemetry & lineage flyout
├── Model.js                   # Stateless formatting, unit conversions & SQL parsing
├── daemon/
│   ├── netledgerd.py          # Background lineage resolution & packet collection daemon
│   └── netledgerd.service     # Systemd unit file for netledgerd
├── tests/
│   └── test_netledger.py      # Unit and integration tests
├── Makefile                   # Test, dev, and installation targets
├── install.sh                 # Installation helper script
└── README.md                  # Documentation
```

---

## Installation & Setup

### 1. Install Plugin for Quickshell / Omarchy

For live development (symlink):
```bash
make dev
# or: ./install.sh --dev
```

For standard installation (copy):
```bash
make install
# or: ./install.sh
```

### 2. Install and Start Background Daemon (`netledgerd`)

```bash
sudo cp daemon/netledgerd.py /usr/local/bin/netledgerd
sudo chmod +x /usr/local/bin/netledgerd
sudo cp daemon/netledgerd.service /etc/systemd/system/netledgerd.service
sudo systemctl daemon-reload
sudo systemctl enable --now netledgerd
```

Verify service status:
```bash
systemctl status netledgerd
```

### 3. Open NetLedger in Omarchy Bar

Click the NetLedger pill in your bar or summon directly via CLI:
```bash
omarchy-shell shell summon dev.zenmi.netledger
```

---

## Testing

Run the automated test suite:
```bash
make test
```
