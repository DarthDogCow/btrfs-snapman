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


# A discover result built from (path in fs, read-only, parent) rows; uuids are made up
def fake_fs(rows, mounts, label="", reach=None):
    uuids = {path: f"{i:08x}-0000-0000-0000-000000000000" for i, (path, _, _) in
             enumerate(rows, start=1)}
    reach = reach or (lambda p: f"{mounts[0][0]}/{p}")
    subs = []
    for i, (path, ro, parent) in enumerate(rows, start=256):
        subs.append({"id": i, "parent_id": 5, "path": path, "reachable": reach(path),
                     "uuid": uuids[path],
                     "parent_uuid": uuids.get(parent, parent or c.NIL_UUID),
                     "received": False, "read_only": ro, "otime": 0})
    return {"fsid": "f" * 8, "label": label, "error": None, "subvolumes": subs,
            "mounts": [{"path": mp, "subvol": sv} for mp, sv in mounts]}


# Shaped like a home server: live docker and cluster at the top, labelled snapshots in
# snapshots/adhoc, timestamp-only ones from scheduled jobs in snapshots/<name>
SERVER = fake_fs([
    ("docker", False, None),
    ("docker/archive/old", False, None),
    ("cluster", False, None),
    ("snapshots/adhoc/docker_local_2026-05-19_13-06-53_Before_change", True, "docker"),
    ("snapshots/adhoc/docker_local_2026-11-16_22-26-50_After_fix", True, "docker"),
    ("snapshots/adhoc/cluster_2026-11-16_13-44-37_Old_cluster", True, "gone-uuid"),
    ("snapshots/docker/2026-11-12_01-00-01", True, "docker"),
    ("snapshots/docker/2026-11-13_01-00-01", True, "docker"),
    ("snapshots/cluster/2026-11-17_11-10-03", True, "cluster"),
], [("/media/SSD1", "/")], label="SSD1")

# Shaped like a laptop: no top-level mount, / and /home are subvolumes, plus Docker's
LAPTOP_MOUNTS = {"@": "/", "@home": "/home"}
LAPTOP = fake_fs([
    ("@", False, None),
    ("@home", False, None),
    ("@swap", False, None),
    ("@/var/lib/docker/btrfs/subvolumes/aaa", False, None),
    ("@/var/lib/docker/btrfs/subvolumes/bbb", False, None),
], [("/", "/@"), ("/home", "/@home")],
    reach=lambda p: LAPTOP_MOUNTS.get(p) or (("/" + p[2:]) if p.startswith("@/") else None))


def by_path(suggestions):
    return {s["path"]: s for s in suggestions}


