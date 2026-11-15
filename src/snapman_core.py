"""
btrfs-snapman core: the only code that runs as root.

It is called by three tiny entry scripts, each with its own polkit rule:
  snapman-query   list                                  no password (active session)
  snapman-admin   snapshot | delete | set-ro            password, cached a few minutes
  snapman-manage  new-volume | remove-volume            password every time

Design rules
  * A fixed set of operations. The GUI passes names, never arbitrary paths.
  * Every path comes from root-owned config:
      /etc/btrfs-snapman/config.toml        hand-written: defaults, create parents, volumes
      /etc/btrfs-snapman/volumes.d/*.toml   one file per volume; the tool writes and removes these
  * The tool never edits config.toml. It only adds or removes its own drop-in files.
  * Snapshot deletes are confined to a volume's snapshot_dir. Source subvolumes can only
    be deleted if they live directly under a [[create.parent]] path.
  * Uses libbtrfsutil (python3-btrfsutil); never parses btrfs CLI output.
  * Every change is logged to the journal with the invoking user's UID.
  * Output is a single JSON object on stdout.
"""

import array
import datetime as _dt
import fcntl
import json
import os
import re
import shlex
import stat
import subprocess
import syslog
import tempfile
import tomllib
import uuid as _uuid

import btrfsutil

CONFIG_PATH = "/etc/btrfs-snapman/config.toml"

# Allowed characters for the different kinds of name.
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")          # volume names, folder names
LABEL_RE = re.compile(r"^[A-Za-z0-9._-]{0,64}$")                      # snapshot comments
ENTRY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:+@-]{0,199}$")       # snapshot names we will touch
SAFE_PATH_RE = re.compile(r"^/[A-Za-z0-9._@:+/ -]*$")                 # paths we will write into a drop-in

# Linux ioctl numbers and flags for reading/setting the NOCOW (chattr +C) attribute.
FS_IOC_GETFLAGS = 0x80086601
FS_IOC_SETFLAGS = 0x40086602
FS_NOCOW_FL = 0x00800000

HOOK_TIMEOUT = 120
NIL_UUID = "00000000-0000-0000-0000-000000000000"
DROPIN_HEADER = ("# Managed by btrfs-snapman. Created via the GUI; removing the volume in the\n"
                 "# GUI deletes this file. Safe to edit by hand (e.g. to add hooks).\n")


class SnapError(Exception):
    """An expected, user-facing failure. Its message is shown in the GUI."""


# =========================================================================== config

def _check_root_owned(path):
    """Refuse config that a non-root user could have written to."""
    st = os.stat(path)
    if st.st_uid != 0:
        raise SnapError(f"{path} must be owned by root")
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise SnapError(f"{path} must not be group- or world-writable")


def _parse_volume(v, defaults, origin, origin_file):
    """Validate one volume table from either config.toml or a drop-in."""
    name = v.get("name", "")
    if not NAME_RE.match(name):
        raise SnapError(f"invalid volume name: {name!r}")
    for key in ("path", "snapshot_dir"):
        if not os.path.isabs(v.get(key, "")):
            raise SnapError(f"volume {name}: {key} must be an absolute path")

    # Hooks are lists of argv lists, e.g. [["/usr/bin/virsh", "domfsfreeze", "vm1"]].
    hooks = {}
    for key in ("pre_snapshot", "post_snapshot"):
        cmds = v.get(key, [])
        if not isinstance(cmds, list) or not all(
            isinstance(c, list) and c and all(isinstance(a, str) for a in c) for c in cmds
        ):
            raise SnapError(f"volume {name}: {key} must be a list of argv lists")
        for c in cmds:
            if not os.path.isabs(c[0]):
                raise SnapError(f"volume {name}: hook command must be an absolute path: {c[0]}")
        hooks[key] = cmds

    # Check the timestamp format can only produce characters that are safe in a filename.
    tsf = v.get("timestamp_format", defaults["timestamp_format"])
    if not re.fullmatch(r"[A-Za-z0-9._+-]*", _dt.datetime(2000, 1, 2, 3, 4, 5).strftime(tsf)):
        raise SnapError(f"volume {name}: timestamp_format must produce only [A-Za-z0-9._+-]")

    return {
        "name": name,
        "path": v["path"],
        "snapshot_dir": v["snapshot_dir"],
        "name_format": v.get("name_format", defaults["name_format"]),
        "timestamp_format": tsf,
        "read_only": bool(v.get("read_only", defaults["read_only"])),
        "pre_snapshot": hooks["pre_snapshot"],
        "post_snapshot": hooks["post_snapshot"],
        "origin": origin,              # "config" (config.toml) or "dropin" (volumes.d)
        "origin_file": origin_file,
    }


