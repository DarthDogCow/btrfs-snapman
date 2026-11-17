"""
Unprivileged code shared by the two front ends: btrfs-snapman (GTK) and btrfs-snapman-cli.

Pure Python: no gi, no curses, no btrfsutil, nothing that needs root. Anything that must
look the same in both front ends (snapshot names, summaries, how a helper call went) lives
here, so the two can't drift apart. Privileged work only ever happens in the helpers.
"""

import collections
import datetime as dt
import json
import os
import re
import tomllib

LIBEXEC = "/usr/libexec/btrfs-snapman"
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")   # must match the helper's NAME_RE
MOUNTINFO = "/proc/self/mountinfo"
NIL_UUID = "00000000-0000-0000-0000-000000000000"
DEFAULT_NAME_FORMAT = "{volume}_{timestamp}_{label}"
DEFAULT_TIMESTAMP_FORMAT = "%Y-%m-%d_%H-%M-%S"


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


def log_lines(res):
    """The command-log lines for one helper response, as (kind, text) pairs.

    kind is "command", "warning", "note" or "hook". Errors are left to the caller.
    """
    result = (res.get("result") or {}) if res.get("ok") else {}
    lines = [("command", c if c.startswith("#") else "$ " + c)    # "# ..." lines are notes
             for c in res.get("commands", [])]
    lines += [("warning", "warning: " + w) for w in res.get("warnings", [])]
    lines += [("note", "note: " + n) for n in result.get("notes", [])]
    lines += [("hook", f"hook rc={h['rc']}: {' '.join(h['argv'])} {h['stderr'].strip()}".rstrip())
              for h in result.get("hooks", [])]
    return lines


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


# =========================================================================== discover

# Subvolumes that belong to other tools (container storage, Timeshift): never suggested
OTHER_TOOLS = ("var/lib/docker", "var/lib/containers", "var/lib/machines", "var/lib/portables",
               "timeshift-btrfs")
SNAPSHOT_FOLDERS = ("snapshots", ".snapshots")
# A timestamp inside a snapshot name: 2026-11-16_13-44-37, 20261116-134437, 2026-11-16_13-44, ...
TIMESTAMP_RE = re.compile(r"(\d{4})([-_.]?)(\d{2})\2(\d{2})([-_T]?)(\d{2})([-_.]?)(\d{2})"
                          r"(?:\7(\d{2}))?")


def split_snapshot_name(name):
    """(prefix, timestamp_format, label) of a name like 'docker_local_2026-11-16_13-44-37_Fix'.

    None if the name has no recognisable timestamp. The label is "" for timestamp-only
    names, which is what scheduled jobs usually make.
    """
    m = TIMESTAMP_RE.search(name)
    if not m:
        return None
    d, dt_sep, t = m.group(2), m.group(5), m.group(7)
    tsf = f"%Y{d}%m{d}%d{dt_sep}%H{t}%M" + (f"{t}%S" if m.group(9) else "")
    return name[:m.start()], tsf, name[m.end():].lstrip("_-")


def _volume_name(fs_path, reachable, taken):
    """A volume name from the subvolume's folder name: '@home' -> 'home', '@' -> 'root'."""
    base = re.sub(r"[^A-Za-z0-9._-]", "_", os.path.basename(fs_path).lstrip("@"))
    base = base.lstrip("._-")[:60] or ("root" if reachable == "/" else "top")
    name, n = base, 2
    while name in taken:
        name, n = f"{base}-{n}", n + 1
    taken.add(name)
    return name


def _skip_reason(sub, ro_folders, uuids):
    """Why a subvolume isn't a candidate volume, or None if it is one.

    A snapshot is read-only, or sits in a folder of mostly read-only subvolumes, or sits
    among read-only ones and was made from a subvolume that still exists.
    """
    p = sub["path"]
    parts = p.split("/")
    folder = os.path.dirname(p)
    if sub["read_only"] or ro_folders.get(folder, 0) > 0.5 or \
            (ro_folders.get(folder, 0) and sub["parent_uuid"] in uuids):
        return "snapshot"
    if any(x in SNAPSHOT_FOLDERS for x in parts[:-1]) or \
            parts[-1].lstrip("@").lower() in SNAPSHOT_FOLDERS:
        return "snapshot"
    for tree in OTHER_TOOLS:
        if f"/{tree}/" in f"/{p}/":
            return "tool:" + tree
    if parts[-1].lstrip("@").lower() == "swap":
        return "swap"
    if not sub["reachable"]:
        return "not mounted anywhere"
    return None


