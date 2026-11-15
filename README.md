# btrfs-snapman

A small GTK4/libadwaita GUI for managing btrfs subvolumes and snapshots by hand. It's built for the layout where you keep one subvolume per thing (e.g. per VM) and its snapshots in a matching `snapshots/<name>` folder. It doesn't use Snapper and doesn't impose a layout.

## What it does
- **Lists** each volume and every snapshot in its snapshot folder, newest first. That includes snapshots made by hand or by scripts; they're matched to their source by `parent_uuid`.
- **Snapshot**: read-only by default. The name is built from a configurable format, and the dialog previews it live. Comments are cleaned: spaces become `_`, and only letters, digits, `_` and `-` are kept.
- **Read-only switch** for each snapshot. A snapshot created by `btrfs receive` asks for an extra confirmation before going writable.
- **Delete snapshot**: you type `delete` to confirm. It refuses mounted snapshots and snapshots containing nested subvolumes.
- **New volume**: creates the subvolume (optionally with NOCOW) and its snapshot folder, and registers it, all in one step. It can also register a subvolume that already exists. If any step fails, the earlier steps are undone.
- **Remove volume**: either unregister only, leaving the data alone, or delete the subvolume. By default it takes a final read-only snapshot first. It can also delete every snapshot and the snapshot folder.
- **Command log**: every action shows the equivalent `btrfs` command, and every change is logged to the journal (`journalctl -t btrfs-snapman`).

## Security model
- The GUI runs as you. Every operation goes through `pkexec` to one of three small root helpers, each with its own polkit rule:

  | Helper | Operations | Password |
  |---|---|---|
  | `snapman-query` | list | none (active local session) |
  | `snapman-admin` | snapshot, delete snapshot, set read-only | yes, cached a few minutes |
  | `snapman-manage` | new volume, remove volume | yes, **every time** |

- The helpers accept names only, never arbitrary paths. Every path comes from root-owned config, and the helpers refuse to start if `config.toml` is writable by anyone other than root. A drop-in file with bad permissions is skipped and reported instead.
- The tool **never edits `config.toml`**. Volumes created in the GUI are written to `volumes.d/<name>.toml`, one file each, and removing the volume deletes that file. Volumes defined in `config.toml` can't be removed from the GUI.
- Snapshot deletes are confined to the volume's snapshot folder; symlinks and `..` are rejected.
- **Deleting a volume's data** is only allowed when the subvolume sits directly under a `[[create.parent]]` path. The tool also refuses if:
  - the subvolume is mounted,
  - it contains nested subvolumes, or
  - any process has files open in it. The error names the process, e.g. a running VM.
- All btrfs operations go through libbtrfsutil. Hooks run without a shell, with a clean environment and a 120-second timeout.

## Install (Ubuntu 24.04 / 26.04)
```
git clone https://github.com/DarthDogCow/btrfs-snapman && cd btrfs-snapman
sudo ./install.sh                 # builds btrfs-snapman_<version>_all.deb and installs it with apt
btrfs-snapman                     # or "Btrfs Snapshots" in the app grid
```
`install.sh` installs `debhelper` if it's missing, builds the package with `dpkg-buildpackage -us -uc -b`, and installs it with `apt`, which pulls in the dependencies. A copy of the `.deb` is left in the source folder. Release builds are also attached to each [GitHub release](https://github.com/DarthDogCow/btrfs-snapman/releases): `sudo apt install ./btrfs-snapman_<version>_all.deb`.

| Path | |
|---|---|
| `/usr/bin/btrfs-snapman` | the GUI |
| `/usr/libexec/btrfs-snapman/` | root helpers and `libvirt-fsfreeze` |
| `/usr/lib/btrfs-snapman/snapman_core.py` | shared root-side code |
| `/usr/share/polkit-1/actions/io.github.darthdogcow.BtrfsSnapman.policy` | the three polkit actions |
| `/etc/btrfs-snapman/config.toml` | config (a dpkg conffile) |
| `/etc/btrfs-snapman/volumes.d/` | one file per GUI-created volume; owned by the package, contents never touched |