def load_config(path=CONFIG_PATH, enforce_ownership=True):
    """Load config.toml plus every volumes.d/*.toml drop-in.

    A broken drop-in is skipped and reported in config_errors, so one bad file
    can't take the whole tool down. A broken config.toml is fatal.
    """
    if not os.path.exists(path):
        raise SnapError(f"config not found: {path}")
    etc = os.path.dirname(path)
    dropin_dir = os.path.join(etc, "volumes.d")
    if enforce_ownership:
        _check_root_owned(etc)
        _check_root_owned(path)
    with open(path, "rb") as f:
        raw = tomllib.load(f)

    # Global defaults, which each volume may override.
    d = raw.get("defaults", {})
    defaults = {
        "name_format": d.get("name_format", "{timestamp}_{label}"),
        "timestamp_format": d.get("timestamp_format", "%Y%m%d-%H%M%S"),
        "read_only": bool(d.get("read_only", True)),
    }

    # Volumes written by hand in config.toml.
    volumes, errors = {}, []
    for v in raw.get("volume", []):
        vol = _parse_volume(v, defaults, "config", path)
        if vol["name"] in volumes:
            raise SnapError(f"duplicate volume name in config: {vol['name']}")
        volumes[vol["name"]] = vol

    # Volumes from drop-in files, one [volume] table per file, file named <name>.toml.
    if os.path.isdir(dropin_dir):
        if enforce_ownership:
            _check_root_owned(dropin_dir)
        for fn in sorted(os.listdir(dropin_dir)):
            if not fn.endswith(".toml"):
                continue
            fp = os.path.join(dropin_dir, fn)
            try:
                if enforce_ownership:
                    _check_root_owned(fp)
                with open(fp, "rb") as f:
                    vol = _parse_volume(tomllib.load(f).get("volume", {}), defaults, "dropin", fp)
                if fn != vol["name"] + ".toml":
                    raise SnapError(f"file must be named {vol['name']}.toml")
                if vol["name"] in volumes:
                    raise SnapError(f"volume {vol['name']} is already defined in "
                                    f"{volumes[vol['name']]['origin_file']}")
                volumes[vol["name"]] = vol
            except (SnapError, OSError, tomllib.TOMLDecodeError) as e:
                errors.append(f"{fp}: {e}")

    # Where new volumes may be created, and where their snapshots go:
    #   [[create.parent]]
    #   path = "/mnt/vmstorage/vmdisks"
    #   snapshot_root = "/mnt/vmstorage/snapshots"
    parents = []
    for p in raw.get("create", {}).get("parent", []):
        if not (os.path.isabs(p.get("path", "")) and os.path.isabs(p.get("snapshot_root", ""))):
            raise SnapError("each [[create.parent]] needs absolute path and snapshot_root")
        parents.append({"path": p["path"], "snapshot_root": p["snapshot_root"]})

    return {"volumes": volumes, "create_parents": parents, "config_errors": errors,
            "defaults": defaults, "dropin_dir": dropin_dir}


# =========================================================================== small helpers

def _uuid_str(b):
    return str(_uuid.UUID(bytes=bytes(b)))


