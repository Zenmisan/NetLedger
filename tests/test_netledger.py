#!/usr/bin/env python3
"""
Unit and integration tests for NetLedger daemon and lineage resolution.
"""

import os
import sqlite3
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from daemon.netledgerd import (
    LedgerStorage,
    resolve_root_group,
    LINEAGE_CACHE
)


class TestNetLedgerLineage(unittest.TestCase):

    def setUp(self):
        LINEAGE_CACHE.clear()

    @patch("daemon.netledgerd.read_proc_node")
    def test_updater_attribution(self, mock_read):
        # PID 1003 (curl) -> PID 1002 (makepkg) -> PID 1001 (yay) -> PID 1 (systemd)
        mock_read.side_effect = lambda pid: {
            1003: {"pid": 1003, "ppid": 1002, "comm": "curl", "cmdline": "curl https://example.com", "cgroup": "user@1000.service"},
            1002: {"pid": 1002, "ppid": 1001, "comm": "makepkg", "cmdline": "makepkg -si", "cgroup": "user@1000.service"},
            1001: {"pid": 1001, "ppid": 1, "comm": "yay", "cmdline": "yay -Syu", "cgroup": "user@1000.service"},
            1: {"pid": 1, "ppid": 0, "comm": "systemd", "cmdline": "/sbin/init", "cgroup": ""}
        }.get(pid)

        root, cat, child, detail = resolve_root_group(1003)
        self.assertEqual(root, "System Update (yay)")
        self.assertEqual(cat, "update")
        self.assertEqual(child, "curl")
        self.assertIn("curl https://example.com", detail)

    @patch("daemon.netledgerd.read_proc_node")
    def test_docker_container_attribution(self, mock_read):
        # PID 2001 (postgres inside docker)
        mock_read.side_effect = lambda pid: {
            2001: {"pid": 2001, "ppid": 1, "comm": "postgres", "cmdline": "postgres", "cgroup": "/system.slice/docker-abc.scope"}
        }.get(pid)

        root, cat, child, _detail = resolve_root_group(2001)
        self.assertEqual(root, "Docker Containers")
        self.assertEqual(cat, "container")
        self.assertEqual(child, "postgres")

    @patch("daemon.netledgerd.read_proc_node")
    def test_shell_bypass_attribution(self, mock_read):
        # PID 3003 (bun) -> PID 3002 (zsh) -> PID 3001 (alacritty) -> PID 1 (systemd)
        mock_read.side_effect = lambda pid: {
            3003: {"pid": 3003, "ppid": 3002, "comm": "bun", "cmdline": "bun install", "cgroup": "user@1000.service"},
            3002: {"pid": 3002, "ppid": 3001, "comm": "zsh", "cmdline": "/bin/zsh", "cgroup": "user@1000.service"},
            3001: {"pid": 3001, "ppid": 1, "comm": "alacritty", "cmdline": "alacritty", "cgroup": "app-alacritty.scope"},
            1: {"pid": 1, "ppid": 0, "comm": "systemd", "cmdline": "/sbin/init", "cgroup": ""}
        }.get(pid)

        root, cat, child, _detail = resolve_root_group(3003)
        self.assertEqual(root, "bun")
        self.assertEqual(cat, "app")
        self.assertEqual(child, "bun")


class TestLedgerStorage(unittest.TestCase):

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self.temp_dir.name, "test_ledger.db")
        self.storage = LedgerStorage(self.db_path)

    def tearDown(self):
        self.storage.conn.close()
        self.temp_dir.cleanup()

    def test_database_initialization(self):
        cur = self.storage.conn.cursor()
        cur.execute("PRAGMA journal_mode;")
        mode = cur.fetchone()[0]
        self.assertEqual(mode.lower(), "wal")

    def test_delta_recording(self):
        now = int(time.time() // 300) * 300
        deltas = {
            (now, "System Update (yay)", "update", "pacman", "sync"): (1024, 256),
            (now, "Brave Browser", "app", "brave", "renderer"): (4096, 512)
        }
        self.storage.record_deltas(deltas)

        # Record additional delta for pacman
        self.storage.record_deltas({
            (now, "System Update (yay)", "update", "pacman", "sync"): (512, 128)
        })

        cur = self.storage.conn.cursor()
        cur.execute("SELECT rx_bytes, tx_bytes FROM rollup_5min WHERE child_comm = 'pacman';")
        rx, tx = cur.fetchone()
        self.assertEqual(rx, 1536)
        self.assertEqual(tx, 384)

    def test_live_state_and_summary(self):
        live_records = [
            (1234, "Brave Browser", "app", "brave", "network", 2048.0, 512.0)
        ]
        self.storage.update_live_state(
            live_records,
            total_rx_rate=2048.0,
            total_tx_rate=512.0,
            top_process="Brave Browser",
            top_category="app"
        )

        cur = self.storage.conn.cursor()
        cur.execute("SELECT rx_rate, tx_rate, top_process FROM live_summary WHERE id = 1;")
        row = cur.fetchone()
        self.assertAlmostEqual(row[0], 2048.0)
        self.assertAlmostEqual(row[1], 512.0)
        self.assertEqual(row[2], "Brave Browser")


if __name__ == "__main__":
    unittest.main()
