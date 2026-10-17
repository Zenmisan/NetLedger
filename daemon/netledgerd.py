#!/usr/bin/env python3
"""
NetLedger Daemon (netledgerd)
System-wide network telemetry collector with upward process lineage attribution
and dual-tier SQLite time-series rollups.
"""

import argparse
import logging
import os
import re
import select
import shutil
import signal
import sqlite3
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, Optional, Set, Tuple

# Configuration & Constants from NetLedger Architecture Blueprint
SHELLS_AND_TERMS: Set[str] = {
    "bash", "zsh", "fish", "sh", "sudo", "su",
    "alacritty", "kitty", "foot", "wezterm", "tmux"
}

UPDATE_MANAGERS: Set[str] = {
    "pacman", "yay", "paru", "makepkg", "fwupdmgr", "flatpak", "rustup"
}

SESSION_ROOTS: Set[str] = {
    "systemd", "Hyprland", "uwsm", "quickshell", "init"
}

# Cache for resolved PIDs (pid -> (timestamp, result))
LINEAGE_CACHE: Dict[int, Tuple[float, Tuple[str, str, str, str]]] = {}
CACHE_TTL_SEC = 5.0

logger = logging.getLogger("netledgerd")


def read_proc_node(pid: int) -> Optional[dict]:
    """Reads /proc/<pid> metadata safely."""
    try:
        p = Path(f"/proc/{pid}")
        comm = (p / "comm").read_text().strip()
        cmdline = (p / "cmdline").read_text().replace("\x00", " ").strip()
        stat_tail = (p / "stat").read_text().rsplit(")", 1)[1].split()
        ppid = int(stat_tail[1])
        cgroup = (p / "cgroup").read_text().strip()
        return {
            "pid": pid,
            "ppid": ppid,
            "comm": comm,
            "cmdline": cmdline,
            "cgroup": cgroup
        }
    except Exception:
        return None


def resolve_root_group(pid: int) -> Tuple[str, str, str, str]:
    """
    Returns (root_group, category, child_comm, child_detail)
    Walks up /proc/<pid>/stat and /proc/<pid>/cgroup hierarchy.
    """
    now = time.time()
    if pid in LINEAGE_CACHE:
        cached_time, cached_res = LINEAGE_CACHE[pid]
        if now - cached_time < CACHE_TTL_SEC:
            return cached_res

    chain, curr, seen = [], pid, set()
    while curr > 1 and curr not in seen:
        seen.add(curr)
        node = read_proc_node(curr)
        if not node:
            break
        chain.append(node)
        curr = node["ppid"]

    if not chain:
        res = ("System / Kernel", "system", f"pid-{pid}", "Ephemeral socket")
        LINEAGE_CACHE[pid] = (now, res)
        return res

    leaf = chain[0]

    # 1. Attribute all child workers (curl, git-remote-https, gpg) to parent System Updater
    for anc in reversed(chain):
        if anc["comm"] in UPDATE_MANAGERS:
            res = (
                f"System Update ({anc['comm']})",
                "update",
                leaf["comm"],
                leaf["cmdline"][:70] or leaf["comm"]
            )
            LINEAGE_CACHE[pid] = (now, res)
            return res

    # 2. Attribute Docker / containerd cgroup slices
    if "docker" in leaf["cgroup"] or "containerd" in leaf["cgroup"]:
        res = (
            "Docker Containers",
            "container",
            leaf["comm"],
            leaf["cmdline"][:70] or leaf["comm"]
        )
        LINEAGE_CACHE[pid] = (now, res)
        return res

    # 3. Walk top-down past session managers and shells to find primary GUI App or Dev Runtime
    for anc in reversed(chain):
        c = anc["comm"]
        if c not in SESSION_ROOTS and c not in SHELLS_AND_TERMS:
            detail = leaf["cmdline"][:70] if leaf["comm"] != c else f"{c} (main/service)"
            res = (c, "app", leaf["comm"], detail)
            LINEAGE_CACHE[pid] = (now, res)
            return res

    # Fallback to CLI leaf process
    res = (leaf["comm"], "cli", leaf["comm"], leaf["cmdline"][:70] or leaf["comm"])
    LINEAGE_CACHE[pid] = (now, res)
    return res