def _get_nocow(path):
    """True/False if the directory has chattr +C, None if it can't be read."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    except OSError:
        return None
    try:
        buf = array.array("l", [0])
        fcntl.ioctl(fd, FS_IOC_GETFLAGS, buf, True)
        return bool(buf[0] & FS_NOCOW_FL)
    except OSError:
        return None
    finally:
        os.close(fd)


def _set_nocow(path):
    """Equivalent of chattr +C. Only affects files created afterwards, so call it on an empty dir."""
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        buf = array.array("l", [0])
        fcntl.ioctl(fd, FS_IOC_GETFLAGS, buf, True)
        buf[0] |= FS_NOCOW_FL
        fcntl.ioctl(fd, FS_IOC_SETFLAGS, buf, True)
    finally:
        os.close(fd)


def _info_dict(path):
    """The subvolume details the GUI shows."""
    info = btrfsutil.subvolume_info(path)
    return {
        "id": info.id,
        "parent_id": info.parent_id,
        "uuid": _uuid_str(info.uuid),
        "parent_uuid": _uuid_str(info.parent_uuid),
        "received_uuid": _uuid_str(info.received_uuid),
        "generation": info.generation,
        "otime": info.otime,
        "read_only": btrfsutil.get_subvolume_read_only(path),
    }


def _mounted_subvol_ids_and_points():
    """Return (set of mounted btrfs subvolume IDs, set of btrfs mount points) from mountinfo."""
    ids, points = set(), set()
    try:
        with open("/proc/self/mountinfo") as f:
            for line in f:
                pre, _, post = line.partition(" - ")
                fields, post_fields = pre.split(), post.split()
                if len(post_fields) < 3 or post_fields[0] != "btrfs":
                    continue
                # mountinfo escapes spaces etc. as \040; turn them back into characters
                points.add(re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), fields[4]))
                for opt in post_fields[2].split(","):
                    if opt.startswith("subvolid="):
                        ids.add(int(opt.split("=", 1)[1]))
    except OSError:
        pass
    return ids, points


def _check_not_mounted(path):
    """Refuse if the subvolume itself, or anything inside it, is a mount point."""
    sid = btrfsutil.subvolume_id(path)
    ids, points = _mounted_subvol_ids_and_points()
    if sid in ids or any(mp == path or mp.startswith(path + "/") for mp in points):
        raise SnapError(f"{path} is mounted (or has something mounted inside it); unmount first")


def _check_no_nested(path):
    """Refuse if the subvolume contains other subvolumes (we never delete recursively)."""
    for sub_path, _ in btrfsutil.SubvolumeIterator(path):
        raise SnapError(f"{path} contains nested subvolume {sub_path}; remove it manually first")


def _processes_using(path, limit=5):
    """Find processes with files open, a cwd, or mappings inside path (e.g. a running VM)."""
    hits = []
    me = os.getpid()
    prefix = path.rstrip("/") + "/"

    def inside(target):
        return target == path or target.startswith(prefix)

    for pid in filter(str.isdigit, os.listdir("/proc")):
        if int(pid) == me:
            continue
        base = f"/proc/{pid}"
        found = False
        try:
            # open file descriptors, current directory and root directory
            links = [os.path.join(base, "fd", fd) for fd in os.listdir(os.path.join(base, "fd"))]
            for link in links + [f"{base}/cwd", f"{base}/root"]:
                try:
                    if inside(os.readlink(link)):
                        found = True
                        break
                except OSError:
                    continue
            # memory-mapped files
            if not found:
                with open(f"{base}/maps") as m:
                    found = any(inside(line.split(None, 5)[-1].strip())
                                for line in m if line.count(" ") >= 5 and "/" in line)
            if found:
                with open(f"{base}/comm") as c:
                    hits.append(f"{c.read().strip()} (pid {pid})")
                if len(hits) >= limit:
                    break
        except OSError:
            continue        # process exited or is inaccessible; ignore
    return hits


def _volume(cfg, name):
    v = cfg["volumes"].get(name)
    if v is None:
        raise SnapError(f"unknown volume: {name!r}")
    return v


def _resolve_source(v):
    src = os.path.realpath(v["path"])
    if not btrfsutil.is_subvolume(src):
        raise SnapError(f"{src} is not a btrfs subvolume")
    return src


def _resolve_snapdir(v):
    d = os.path.realpath(v["snapshot_dir"])
    if not os.path.isdir(d):
        raise SnapError(f"snapshot_dir does not exist: {d}")
    return d


def _resolve_entry(v, entry):
    """Turn a snapshot name into a path, guaranteeing it is directly inside snapshot_dir."""
    if not ENTRY_RE.match(entry or ""):
        raise SnapError(f"invalid snapshot name: {entry!r}")
    d = _resolve_snapdir(v)
    p = os.path.join(d, entry)
    if os.path.islink(p):
        raise SnapError("refusing to follow a symlink")
    if os.path.dirname(os.path.realpath(p)) != d:
        raise SnapError("snapshot path escapes snapshot_dir")
    if not os.path.exists(p):
        raise SnapError(f"no such snapshot: {entry}")
    if not btrfsutil.is_subvolume(p):
        raise SnapError(f"{p} is not a subvolume")
    if os.path.realpath(p) == os.path.realpath(v["path"]):
        raise SnapError("refusing to operate on the source subvolume")
    return p


def _parent_for(cfg, src):
    """The [[create.parent]] that src sits directly under, or None."""
    for p in cfg["create_parents"]:
        if os.path.dirname(src) == os.path.realpath(p["path"]):
            return p
    return None


def _q(*args):
    """Format a command line for the GUI's command log."""
    return " ".join(shlex.quote(a) for a in args)