**Upgrading:** pull and run `sudo ./install.sh` again. Your `config.toml` is kept; if the packaged example changed, the new one is saved next to it as `config.toml.dpkg-dist`. The annotated example is always at `/usr/share/doc/btrfs-snapman/examples/config.example.toml`.

**Removing:** `sudo ./install.sh --uninstall` (or `sudo apt remove btrfs-snapman`) keeps `/etc/btrfs-snapman`. `apt purge` deletes `config.toml` too, but leaves your `volumes.d/*.toml` files. Versions before 0.5.0 were copied into `/usr/local`; `install.sh` removes that copy in either mode.

Machine-specific configs and one-off scripts can go in `local/`, which git ignores.

## Config reference
`config.toml`:
```toml
[defaults]
name_format = "{volume}_{timestamp}_{label}"   # tokens: {volume} {timestamp} {label}; an empty label drops cleanly
timestamp_format = "%Y-%m-%d_%H-%M-%S"         # strftime; may only produce [A-Za-z0-9._+-]
read_only = true

[[create.parent]]                              # where "New volume" may create subvolumes
path = "/mnt/vmstorage/vmdisks"
snapshot_root = "/mnt/vmstorage/snapshots"     # snapshots of <path>/<folder> go in <snapshot_root>/<folder>

[[volume]]                                     # optional: volumes defined by hand (the GUI can't remove these)
name = "Home"
path = "/home"
snapshot_dir = "/snapshots/home"
```
`volumes.d/<name>.toml` (normally written by the GUI; the file name must match `name`):
```toml
[volume]
name = "win11"
path = "/mnt/vmstorage/vmdisks/win11"
snapshot_dir = "/mnt/vmstorage/snapshots/win11"
# optional, any volume: name_format, timestamp_format, read_only, and hooks
# pre_snapshot  = [["/usr/libexec/btrfs-snapman/libvirt-fsfreeze", "freeze", "win11"]]
# post_snapshot = [["/usr/libexec/btrfs-snapman/libvirt-fsfreeze", "thaw",   "win11"]]
```
If a pre hook fails, the snapshot is aborted. Post hooks always run.

## Recovering a removed volume
When you remove a volume and keep its snapshots (with or without the final snapshot), they stay in its snapshot folder but are no longer listed. To bring the volume back:
```
sudo btrfs subvolume snapshot /mnt/vmstorage/snapshots/X/X_<time>_final-before-remove /mnt/vmstorage/vmdisks/X
```
Then use **New volume → Use existing subvolume** with the same folder name. The old snapshots reappear, but they show as "not from this source", because the restored subvolume is a new snapshot with a new UUID.

## VM disk notes
- A snapshot of a running VM's disk is **crash-consistent only**, the same as pulling the power.
- `libvirt-fsfreeze` (installed in `/usr/libexec/btrfs-snapman/`) freezes and thaws guest filesystems through `virsh` on `qemu:///system`. It needs `qemu-guest-agent` in each guest. It does **not** see GNOME Boxes or other `qemu:///session` VMs.
- NOCOW (`chattr +C`) reduces fragmentation for VM images, but turns off checksums and compression for those files. After a snapshot, the first write to each extent is copied anyway. It can only be set on an empty folder, which is why it's offered in New volume.

## Tests
`sudo PY=/usr/bin/python3 tests/test_core.sh src` builds a 1 GB loopback btrfs and runs 77 checks against the helpers: snapshots, hooks, path and symlink confinement, the received-snapshot guard, refusal of mounted and nested snapshots, drop-in loading and permissions, new-volume rollback, and remove-volume with each option, including refusal while a file is open.

## Not done (yet)
- Retention or pruning rules
- `send`/`receive` to another host
- Restoring a volume from a snapshot in the GUI (see the recipe above)
- Per-snapshot sizes (these need qgroups, which are deliberately not enabled)