def _formats(name, names):
    """(name_format, timestamp_format) that reproduce the labelled names, or None."""
    seen = collections.Counter()
    for nm in names:
        parts = split_snapshot_name(nm)
        if parts and parts[2] and re.fullmatch(r"[A-Za-z0-9._-]*", parts[0]):
            seen[parts[:2]] += 1
    if not seen:
        return None
    prefix, tsf = seen.most_common(1)[0][0]
    if prefix == f"{name}_":
        prefix = "{volume}_"
    return prefix + "{timestamp}_{label}", tsf


def _labelled(names):
    return sum(1 for nm in names if (p := split_snapshot_name(nm)) and p[2])


def suggest_volumes(discovered, volumes):
    """Suggested volumes from snapman-query discover and the configured volumes from list.

    Returns dicts with status "new", "configured" or "skipped", name, path, and for new
    ones snapshot_dir, name_format, timestamp_format, why (how the folder was chosen) and
    alternatives [(folder, snapshots of it there)]. Snapshots themselves aren't listed;
    subvolumes of other tools are summed up in one "skipped" entry per tree.
    """
    configured = {os.path.realpath(v["path"]): v["name"] for v in volumes}
    taken = {v["name"] for v in volumes}
    out = []
    for fs in discovered["filesystems"]:
        where = fs["label"] or (fs["mounts"][0]["path"] if fs["mounts"] else "?")
        if fs["error"]:
            out.append({"status": "skipped", "name": "", "path": where, "why": fs["error"]})
            continue
        subs = fs["subvolumes"]
        # Folders of snapshots: mostly read-only subvolumes (a writable one there is a
        # snapshot made writable, not a volume)
        per_folder = collections.defaultdict(list)
        for s in subs:
            per_folder[os.path.dirname(s["path"])].append(s["read_only"])
        ro_folders = {f: sum(ro) / len(ro) for f, ro in per_folder.items()}
        uuids = {s["uuid"] for s in subs}
        top = next((m["path"] for m in fs["mounts"] if m["subvol"] == "/"), None) or \
            min(fs["mounts"], key=lambda m: len(m["subvol"]))["path"]

        # Candidates: writable, not a snapshot, not another tool's, reachable
        cands, others = [], collections.Counter()
        for sub in sorted(subs, key=lambda x: x["path"]):
            why = _skip_reason(sub, ro_folders, uuids)
            if why is None:
                cands.append(sub)
            elif why.startswith("tool:"):
                others[why[5:]] += 1
            elif why != "snapshot":
                out.append({"status": "skipped", "name": "", "path": sub["reachable"] or
                            f"{where}:/{sub['path']}", "why": why})
        for tree, n in others.items():
            out.append({"status": "skipped", "name": "", "path": where,
                        "why": f"{n} subvolume(s) under {tree}, which belong to another tool"})
        live = {c["reachable"] for c in cands}

        # Snapshot names per folder: of each subvolume (by parent UUID), and of anything
        by_parent = collections.defaultdict(lambda: collections.defaultdict(list))
        any_folder = collections.defaultdict(list)
        for s in subs:
            if s["reachable"] and _skip_reason(s, ro_folders, uuids) == "snapshot":
                folder = os.path.dirname(s["reachable"])
                any_folder[folder].append(os.path.basename(s["reachable"]))
                if s["parent_uuid"] != NIL_UUID:
                    by_parent[s["parent_uuid"]][folder].append(os.path.basename(s["reachable"]))

        chosen = []                     # (path in the filesystem, entry), for the nesting check
        for c in cands:
            path = c["reachable"]
            # Nesting is about the subvolume tree: @home is not inside @, though /home is in /
            outer = next((e for fp, e in chosen if c["path"].startswith(fp + "/")), None)
            if outer:
                out.append({"status": "skipped", "name": "", "path": path,
                            "why": f"inside {outer['name']}, whose snapshots don't include it"})
                continue
            if os.path.realpath(path) in configured:
                entry = {"status": "configured", "name": configured[os.path.realpath(path)],
                         "path": path}
                chosen.append((c["path"], entry))
                out.append(entry)
                continue
            name = _volume_name(c["path"], path, taken)
            own = by_parent.get(c["uuid"], {})
            alternatives = sorted(((f, len(n)) for f, n in own.items()), key=lambda x: -x[1])
            # Where its labelled (by hand) snapshots are; else where anything's labelled ones
            # are; else a new folder. Folders of timestamp-only names belong to scheduled jobs.
            manual = {f: _labelled(n) for f, n in own.items() if _labelled(n)}
            shared = {f: _labelled(n) for f, n in any_folder.items() if _labelled(n)}
            if manual:
                folder = max(manual, key=manual.get)
                why = f"holds {manual[folder]} of its snapshots with comments"
            elif shared:
                folder = max(shared, key=shared.get)
                why = "holds other snapshots with comments on this filesystem"
            else:
                folder, why = os.path.join(top, "snapshots", name), "new folder"
                if folder in any_folder:
                    folder = os.path.join(top, "snapshots", "adhoc")
            if any(os.path.dirname(x) == folder for x in live | set(configured)):
                folder, why = os.path.join(top, "snapshots", name), "new folder"
            # Names as its own snapshots there are named; in a folder shared with other
            # volumes, only the timestamp style is borrowed
            fmts = _formats(name, own.get(folder, []))
            if not fmts:
                borrowed = _formats(name, any_folder.get(folder, []))
                fmts = (DEFAULT_NAME_FORMAT, borrowed[1] if borrowed else DEFAULT_TIMESTAMP_FORMAT)
            name_format, tsf = fmts
            entry = {"status": "new", "name": name, "path": path, "snapshot_dir": folder,
                     "name_format": name_format, "timestamp_format": tsf, "why": why,
                     "alternatives": [a for a in alternatives if a[0] != folder],
                     "filesystem": where}
            chosen.append((c["path"], entry))
            out.append(entry)
    return out