def _log(msg):
    """Write to the journal (journalctl -t btrfs-snapman), tagged with the calling user."""
    uid = os.environ.get("PKEXEC_UID", str(os.getuid()))
    syslog.openlog("btrfs-snapman", syslog.LOG_PID, syslog.LOG_AUTHPRIV)
    syslog.syslog(syslog.LOG_NOTICE, f"uid={uid} {msg}")


def _run_hooks(cmds, results):
    """Run hook commands without a shell, with a clean environment. Returns False if any failed."""
    ok = True
    for argv in cmds:
        try:
            p = subprocess.run(argv, capture_output=True, text=True, timeout=HOOK_TIMEOUT,
                               env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8"})
            results.append({"argv": argv, "rc": p.returncode,
                            "stdout": p.stdout[-2000:], "stderr": p.stderr[-2000:]})
            if p.returncode != 0:
                ok = False
        except (OSError, subprocess.TimeoutExpired) as e:
            results.append({"argv": argv, "rc": None, "stdout": "", "stderr": str(e)})
            ok = False
    return ok


def _toml_str(s):
    """Quote a string for TOML. JSON's escaping is a valid subset of TOML basic strings."""
    return json.dumps(s)


def _write_dropin(cfg, name, path, snapshot_dir):
    """Atomically write volumes.d/<name>.toml (temp file, fsync, rename)."""
    os.makedirs(cfg["dropin_dir"], mode=0o755, exist_ok=True)
    target = os.path.join(cfg["dropin_dir"], f"{name}.toml")
    body = (DROPIN_HEADER + "\n[volume]\n"
            f"name = {_toml_str(name)}\n"
            f"path = {_toml_str(path)}\n"
            f"snapshot_dir = {_toml_str(snapshot_dir)}\n")
    fd, tmp = tempfile.mkstemp(dir=cfg["dropin_dir"], prefix=".tmp-", suffix=".toml")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(body)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, target)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    # make the rename itself durable
    dfd = os.open(cfg["dropin_dir"], os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)
    return target


# =========================================================================== query

