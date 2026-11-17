"""
Unprivileged code shared by the two front ends: btrfs-snapman (GTK) and btrfs-snapman-cli.

Pure Python: no gi, no curses, no btrfsutil, nothing that needs root. Anything that must
look the same in both front ends (snapshot names, summaries, how a helper call went) lives
here, so the two can't drift apart. Privileged work only ever happens in the helpers.
"""

import datetime as dt
import json
import os
import re

LIBEXEC = "/usr/libexec/btrfs-snapman"
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")   # must match the helper's NAME_RE
MOUNTINFO = "/proc/self/mountinfo"


# =========================================================================== names and times

def sanitise_label(text):
    """Clean a comment for use in a name: spaces -> '_', keep only [A-Za-z0-9_-]."""
    return re.sub(r"[^A-Za-z0-9_-]", "", text.replace(" ", "_"))[:64]


def preview_name(v, label):
    """What the helper will name a snapshot taken now (it builds the real name the same way)."""
    ts = dt.datetime.now().strftime(v.get("timestamp_format", "%Y%m%d-%H%M%S"))
    name = v["name_format"].format(volume=v["name"], timestamp=ts, label=label)
    return re.sub(r"__+", "_", name).strip("_-")


def fmt_time(epoch):
    return dt.datetime.fromtimestamp(epoch).strftime("%Y-%m-%d %H:%M:%S")


def fmt_age(epoch):
    """e.g. '3d ago', '5h ago'."""
    secs = max(0, int(dt.datetime.now().timestamp() - epoch))
    for unit, n in (("d", 86400), ("h", 3600), ("m", 60)):
        if secs >= n:
            return f"{secs // n}{unit} ago"
    return "just now"


# =========================================================================== locations

def mount_of(path, mountinfo=MOUNTINFO):
    """(mount point, fs type) of the mount that contains path, from /proc/self/mountinfo."""
    best = ("/", "")
    try:
        with open(mountinfo) as f:
            for line in f:
                pre, _, post = line.partition(" - ")
                fields, post_fields = pre.split(), post.split()
                if len(fields) < 5 or not post_fields:
                    continue
                # mountinfo escapes spaces etc. as \040; turn them back into characters
                mp = re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), fields[4])
                inside = mp == "/" or path == mp or path.startswith(mp + "/")
                # later lines are mounted on top of earlier ones, so >= keeps the visible one
                if inside and len(mp) >= len(best[0]):
                    best = (mp, post_fields[0])
    except OSError:
        pass
    return best


def suggest_snapshot_root(path, mountinfo=MOUNTINFO):
    """Default snapshot root for a new location: 'snapshots' at the top of its filesystem."""
    return os.path.join(mount_of(path, mountinfo)[0], "snapshots")


# =========================================================================== plain-English previews

def new_volume_preview(parent, folder, existing):
    """The "Will create" lines for New volume, or [] while the parent or folder is missing."""
    if not parent or not folder:
        return []
    what = "Register" if existing else "Subvolume"
    return [f"{what}: {parent['path']}/{folder}",
            f"Snapshots: {parent['snapshot_root']}/{folder}/"]


def remove_summary(volume, delete_data, final, delete_snapshots):
    """What Remove volume will do, in the words both front ends show."""
    if not delete_data:
        return "Only the registration is removed. Nothing on disk changes."
    if delete_snapshots:
        return (f"The subvolume, all {len(volume['snapshots'])} snapshot(s) and the snapshot "
                "folder are deleted. Nothing is kept.")
    if final:
        return ("A final read-only snapshot is taken, then the subvolume is deleted. "
                f"Snapshots stay in {volume['snapshot_dir']} but are no longer listed here.")
    return (f"The subvolume is deleted. Snapshots stay in {volume['snapshot_dir']} "
            "but are no longer listed here.")


# =========================================================================== helper calls

def helper_argv(mode, args, via, libexec=LIBEXEC):
    """argv for one helper call. via: "pkexec", "sudo", or None when already root."""
    exe = f"{libexec}/snapman-{mode}"
    prefix = {"pkexec": ["pkexec"], "sudo": ["sudo", "-n"], None: []}[via]
    return prefix + [exe] + list(args)


def parse_helper_output(returncode, stdout, stderr):
    """Turn a finished helper call into (kind, response).

    kind is "ok", "failed" (the helper said no, or polkit refused), "auth_needed" (sudo -n
    wants a password), "auth_cancelled" (the polkit dialog was dismissed) or "bad_output".
    response always has the helper's shape: {"ok": ..., "error": ...} at least.
    """
    out, err = (stdout or "").strip(), (stderr or "").strip()
    # pkexec uses exit code 126 for "dialog dismissed", 127 for "not authorised"
    if returncode == 126:
        return "auth_cancelled", {"ok": False, "error": "Authentication cancelled",
                                  "cancelled": True}
    if returncode == 127 and not out:
        return "failed", {"ok": False, "error": "Not authorised (polkit)"}
    # sudo -n prints its own complaint ("sudo: a password is required") and nothing on stdout
    if returncode != 0 and not out and err.startswith("sudo:"):
        return "auth_needed", {"ok": False, "error": err}
    try:
        res = json.loads(out)
        if not isinstance(res, dict) or "ok" not in res:
            raise ValueError
    except ValueError:
        return "bad_output", {"ok": False, "error": err or out or f"helper exited {returncode}"}
    return ("ok" if res["ok"] else "failed"), res