def _toml(value):
    return json.dumps(value)    # JSON's string escaping is a valid subset of TOML's


def render_toml(suggestions):
    """The new suggestions as [[volume]] tables, with the reasons as comments."""
    lines = ["# Volumes suggested by btrfs-snapman-cli discover. Review and edit, then install",
             "# with: btrfs-snapman-cli register FILE", ""]
    for s in suggestions:
        if s["status"] != "new":
            continue
        lines.append(f"# {s['path']} on {s['filesystem']}. Snapshot folder: {s['why']}.")
        for folder, n in s["alternatives"]:
            lines.append(f"#   also {n} snapshot(s) of it in {folder}")
        lines += ["[[volume]]", f"name = {_toml(s['name'])}", f"path = {_toml(s['path'])}",
                  f"snapshot_dir = {_toml(s['snapshot_dir'])}",
                  f"name_format = {_toml(s['name_format'])}",
                  f"timestamp_format = {_toml(s['timestamp_format'])}", ""]
    rest = [s for s in suggestions if s["status"] != "new"]
    if not any(s["status"] == "new" for s in suggestions):
        lines += ["# Nothing new to suggest.", ""]
    for s in rest:
        what = f"already configured as {s['name']}" if s["status"] == "configured" else s["why"]
        lines.append(f"# {s['path']}: {what}")
    return "\n".join(lines).rstrip() + "\n"


def read_volume_file(text):
    """Volumes from a TOML file of [[volume]] tables (config.toml style) or one [volume].

    Returns dicts for register; name_format/timestamp_format are None when not given.
    Raises ValueError with a readable message.
    """
    try:
        data = tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        raise ValueError(f"not valid TOML: {e}") from None
    vols = data.get("volume", [])
    vols = [vols] if isinstance(vols, dict) else vols
    if not vols:
        raise ValueError("no [[volume]] tables found")
    items = []
    for v in vols:
        if not isinstance(v, dict) or not all(isinstance(v.get(k), str)
                                              for k in ("name", "path", "snapshot_dir")):
            raise ValueError("every volume needs name, path and snapshot_dir (strings)")
        extra = set(v) - {"name", "path", "snapshot_dir", "name_format", "timestamp_format"}
        if extra:
            raise ValueError(f"volume {v['name']}: register can't set {', '.join(sorted(extra))};"
                             " add those to its volumes.d file afterwards")
        items.append({k: v.get(k) for k in ("name", "path", "snapshot_dir", "name_format",
                                             "timestamp_format")})
    return items


def register_args(items):
    """argv for snapman-manage register: five per volume, "-" for a format left unset."""
    args = ["register"]
    for it in items:
        args += [it["name"], it["path"], it["snapshot_dir"], it["name_format"] or "-",
                 it["timestamp_format"] or "-"]
    return args