def op_list(cfg):
    """Everything the GUI displays: each volume, its source subvolume and its snapshots."""
    out = {"volumes": [], "config_errors": cfg["config_errors"],
           "create_parents": cfg["create_parents"]}
    mounted_ids, _ = _mounted_subvol_ids_and_points()

    for v in cfg["volumes"].values():
        entry = {
            "name": v["name"], "path": v["path"], "snapshot_dir": v["snapshot_dir"],
            "default_read_only": v["read_only"], "name_format": v["name_format"],
            "timestamp_format": v["timestamp_format"],
            "hooks": {"pre_snapshot": v["pre_snapshot"], "post_snapshot": v["post_snapshot"]},
            "origin": v["origin"], "origin_file": v["origin_file"],
            "removable": v["origin"] == "dropin",
            "data_deletable": False,
            "error": None, "source": None, "snapshots": [],
        }
        try:
            # Source subvolume details.
            src = _resolve_source(v)
            entry["source"] = _info_dict(src)
            entry["source"]["nocow"] = _get_nocow(src)
            entry["data_deletable"] = entry["removable"] and _parent_for(cfg, src) is not None

            # Every subvolume directly inside snapshot_dir, whoever made it.
            d = _resolve_snapdir(v)
            for name in sorted(os.listdir(d)):
                p = os.path.join(d, name)
                if os.path.islink(p) or not os.path.isdir(p):
                    continue
                try:
                    if not btrfsutil.is_subvolume(p):
                        continue
                    info = _info_dict(p)
                except btrfsutil.BtrfsUtilError:
                    continue
                info["name"] = name
                info["path"] = p
                info["of_source"] = info["parent_uuid"] == entry["source"]["uuid"]
                info["received"] = info["received_uuid"] != NIL_UUID
                info["mounted"] = info["id"] in mounted_ids
                info["manageable"] = bool(ENTRY_RE.match(name))
                entry["snapshots"].append(info)
            entry["snapshots"].sort(key=lambda s: s["otime"], reverse=True)
        except (SnapError, OSError, btrfsutil.BtrfsUtilError) as e:
            entry["error"] = str(e)
        out["volumes"].append(entry)
    return out, [], []


# =========================================================================== admin

def _take_snapshot(v, label, ro, run_hooks=True):
    """Create one snapshot of volume v. Shared by 'snapshot' and remove-volume's final snapshot."""
    if not LABEL_RE.match(label):
        raise SnapError("comment may only contain letters, digits, '.', '_' and '-' (max 64)")
    src = _resolve_source(v)
    d = _resolve_snapdir(v)

    # Build the name, e.g. win11_2026-11-15_09-30-00_pre_update. An empty label
    # leaves dangling separators ("X__" / "_X"), so tidy those up.
    ts = _dt.datetime.now().strftime(v["timestamp_format"])
    name = v["name_format"].format(volume=v["name"], timestamp=ts, label=label)
    name = re.sub(r"__+", "_", name).strip("_-")
    if not ENTRY_RE.match(name):
        raise SnapError(f"generated snapshot name is invalid: {name!r} (check name_format)")
    dest = os.path.join(d, name)
    if os.path.lexists(dest):
        raise SnapError(f"already exists: {dest}")

    cmd = _q("btrfs", "subvolume", "snapshot", *(["-r"] if ro else []), src, dest)
    hooks, warnings = [], []

    # Pre hooks (e.g. freeze a VM), the snapshot itself, then post hooks (thaw), which
    # always run, even if a pre hook or the snapshot failed.
    pre_ok = _run_hooks(v["pre_snapshot"], hooks) if run_hooks else True
    try:
        if not pre_ok:
            failed = next(h for h in hooks if h["rc"] != 0)
            raise SnapError(f"pre_snapshot hook failed ({_q(*failed['argv'])}: "
                            f"{failed['stderr'].strip() or 'rc=' + str(failed['rc'])}); "
                            "snapshot not taken, post hooks were still run")
        btrfsutil.create_snapshot(src, dest, read_only=ro)
    finally:
        if run_hooks and not _run_hooks(v["post_snapshot"], hooks):
            warnings.append("a post_snapshot hook failed; check the hook output")
    _log(f"snapshot {src} -> {dest} ro={ro}")

    # Informational, logged by the GUI rather than shown as a popup.
    notes = []
    if _get_nocow(src):
        notes.append("source is NOCOW: the first write to each extent after this snapshot "
                     "will be copied (fragmentation for VM images)")
    return {"name": name, "path": dest, "read_only": ro, "hooks": hooks, "notes": notes}, \
        [cmd], warnings