class Discover(unittest.TestCase):
    def test_split_snapshot_name(self):
        self.assertEqual(c.split_snapshot_name("docker_local_2026-11-16_13-44-37_Fix_it"),
                         ("docker_local_", "%Y-%m-%d_%H-%M-%S", "Fix_it"))
        self.assertEqual(c.split_snapshot_name("2026-11-12_01-00-01"),
                         ("", "%Y-%m-%d_%H-%M-%S", ""))
        self.assertEqual(c.split_snapshot_name("20261116-134437_pre"),
                         ("", "%Y%m%d-%H%M%S", "pre"))
        self.assertEqual(c.split_snapshot_name("x-2026-11-16_13-44"),
                         ("x-", "%Y-%m-%d_%H-%M", ""))
        self.assertIsNone(c.split_snapshot_name("manual-old"))

    def test_server_layout(self):
        got = by_path(c.suggest_volumes({"filesystems": [SERVER]}, []))
        docker = got["/media/SSD1/docker"]
        self.assertEqual(docker["status"], "new")
        self.assertEqual(docker["snapshot_dir"], "/media/SSD1/snapshots/adhoc")
        # the existing prefix is kept, not replaced by the volume name
        self.assertEqual(docker["name_format"], "docker_local_{timestamp}_{label}")
        self.assertEqual(docker["timestamp_format"], "%Y-%m-%d_%H-%M-%S")
        self.assertEqual(docker["alternatives"], [("/media/SSD1/snapshots/docker", 2)])
        # cluster's own snapshots are all scheduled; the labelled folder is shared
        cluster = got["/media/SSD1/cluster"]
        self.assertEqual(cluster["snapshot_dir"], "/media/SSD1/snapshots/adhoc")
        self.assertEqual(cluster["name_format"], "{volume}_{timestamp}_{label}")
        self.assertIn("other snapshots with comments", cluster["why"])
        nested = got["/media/SSD1/docker/archive/old"]
        self.assertEqual(nested["status"], "skipped")
        self.assertIn("inside docker", nested["why"])
        # snapshots themselves are never suggested
        self.assertFalse(any("snapshots/" in p for p in got))

    def test_laptop_layout(self):
        sugg = c.suggest_volumes({"filesystems": [LAPTOP]}, [])
        got = by_path(sugg)
        self.assertEqual((got["/"]["name"], got["/"]["snapshot_dir"]), ("root", "/snapshots/root"))
        self.assertEqual((got["/home"]["name"], got["/home"]["snapshot_dir"]),
                         ("home", "/snapshots/home"))
        self.assertEqual(got["/home"]["why"], "new folder")
        skipped = [s["why"] for s in sugg if s["status"] == "skipped"]
        self.assertIn("2 subvolume(s) under var/lib/docker, which belong to another tool", skipped)
        self.assertIn("swap", skipped)
        self.assertEqual(len([s for s in sugg if s["status"] == "new"]), 2)

    def test_configured_and_name_clash(self):
        vols = [{"name": "home", "path": "/home"}, {"name": "docker", "path": "/srv/other"}]
        got = by_path(c.suggest_volumes({"filesystems": [SERVER, LAPTOP]}, vols))
        self.assertEqual((got["/home"]["status"], got["/home"]["name"]), ("configured", "home"))
        self.assertEqual(got["/media/SSD1/docker"]["name"], "docker-2")

    def test_snapshots_next_to_live_subvolumes(self):
        # Labelled snapshots kept beside the live subvolumes: that folder would let a
        # snapshot delete reach a live subvolume, so a new folder is used instead
        fs = fake_fs([("Music", False, None), ("Video", False, None),
                      ("Music_2025-05-26_21-06-48_Initial", True, "Music")],
                     [("/media/RAID", "/")])
        got = by_path(c.suggest_volumes({"filesystems": [fs]}, []))
        self.assertEqual(got["/media/RAID/Music"]["status"], "new")
        self.assertEqual(got["/media/RAID/Music"]["snapshot_dir"], "/media/RAID/snapshots/Music")

    def test_writable_snapshot_is_not_a_volume(self):
        fs = fake_fs([("data", False, None), ("snaps/a_2026-01-01_00-00-00_x", True, "data"),
                      ("snaps/a_2026-01-02_00-00-00_y", False, "data")], [("/m", "/")])
        got = by_path(c.suggest_volumes({"filesystems": [fs]}, []))
        self.assertEqual([p for p, s in got.items() if s["status"] == "new"], ["/m/data"])

    def test_toml_round_trip(self):
        sugg = c.suggest_volumes({"filesystems": [SERVER]}, [{"name": "x", "path": "/nope"}])
        text = c.render_toml(sugg)
        self.assertIn("# /media/SSD1/docker/archive/old: inside docker", text)
        items = c.read_volume_file(text)
        self.assertEqual([i["name"] for i in items], ["cluster", "docker"])
        self.assertEqual(items[1]["name_format"], "docker_local_{timestamp}_{label}")
        args = c.register_args(items)
        self.assertEqual(args[:6], ["register", "cluster", "/media/SSD1/cluster",
                                    "/media/SSD1/snapshots/adhoc",
                                    "{volume}_{timestamp}_{label}", "%Y-%m-%d_%H-%M-%S"])

    def test_read_volume_file(self):
        items = c.read_volume_file('[volume]\nname = "a"\npath = "/a"\nsnapshot_dir = "/s"\n')
        self.assertEqual(items, [{"name": "a", "path": "/a", "snapshot_dir": "/s",
                                  "name_format": None, "timestamp_format": None}])
        self.assertEqual(c.register_args(items), ["register", "a", "/a", "/s", "-", "-"])
        for bad in ('[[volume]]\nname = "a"\n', "nonsense =", "[defaults]\nx = 1\n",
                    '[[volume]]\nname="a"\npath="/a"\nsnapshot_dir="/s"\npre_snapshot=[]\n'):
            with self.assertRaises(ValueError):
                c.read_volume_file(bad)


if __name__ == "__main__":
    unittest.main()
