#!/usr/bin/python3
"""Unit tests for snapman_client, the unprivileged code shared by the GUI and the CLI.

No root, no btrfs. Usage: python3 tests/test_client.py [-v]
"""

import datetime as dt
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src"))
import snapman_client as c  # noqa: E402

VOL = {"name": "Docker", "name_format": "{volume}_{timestamp}_{label}",
       "timestamp_format": "%Y-%m-%d_%H-%M-%S", "snapshot_dir": "/srv/snapshots/docker",
       "snapshots": [{}, {}, {}]}


class Names(unittest.TestCase):
    def test_sanitise_label(self):
        self.assertEqual(c.sanitise_label("before pihole v6"), "before_pihole_v6")
        self.assertEqual(c.sanitise_label("a/b.c:d!é"), "abcd")
        self.assertEqual(c.sanitise_label("x" * 100), "x" * 64)
        self.assertEqual(c.sanitise_label(""), "")

    def test_preview_name(self):
        ts = dt.datetime.now().strftime("%Y-%m-%d_%H-%M")
        name = c.preview_name(VOL, "before_pihole_v6")
        self.assertTrue(name.startswith(f"Docker_{ts}"), name)
        self.assertTrue(name.endswith("_before_pihole_v6"), name)

    def test_preview_name_empty_comment(self):
        # An empty label leaves no trailing or doubled separators
        name = c.preview_name(VOL, "")
        self.assertRegex(name, r"^Docker_\d{4}-\d\d-\d\d_\d\d-\d\d-\d\d$")
        v = dict(VOL, name_format="{timestamp}__{label}__{volume}")
        self.assertRegex(c.preview_name(v, ""), r"^\d{4}-\d\d-\d\d_\d\d-\d\d-\d\d_Docker$")
        v = dict(VOL, name_format="{label}-{timestamp}")
        self.assertRegex(c.preview_name(v, ""), r"^\d{4}")

    def test_times(self):
        now = dt.datetime.now().timestamp()
        self.assertEqual(c.fmt_age(now), "just now")
        self.assertEqual(c.fmt_age(now - 180), "3m ago")
        self.assertEqual(c.fmt_age(now - 7 * 86400 - 5), "7d ago")
        self.assertEqual(c.fmt_age(now + 100), "just now")
        self.assertRegex(c.fmt_time(now), r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$")


class Summaries(unittest.TestCase):
    def test_remove_summary_all_four(self):
        self.assertEqual(c.remove_summary(VOL, False, True, False),
                         "Only the registration is removed. Nothing on disk changes.")
        self.assertEqual(c.remove_summary(VOL, True, False, True),
                         "The subvolume, all 3 snapshot(s) and the snapshot folder are "
                         "deleted. Nothing is kept.")
        self.assertEqual(c.remove_summary(VOL, True, True, False),
                         "A final read-only snapshot is taken, then the subvolume is deleted. "
                         "Snapshots stay in /srv/snapshots/docker but are no longer listed here.")
        self.assertEqual(c.remove_summary(VOL, True, False, False),
                         "The subvolume is deleted. Snapshots stay in /srv/snapshots/docker "
                         "but are no longer listed here.")

    def test_new_volume_preview(self):
        p = {"path": "/srv", "snapshot_root": "/srv/snapshots"}
        self.assertEqual(c.new_volume_preview(p, "docker", False),
                         ["Subvolume: /srv/docker", "Snapshots: /srv/snapshots/docker/"])
        self.assertEqual(c.new_volume_preview(p, "docker", True)[0], "Register: /srv/docker")
        self.assertEqual(c.new_volume_preview(None, "docker", False), [])
        self.assertEqual(c.new_volume_preview(p, "", False), [])


class Locations(unittest.TestCase):
    MOUNTINFO = (
        "22 1 0:21 / / rw,relatime shared:1 - ext4 /dev/sda2 rw\n"
        "30 22 0:25 / /srv rw shared:2 - btrfs /dev/sdb rw,subvol=/\n"
        "31 30 0:26 / /srv/my\\040disk rw shared:3 - btrfs /dev/sdc rw\n"
        "32 22 0:27 / /srvx rw shared:4 - xfs /dev/sdd rw\n"
        "33 30 0:28 / /srv rw shared:5 - btrfs /dev/sde rw\n"   # mounted on top of /srv
        "bad line\n"
    )

    def setUp(self):
        fd, self.path = tempfile.mkstemp()
        with os.fdopen(fd, "w") as f:
            f.write(self.MOUNTINFO)

    def tearDown(self):
        os.unlink(self.path)

    def test_mount_of(self):
        self.assertEqual(c.mount_of("/srv/docker", self.path), ("/srv", "btrfs"))
        self.assertEqual(c.mount_of("/srvx/a", self.path), ("/srvx", "xfs"))
        self.assertEqual(c.mount_of("/srv/my disk/vm", self.path), ("/srv/my disk", "btrfs"))
        self.assertEqual(c.mount_of("/home", self.path), ("/", "ext4"))
        self.assertEqual(c.mount_of("/x", "/nonexistent/mountinfo"), ("/", ""))

    def test_suggest_snapshot_root(self):
        self.assertEqual(c.suggest_snapshot_root("/srv/docker", self.path), "/srv/snapshots")
        self.assertEqual(c.suggest_snapshot_root("/srv/my disk/vms", self.path),
                         "/srv/my disk/snapshots")
        self.assertEqual(c.suggest_snapshot_root("/srv", self.path), "/srv/snapshots")
        self.assertEqual(c.suggest_snapshot_root("/home/x", self.path), "/snapshots")


class HelperCalls(unittest.TestCase):
    def test_helper_argv(self):
        self.assertEqual(c.helper_argv("query", ["list"], "sudo"),
                         ["sudo", "-n", "/usr/libexec/btrfs-snapman/snapman-query", "list"])
        self.assertEqual(c.helper_argv("admin", ("delete", "v", "s"), "pkexec", "/x"),
                         ["pkexec", "/x/snapman-admin", "delete", "v", "s"])
        self.assertEqual(c.helper_argv("manage", [], None, "/x"), ["/x/snapman-manage"])

    def test_ok_and_failed(self):
        ok = json.dumps({"ok": True, "result": {"name": "x"}, "commands": [], "warnings": []})
        kind, res = c.parse_helper_output(0, ok + "\n", "")
        self.assertEqual((kind, res["result"]), ("ok", {"name": "x"}))
        kind, res = c.parse_helper_output(1, '{"ok": false, "error": "no such volume"}', "")
        self.assertEqual((kind, res["error"]), ("failed", "no such volume"))

    def test_sudo_needs_password(self):
        kind, res = c.parse_helper_output(1, "", "sudo: a password is required\n")
        self.assertEqual(kind, "auth_needed")
        self.assertFalse(res["ok"])
        self.assertEqual(res["error"], "sudo: a password is required")

    def test_pkexec(self):
        kind, res = c.parse_helper_output(126, "", "")
        self.assertEqual(kind, "auth_cancelled")
        self.assertTrue(res["cancelled"])
        kind, res = c.parse_helper_output(127, "", "Error executing command as another user")
        self.assertEqual((kind, res["error"]), ("failed", "Not authorised (polkit)"))

    def test_bad_output(self):
        kind, res = c.parse_helper_output(1, "", "Traceback (most recent call last):\n  ...")
        self.assertEqual(kind, "bad_output")
        self.assertTrue(res["error"].startswith("Traceback"))
        self.assertEqual(c.parse_helper_output(1, "{not json", "")[0], "bad_output")
        self.assertEqual(c.parse_helper_output(0, "[1, 2]", "")[0], "bad_output")
        self.assertEqual(c.parse_helper_output(2, "", "")[1]["error"], "helper exited 2")


if __name__ == "__main__":
    unittest.main()