def op_snapshot(cfg, volume, label="", read_only=None):
    v = _volume(cfg, volume)
    ro = v["read_only"] if read_only is None else read_only
    return _take_snapshot(v, label, ro)


def op_delete(cfg, volume, entry):
    """Delete one snapshot from a volume's snapshot_dir."""
    v = _volume(cfg, volume)
    p = _resolve_entry(v, entry)
    _check_not_mounted(p)
    _check_no_nested(p)
    sid = btrfsutil.subvolume_id(p)
    btrfsutil.delete_subvolume(p)
    _log(f"delete {p} (id={sid})")
    return {"deleted": p}, [_q("btrfs", "subvolume", "delete", p)], []


def op_set_ro(cfg, volume, entry, value, force=False):
    """Flip a snapshot's read-only flag. Guards snapshots created by btrfs receive."""
    v = _volume(cfg, volume)
    p = _resolve_entry(v, entry)
    info = btrfsutil.subvolume_info(p)
    received = _uuid_str(info.received_uuid) != NIL_UUID
    if not value and received and not force:
        raise SnapError("RECEIVED_SNAPSHOT: this snapshot was created by btrfs receive; making it "
                        "writable breaks incremental send chains. Re-run with force to proceed.")
    btrfsutil.set_subvolume_read_only(p, value)
    _log(f"set-ro {p} {value} force={force}")
    warnings = ["received_uuid is now stale; incremental sends based on this snapshot will fail"] \
        if (not value and received) else []
    cmd = _q("btrfs", "property", "set", *(["-f"] if force else []), p, "ro", str(value).lower())
    return {"path": p, "read_only": value}, [cmd], warnings


# =========================================================================== manage

def op_new_volume(cfg, name, parent, folder=None, nocow=False, existing=False):
    """Create (or adopt) a subvolume under a create parent and register it as a drop-in.

    Creates <parent>/<folder> (a new subvolume, unless existing=True), creates
    <snapshot_root>/<folder>, then writes volumes.d/<name>.toml. If any step fails,
    the steps already done are undone.
    """
    folder = folder or name
    if not NAME_RE.match(name):
        raise SnapError(f"invalid volume name: {name!r}")
    if not NAME_RE.match(folder):
        raise SnapError(f"invalid folder name: {folder!r}")
    if name in cfg["volumes"]:
        raise SnapError(f"a volume called {name} already exists")
    par = next((p for p in cfg["create_parents"] if p["path"] == parent), None)
    if par is None:
        raise SnapError("parent is not a [[create.parent]] in config.toml")

    base = os.path.realpath(par["path"])
    snap_root = os.path.realpath(par["snapshot_root"])
    for d in (base, snap_root):
        if not os.path.isdir(d):
            raise SnapError(f"does not exist: {d}")
    src = os.path.join(base, folder)
    snapdir = os.path.join(snap_root, folder)
    for p in (src, snapdir):
        if not SAFE_PATH_RE.match(p):
            raise SnapError(f"path contains characters this tool won't write to config: {p}")

    # Pre-flight checks before touching anything.
    if existing:
        if not (os.path.isdir(src) and not os.path.islink(src) and btrfsutil.is_subvolume(src)):
            raise SnapError(f"{src} is not an existing subvolume")
        if nocow:
            raise SnapError("NOCOW can only be set when creating a new, empty subvolume")
    elif os.path.lexists(src):
        raise SnapError(f"already exists: {src} (tick 'use existing subvolume' to register it)")
    if os.path.islink(snapdir) or (os.path.lexists(snapdir) and not os.path.isdir(snapdir)):
        raise SnapError(f"{snapdir} exists and is not a directory")
    if os.path.isdir(snapdir) and os.listdir(snapdir) and not existing:
        raise SnapError(f"{snapdir} already contains files; refusing to mix with a new volume")

    commands, undo = [], []
    try:
        # 1. the subvolume itself
        if not existing:
            btrfsutil.create_subvolume(src)
            undo.append(lambda: btrfsutil.delete_subvolume(src))
            commands.append(_q("btrfs", "subvolume", "create", src))
            if nocow:
                _set_nocow(src)
                commands.append(_q("chattr", "+C", src))
        # 2. its snapshot folder
        if not os.path.isdir(snapdir):
            os.mkdir(snapdir, 0o755)
            undo.append(lambda: os.rmdir(snapdir))
            commands.append(_q("mkdir", snapdir))
        # 3. the drop-in that registers it
        target = _write_dropin(cfg, name, src, snapdir)
        commands.append(f"# wrote {target}")
    except BaseException:
        for fn in reversed(undo):
            try:
                fn()
            except Exception:
                pass
        raise
    _log(f"new-volume {name} path={src} snapshot_dir={snapdir} nocow={nocow} existing={existing}")
    return {"name": name, "path": src, "snapshot_dir": snapdir, "dropin": target}, commands, []