class LedgerStorage:
    def __init__(self, db_path: str):
        self.db_path = Path(db_path)
        self._ensure_dir()
        self.conn = sqlite3.connect(str(self.db_path), timeout=10.0, check_same_thread=False)
        self._init_db()

    def _ensure_dir(self):
        try:
            self.db_path.parent.mkdir(parents=True, exist_ok=True)
        except PermissionError:
            fallback = Path.home() / ".local/share/netledger/ledger.db"
            logger.warning("Permission denied for %s, falling back to %s", self.db_path, fallback)
            fallback.parent.mkdir(parents=True, exist_ok=True)
            self.db_path = fallback

    def _init_db(self):
        cur = self.conn.cursor()
        cur.execute("PRAGMA journal_mode = WAL;")
        cur.execute("PRAGMA synchronous = NORMAL;")

        # Tier 1: 5-minute buckets (Retained for 14 days)
        cur.execute("""
            CREATE TABLE IF NOT EXISTS rollup_5min (
                bucket_ts     INTEGER NOT NULL,
                root_group    TEXT NOT NULL,
                category      TEXT NOT NULL,
                child_comm    TEXT NOT NULL,
                child_detail  TEXT NOT NULL,
                rx_bytes      INTEGER DEFAULT 0,
                tx_bytes      INTEGER DEFAULT 0,
                PRIMARY KEY (bucket_ts, root_group, child_comm, child_detail)
            );
        """)
        cur.execute("CREATE INDEX IF NOT EXISTS idx_rollup_5min_ts ON rollup_5min(bucket_ts);")

        # Tier 2: 1-hour buckets (Retained for 400+ days)
        cur.execute("""
            CREATE TABLE IF NOT EXISTS rollup_1hour (
                bucket_ts     INTEGER NOT NULL,
                root_group    TEXT NOT NULL,
                category      TEXT NOT NULL,
                child_comm    TEXT NOT NULL,
                child_detail  TEXT NOT NULL,
                rx_bytes      INTEGER DEFAULT 0,
                tx_bytes      INTEGER DEFAULT 0,
                PRIMARY KEY (bucket_ts, root_group, child_comm, child_detail)
            );
        """)
        cur.execute("CREATE INDEX IF NOT EXISTS idx_rollup_1hour_ts ON rollup_1hour(bucket_ts);")

        # Live Real-time rates (updated every 2 seconds for BarWidget.qml)
        cur.execute("""
            CREATE TABLE IF NOT EXISTS live_state (
                updated_at    INTEGER NOT NULL,
                pid           INTEGER NOT NULL,
                root_group    TEXT NOT NULL,
                category      TEXT NOT NULL,
                child_comm    TEXT NOT NULL,
                child_detail  TEXT NOT NULL,
                rx_rate       REAL DEFAULT 0,
                tx_rate       REAL DEFAULT 0,
                PRIMARY KEY (pid)
            );
        """)

        cur.execute("""
            CREATE TABLE IF NOT EXISTS live_summary (
                id            INTEGER PRIMARY KEY CHECK (id = 1),
                updated_at    INTEGER NOT NULL,
                rx_rate       REAL DEFAULT 0,
                tx_rate       REAL DEFAULT 0,
                top_process   TEXT DEFAULT '',
                top_category  TEXT DEFAULT ''
            );
        """)

        self.conn.commit()

        # Set file permissions to 0644 so Quickshell unprivileged UI can read in WAL mode
        try:
            os.chmod(self.db_path, 0o644)
        except Exception as e:
            logger.debug("Could not chmod db: %s", e)

    def record_deltas(self, deltas: Dict[Tuple[int, str, str, str, str], Tuple[int, int]]):
        """
        Commit byte deltas to rollup_5min.
        deltas: (bucket_ts, root_group, category, child_comm, child_detail) -> (rx_bytes, tx_bytes)
        """
        if not deltas:
            return

        cur = self.conn.cursor()
        sql = """
            INSERT INTO rollup_5min (bucket_ts, root_group, category, child_comm, child_detail, rx_bytes, tx_bytes)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(bucket_ts, root_group, child_comm, child_detail) DO UPDATE SET
                rx_bytes = rollup_5min.rx_bytes + excluded.rx_bytes,
                tx_bytes = rollup_5min.tx_bytes + excluded.tx_bytes;
        """
        rows = [
            (bucket_ts, root_group, category, child_comm, child_detail, rx, tx)
            for (bucket_ts, root_group, category, child_comm, child_detail), (rx, tx) in deltas.items()
        ]
        cur.executemany(sql, rows)
        self.conn.commit()

    def update_live_state(self, live_records: list, total_rx_rate: float, total_tx_rate: float, top_process: str, top_category: str):
        cur = self.conn.cursor()
        now = int(time.time())

        cur.execute("DELETE FROM live_state;")
        if live_records:
            sql = """
                INSERT OR REPLACE INTO live_state (updated_at, pid, root_group, category, child_comm, child_detail, rx_rate, tx_rate)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
            cur.executemany(sql, [(now, r[0], r[1], r[2], r[3], r[4], r[5], r[6]) for r in live_records])

        cur.execute("""
            INSERT OR REPLACE INTO live_summary (id, updated_at, rx_rate, tx_rate, top_process, top_category)
            VALUES (1, ?, ?, ?, ?, ?);
        """, (now, total_rx_rate, total_tx_rate, top_process, top_category))
        self.conn.commit()

    def prune_and_rollup(self):
        """
        Roll up older 5-minute buckets into 1-hour buckets and prune expired rows.
        - rollup_5min retention: 14 days
        - rollup_1hour retention: 400 days
        """
        cur = self.conn.cursor()
        now = int(time.time())
        one_hour_ago = now - 3600
        fourteen_days_ago = now - (14 * 86400)
        four_hundred_days_ago = now - (400 * 86400)

        # 1. Rollup 5min buckets older than 1 hour into rollup_1hour
        rollup_sql = """
            INSERT INTO rollup_1hour (bucket_ts, root_group, category, child_comm, child_detail, rx_bytes, tx_bytes)
            SELECT
                (bucket_ts / 3600) * 3600 AS h_bucket,
                root_group,
                category,
                child_comm,
                child_detail,
                SUM(rx_bytes),
                SUM(tx_bytes)
            FROM rollup_5min
            WHERE bucket_ts <= ?
            GROUP BY h_bucket, root_group, child_comm, child_detail
            ON CONFLICT(bucket_ts, root_group, child_comm, child_detail) DO UPDATE SET
                rx_bytes = rollup_1hour.rx_bytes + excluded.rx_bytes,
                tx_bytes = rollup_1hour.tx_bytes + excluded.tx_bytes;
        """
        cur.execute(rollup_sql, (one_hour_ago,))

        # 2. Prune rollup_5min older than 14 days
        cur.execute("DELETE FROM rollup_5min WHERE bucket_ts < ?;", (fourteen_days_ago,))

        # 3. Prune rollup_1hour older than 400 days
        cur.execute("DELETE FROM rollup_1hour WHERE bucket_ts < ?;", (four_hundred_days_ago,))

        self.conn.commit()
        logger.info("Executed database maintenance and retention pruning.")


class NetHogsCollector:
    """Spawns and streams bandwidth output from `nethogs -t -v 2`."""

    def __init__(self):
        self.process = None

    def start(self):
        cmd = ["nethogs", "-t", "-v", "2"]
        logger.info("Starting nethogs stream: %s", " ".join(cmd))
        self.process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1
        )

    def read_samples(self, timeout=2.0):
        """
        Reads lines from nethogs stdout until refreshing or timeout.
        Returns list of (pid, sent_kbs, recv_kbs).
        """
        if not self.process or self.process.poll() is not None:
            self.start()

        rlist, _, _ = select.select([self.process.stdout], [], [], timeout)
        if not rlist:
            return []

        samples = []
        # Sample nethogs line format:
        # /usr/bin/curl/14612/1000	2.5	140.2
        # or: prog/pid/uid  sent_kb/s  recv_kb/s
        pattern = re.compile(r"^(.+?)/(\d+)/(\d+)\s+([\d.]+)\s+([\d.]+)")

        while True:
            rlist, _, _ = select.select([self.process.stdout], [], [], 0.05)
            if not rlist:
                break
            line = self.process.stdout.readline()
            if not line:
                break
            line = line.strip()
            if not line or "Refreshing" in line:
                continue

            m = pattern.match(line)
            if m:
                _prog, pid_str, _uid, sent_kbs, recv_kbs = m.groups()
                try:
                    pid = int(pid_str)
                    tx_rate = float(sent_kbs) * 1024.0  # to bytes/sec
                    rx_rate = float(recv_kbs) * 1024.0
                    samples.append((pid, tx_rate, rx_rate))
                except ValueError:
                    continue

        return samples

    def stop(self):
        if self.process:
            try:
                self.process.terminate()
                self.process.wait(timeout=2)
            except Exception:
                self.process.kill()


class ProcNetFallbackCollector:
    """
    Fallback collector when nethogs is not installed.
    Monitors /proc/net/dev for interface deltas and inspects active connections.
    """

    def __init__(self):
        self.last_time = time.time()
        self.last_totals = self._read_net_dev()

    def _read_net_dev(self) -> Tuple[int, int]:
        rx_total, tx_total = 0, 0
        try:
            lines = Path("/proc/net/dev").read_text().splitlines()[2:]
            for line in lines:
                parts = line.split(":")
                if len(parts) != 2:
                    continue
                iface = parts[0].strip()
                if iface == "lo":
                    continue
                fields = parts[1].split()
                rx_total += int(fields[0])
                tx_total += int(fields[8])
        except Exception as e:
            logger.debug("Error reading /proc/net/dev: %s", e)
        return rx_total, tx_total

    def read_samples(self, timeout=2.0):
        time.sleep(timeout)
        now = time.time()
        dt = max(now - self.last_time, 0.1)
        curr_rx, curr_tx = self._read_net_dev()

        delta_rx = max(0, curr_rx - self.last_totals[0])
        delta_tx = max(0, curr_tx - self.last_totals[1])

        self.last_time = now
        self.last_totals = (curr_rx, curr_tx)

        rx_rate = delta_rx / dt
        tx_rate = delta_tx / dt

        if rx_rate < 1.0 and tx_rate < 1.0:
            return []

        # Find active network PID to attribute or assign to system
        active_pid = os.getpid()
        try:
            # Check for high active network connections in /proc/net/tcp
            lines = Path("/proc/net/tcp").read_text().splitlines()[1:]
            for line in lines:
                parts = line.split()
                if len(parts) > 9 and parts[3] == "01":  # ESTABLISHED
                    inode = parts[9]
                    # Attempt quick lookup in /proc/*/fd/
                    for p in Path("/proc").glob("[0-9]*/fd/*"):
                        try:
                            if os.readlink(str(p)) == f"socket:[{inode}]":
                                active_pid = int(p.parts[2])
                                break
                        except Exception:
                            continue
        except Exception:
            pass

        return [(active_pid, tx_rate, rx_rate)]

    def stop(self):
        pass


def run_daemon(db_path: str, interval: float = 2.0):
    logger.info("Initializing NetLedger daemon on %s (interval: %ss)", db_path, interval)
    storage = LedgerStorage(db_path)

    has_nethogs = shutil.which("nethogs") is not None
    if has_nethogs:
        logger.info("nethogs binary found. Using NetHogsCollector.")
        collector = NetHogsCollector()
    else:
        logger.warning("nethogs binary not found in PATH! Falling back to ProcNetFallbackCollector.")
        collector = ProcNetFallbackCollector()

    running = True

    def sig_handler(_signum, _frame):
        nonlocal running
        logger.info("Shutdown signal received. Stopping...")
        running = False

    signal.signal(signal.SIGINT, sig_handler)
    signal.signal(signal.SIGTERM, sig_handler)

    last_prune_time = time.time()
    pending_deltas: Dict[Tuple[int, str, str, str, str], Tuple[int, int]] = {}

    try:
        while running:
            loop_start = time.time()
            samples = collector.read_samples(timeout=interval)

            now_epoch = int(time.time())
            bucket_5min = (now_epoch // 300) * 300

            live_records = []
            total_rx_rate = 0.0
            total_tx_rate = 0.0
            max_process_rate = 0.0
            top_process_name = ""
            top_process_cat = ""

            for pid, tx_rate, rx_rate in samples:
                total_rx_rate += rx_rate
                total_tx_rate += tx_rate

                root_group, category, child_comm, child_detail = resolve_root_group(pid)

                comb_rate = rx_rate + tx_rate
                if comb_rate > max_process_rate:
                    max_process_rate = comb_rate
                    top_process_name = root_group
                    top_process_cat = category

                live_records.append((
                    pid, root_group, category, child_comm, child_detail, rx_rate, tx_rate
                ))

                # Approximate cumulative byte deltas for this sample interval
                dt = max(interval, 0.1)
                rx_bytes = int(rx_rate * dt)
                tx_bytes = int(tx_rate * dt)

                if rx_bytes > 0 or tx_bytes > 0:
                    key = (bucket_5min, root_group, category, child_comm, child_detail)
                    curr_rx, curr_tx = pending_deltas.get(key, (0, 0))
                    pending_deltas[key] = (curr_rx + rx_bytes, curr_tx + tx_bytes)

            # Update live state in database
            storage.update_live_state(
                live_records,
                total_rx_rate,
                total_tx_rate,
                top_process_name,
                top_process_cat
            )

            # Flush bucket deltas to SQLite
            if pending_deltas:
                storage.record_deltas(pending_deltas)
                pending_deltas.clear()

            # Hourly rollup and maintenance
            if time.time() - last_prune_time > 3600:
                storage.prune_and_rollup()
                last_prune_time = time.time()

            # Clean cache periodically
            if len(LINEAGE_CACHE) > 5000:
                cutoff = time.time() - CACHE_TTL_SEC
                expired = [k for k, v in LINEAGE_CACHE.items() if v[0] < cutoff]
                for k in expired:
                    del LINEAGE_CACHE[k]

            elapsed = time.time() - loop_start
            sleep_time = max(0.1, interval - elapsed)
            time.sleep(sleep_time)

    finally:
        collector.stop()
        if pending_deltas:
            storage.record_deltas(pending_deltas)
        logger.info("NetLedger daemon terminated cleanly.")


def main():
    parser = argparse.ArgumentParser(description="NetLedger Telemetry Daemon")
    parser.add_argument(
        "--db-path",
        default=os.environ.get("NETLEDGER_DB", "/var/lib/netledger/ledger.db"),
        help="Path to SQLite ledger database (default: /var/lib/netledger/ledger.db)"
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=2.0,
        help="Collection loop interval in seconds (default: 2.0)"
    )
    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="Enable verbose debug logging"
    )

    args = parser.parse_args()

    log_level = logging.DEBUG if args.verbose else logging.INFO
    logging.basicConfig(
        level=log_level,
        format="[%(asctime)s] [%(levelname)s] (netledgerd) %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S"
    )

    run_daemon(db_path=args.db_path, interval=args.interval)


if __name__ == "__main__":
    main()