def op_remove_volume(cfg, name, delete_data=False, final_snapshot=True, delete_snapshots=False):
    """Unregister a drop-in volume, and optionally delete its data.

    delete_data=False   only removes volumes.d/<name>.toml; nothing on disk changes
    delete_data=True    also deletes the source subvolume, after these checks:
                        it sits directly under a [[create.parent]], isn't mounted,
                        has no nested subvolumes, and no process has files open in it
    final_snapshot      (with delete_data) takes a read-only snapshot first, so the
                        data survives until you delete that snapshot as well
    delete_snapshots    (with delete_data) also deletes every snapshot in snapshot_dir,
                        then the folder itself; can't be combined with final_snapshot
    """
    v = _volume(cfg, name)
    if v["origin"] != "dropin":
        raise SnapError(f"{name} is defined in {v['origin_file']}; remove it there by hand")
    if delete_snapshots and not delete_data:
        raise SnapError("delete_snapshots requires delete_data")
    if delete_snapshots and final_snapshot:
        raise SnapError("a final snapshot would be deleted along with the others; pick one")

    commands, warnings, result = [], [], {"name": name}

    if delete_data:
        src = _resolve_source(v)

        # Safety checks, all before anything is changed.
        par = _parent_for(cfg, src)
        if par is None:
            raise SnapError(f"{src} is not directly under a [[create.parent]]; the tool will only "
                            "unregister it, not delete it")
        _check_not_mounted(src)
        _check_no_nested(src)
        users = _processes_using(src)
        if users:
            raise SnapError(f"files in {src} are in use by: {', '.join(users)}. "
                            "Shut the VM/app down first.")
        snapdir = None
        if delete_snapshots:
            snapdir = _resolve_snapdir(v)
            if os.path.dirname(snapdir) != os.path.realpath(par["snapshot_root"]):
                raise SnapError(f"{snapdir} is not directly under {par['snapshot_root']}; "
                                "refusing to delete snapshots from there")
            snaps = [os.path.join(snapdir, e) for e in sorted(os.listdir(snapdir))]
            for p in snaps:
                if os.path.islink(p) or not os.path.isdir(p) or not btrfsutil.is_subvolume(p):
                    raise SnapError(f"{snapdir} contains {os.path.basename(p)}, which is not a "
                                    "snapshot; clean it up by hand first")
                _check_not_mounted(p)
                _check_no_nested(p)

        # Optional safety net: one last read-only snapshot of the data.
        if final_snapshot:
            snap, cmds, w = _take_snapshot(v, "final-before-remove", True, run_hooks=False)
            commands += cmds
            warnings += w
            result["final_snapshot"] = snap["path"]

        # Delete the source subvolume.
        btrfsutil.delete_subvolume(src)
        commands.append(_q("btrfs", "subvolume", "delete", src))
        _log(f"remove-volume {name}: deleted {src}")
        result["deleted"] = src

        # Optionally delete all its snapshots and the now-empty folder.
        if delete_snapshots:
            for p in snaps:
                btrfsutil.delete_subvolume(p)
                commands.append(_q("btrfs", "subvolume", "delete", p))
            os.rmdir(snapdir)
            commands.append(_q("rmdir", snapdir))
            _log(f"remove-volume {name}: deleted {len(snaps)} snapshots and {snapdir}")
            result["deleted_snapshots"] = len(snaps)

    # Finally, unregister it.
    os.unlink(v["origin_file"])
    commands.append(f"# removed {v['origin_file']}")
    _log(f"remove-volume {name}: unregistered ({v['origin_file']})")
    return result, commands, warnings


# =========================================================================== entry point

USAGE = {
    "query": "list",
    "admin": "snapshot VOLUME [COMMENT] [--ro|--rw] | delete VOLUME SNAPSHOT | "
             "set-ro VOLUME SNAPSHOT true|false [--force]",
    "manage": "new-volume NAME PARENT [FOLDER] [--nocow] [--existing] | "
              "remove-volume NAME [--delete-data] [--no-final-snapshot] [--delete-snapshots]",
}


def dispatch(mode, argv, cfg):
    """Map a command line to an operation. Each entry script only gets its own verbs."""
    if not argv:
        raise SnapError("usage: " + USAGE[mode])
    verb, args = argv[0], argv[1:]
    flags = {a for a in args if a.startswith("--")}
    pos = [a for a in args if not a.startswith("--")]

    if mode == "query":
        if verb == "list" and not args:
            return op_list(cfg)

    elif mode == "admin":
        if verb == "snapshot" and 1 <= len(pos) <= 2 and flags <= {"--ro", "--rw"} \
                and len(flags) <= 1:
            ro = True if "--ro" in flags else False if "--rw" in flags else None
            return op_snapshot(cfg, pos[0], pos[1] if len(pos) > 1 else "", ro)
        if verb == "delete" and len(pos) == 2 and not flags:
            return op_delete(cfg, *pos)
        if verb == "set-ro" and len(pos) == 3 and pos[2] in ("true", "false") \
                and flags <= {"--force"}:
            return op_set_ro(cfg, pos[0], pos[1], pos[2] == "true", "--force" in flags)

    elif mode == "manage":
        if verb == "new-volume" and 2 <= len(pos) <= 3 and flags <= {"--nocow", "--existing"}:
            return op_new_volume(cfg, pos[0], pos[1], pos[2] if len(pos) > 2 else None,
                                 "--nocow" in flags, "--existing" in flags)
        if verb == "remove-volume" and len(pos) == 1 and \
                flags <= {"--delete-data", "--no-final-snapshot", "--delete-snapshots"}:
            # A final snapshot is the default when deleting data, unless the snapshots
            # are being deleted too (it would be deleted with them).
            delete_data = "--delete-data" in flags
            delete_snaps = "--delete-snapshots" in flags
            final = delete_data and not delete_snaps and "--no-final-snapshot" not in flags
            return op_remove_volume(cfg, pos[0], delete_data, final, delete_snaps)

    raise SnapError("usage: " + USAGE[mode])


def main(mode, argv, config_path=CONFIG_PATH, enforce_ownership=True):
    """Called by the entry scripts. Prints one JSON object; exit code 0 = success."""
    if os.geteuid() != 0:
        print(json.dumps({"ok": False, "error": "helper must run as root (via pkexec)"}))
        return 1
    try:
        cfg = load_config(config_path, enforce_ownership)
        result, commands, warnings = dispatch(mode, argv, cfg)
        print(json.dumps({"ok": True, "result": result, "commands": commands, "warnings": warnings}))
        return 0
    except (SnapError, btrfsutil.BtrfsUtilError, OSError, tomllib.TOMLDecodeError, KeyError) as e:
        print(json.dumps({"ok": False, "error": str(e)}))
        return 1
