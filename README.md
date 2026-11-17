# btrfs-snapman

A small tool for managing btrfs subvolumes and snapshots by hand, with two front ends: a GTK4/libadwaita GUI (`btrfs-snapman`) and a terminal interface for SSH and headless machines such as a Raspberry Pi (`btrfs-snapman-cli`). It's built for the layout where you keep one subvolume per thing (e.g. per VM or per container stack) and its snapshots in a matching `snapshots/<name>` folder. It doesn't use Snapper and doesn't impose a layout.

## What it does
- **Lists** each volume and every snapshot in its snapshot folder, newest first. That includes snapshots made by hand or by scripts; they're matched to their source by `parent_uuid`.
- **Snapshot**: read-only by default. The name is built from a configurable format, and the dialog previews it live. Comments are cleaned: spaces become `_`, and only letters, digits, `_` and `-` are kept.
- **Read-only switch** for each snapshot. A snapshot created by `btrfs receive` asks for an extra confirmation before going writable.
- **Delete snapshot**: you type `delete` to confirm. It refuses mounted snapshots and snapshots containing nested subvolumes.
- **New volume**: creates the subvolume (optionally with NOCOW) and its snapshot folder, and registers it, all in one step. It can also register a subvolume that already exists. If any step fails, the earlier steps are undone.
- **Approve a new location**: **Browse…** next to Parent picks any folder. If it isn't a parent yet, you're asked to approve it, together with a snapshot root (default: `<mount point>/snapshots` of the same filesystem, changeable with a second Browse). The snapshot root is created if it's missing.
- **Remove volume**: either unregister only, leaving the data alone, or delete the subvolume. By default it takes a final read-only snapshot first. It can also delete every snapshot and the snapshot folder.
- **Command log**: every action shows the equivalent `btrfs` command, and every change is logged to the journal (`journalctl -t btrfs-snapman`).

## Terminal interface
`btrfs-snapman-cli` does everything the GUI does, through the same helpers and config.

- **Full screen**: run it with no arguments. Volumes on the left, the selected volume's snapshots on the right, the command log below; `?` lists the keys (`s` snapshot, `d` delete, `r` read-only, `n` new volume, `x` remove volume, `a` approve a location, `L` locations, `l` log, `q` quit). Works over SSH and inside tmux or screen, at 80×24 or larger, with or without colour (`NO_COLOR`) and in a non-UTF-8 locale.
- **One command at a time**, for scripts and cron:
  ```
  btrfs-snapman-cli list                          # volumes
  btrfs-snapman-cli list Docker                   # its snapshots, newest first
  btrfs-snapman-cli snapshot Docker "before pihole v6"
  # -> Docker_2026-11-17_09-45-02_before_pihole_v6
  btrfs-snapman-cli delete Docker Docker_2026-11-10_08-00-00 --yes
  btrfs-snapman-cli set-ro Docker Docker_2026-11-10_08-00-00 off
  btrfs-snapman-cli new-volume Pihole /srv/containers
  btrfs-snapman-cli remove-volume Pihole --delete-data
  btrfs-snapman-cli locations | add-location PATH | remove-location PATH
  ```
  Results go to stdout; the equivalent commands, notes, hook output and warnings to stderr. `--json` prints the helper's JSON instead. Destructive commands ask you to type a confirmation on a terminal, and need `--yes` (or `--force` for making a received snapshot writable) without one. Exit codes: 0 ok, 1 refused or failed, 2 usage, 3 authentication, 4 not confirmed, 130 interrupted. See `man btrfs-snapman-cli`.

## Security model
- Both front ends run as you. Every operation goes to one of three small root helpers: the GUI through `pkexec` and polkit, the terminal interface through `sudo` (there's no polkit agent over SSH), or directly when already root, e.g. from cron.

  | Helper | Operations | GUI (polkit) | Terminal (sudo) |
  |---|---|---|---|
  | `snapman-query` | list | no password (active local session) | sudo timestamp |
  | `snapman-admin` | snapshot, delete snapshot, set read-only | password, cached a few minutes | sudo timestamp (15 minutes) |
  | `snapman-manage` | new volume, remove volume, approve / remove a location | password **every time** | password **every time** (`sudo -k`, then `sudo -v`) |

- The terminal interface calls `sudo -n /usr/libexec/btrfs-snapman/snapman-<mode> ...` as an argument list, never through a shell. When sudo wants a password, `sudo -v` asks for it on the terminal (the full-screen interface steps aside while it does) and the call is retried once. The program never reads, stores or passes on your password. Without a terminal nothing can be asked: unattended jobs run as root, or rely on a sudoers rule.
- Optional sudo rules are in `/usr/share/doc/btrfs-snapman-cli/examples/sudoers.example` (not installed): listing without a password for the `sudo` group, and list/snapshot rights for a dedicated `snapman` group. Install them with `sudo visudo -f /etc/sudoers.d/btrfs-snapman` and check the result with `sudo visudo -c`. Password-free listing is off by default.

- The helpers accept names only, with one exception: approving a location (`add-parent PATH SNAPSHOT_ROOT`). Every other path comes from root-owned config, and the helpers refuse to start if `config.toml` is writable by anyone other than root. A drop-in file with bad permissions is skipped and reported instead.
- `add-parent` only accepts two absolute, existing, real directories (no symlink anywhere in the path) on the **same** btrfs filesystem, compared by fsid. It refuses `/`, `/boot`, `/etc`, `/usr`, `/var/lib`, and anything under `/proc`, `/sys` or `/dev`.
- The tool **never edits `config.toml`**. Volumes created in either front end are written to `volumes.d/<name>.toml`, and approved locations to `parents.d/<path>.toml`, one file each; removing the volume or location deletes that file. Anything defined in `config.toml` can't be removed from the tool.
- Snapshot deletes are confined to the volume's snapshot folder; symlinks and `..` are rejected.
- **Deleting a volume's data** is only allowed when the subvolume sits directly under a create parent (`[[create.parent]]` or `parents.d`). The tool also refuses if:
  - the subvolume is mounted,
  - it contains nested subvolumes, or
  - any process has files open in it. The error names the process, e.g. a running VM.
- All btrfs operations go through libbtrfsutil. Hooks run without a shell, with a clean environment and a 120-second timeout.
- The journal records who acted: `PKEXEC_UID` via the GUI, `SUDO_UID` via the terminal interface.

## Install (Ubuntu 24.04 / 26.04)
Three packages, built from this source:

| Package | Contains | For |
|---|---|---|
| `btrfs-snapman-common` | root helpers, shared modules, `libvirt-fsfreeze`, `/etc/btrfs-snapman` | both |
| `btrfs-snapman` | the GTK GUI, its polkit actions and desktop file | desktops |
| `btrfs-snapman-cli` | the terminal interface and its sudoers example | everything, including headless machines |

```
git clone https://github.com/DarthDogCow/btrfs-snapman && cd btrfs-snapman
sudo ./install.sh                 # common + GUI + terminal interface
sudo ./install.sh --cli           # common + terminal interface only: no GTK or polkit (e.g. a Pi)
btrfs-snapman                     # or "Btrfs Snapshots" in the app grid
btrfs-snapman-cli                 # full screen in a terminal
```
`install.sh` installs `build-essential` and `debhelper` if they're missing, builds the packages with `dpkg-buildpackage -us -uc -b`, and installs them with `apt`, which pulls in the dependencies. Copies of the `.deb`s are left in the source folder. Release builds are also attached to each [GitHub release](https://github.com/DarthDogCow/btrfs-snapman/releases). On a headless machine such as a Raspberry Pi (the packages are `Architecture: all`, so the same files work on arm64):
```
sudo apt install ./btrfs-snapman-common_0.7.0_all.deb ./btrfs-snapman-cli_0.7.0_all.deb
```

| Path | |
|---|---|
| `/usr/bin/btrfs-snapman` | the GUI |
| `/usr/bin/btrfs-snapman-cli` | the terminal interface |
| `/usr/libexec/btrfs-snapman/` | root helpers and `libvirt-fsfreeze` |
| `/usr/lib/btrfs-snapman/snapman_core.py` | shared root-side code |
| `/usr/lib/btrfs-snapman/snapman_client.py` | code shared by the two front ends (unprivileged) |
| `/usr/share/polkit-1/actions/io.github.darthdogcow.BtrfsSnapman.policy` | the three polkit actions (GUI) |
| `/etc/btrfs-snapman/config.toml` | config (a dpkg conffile) |
| `/etc/btrfs-snapman/volumes.d/` | one file per volume created with the tool; owned by the package, contents never touched |
| `/etc/btrfs-snapman/parents.d/` | one file per approved location; likewise |

**Upgrading:** pull and run `sudo ./install.sh` again (with `--cli` on headless machines). Your `config.toml` is kept; if the packaged example changed, the new one is saved next to it as `config.toml.dpkg-dist`. The annotated example is always at `/usr/share/doc/btrfs-snapman-common/examples/config.example.toml`. Upgrading from 0.6.0, where one `btrfs-snapman` package held everything, moves the config to `btrfs-snapman-common` without a prompt and leaves `volumes.d` and `parents.d` alone.

**Removing:** `sudo ./install.sh --uninstall` (or `sudo apt remove btrfs-snapman btrfs-snapman-cli btrfs-snapman-common`) keeps `/etc/btrfs-snapman`. Purging `btrfs-snapman-common` deletes `config.toml` too, but leaves your `volumes.d/*.toml` and `parents.d/*.toml` files. Versions before 0.5.0 were copied into `/usr/local`; `install.sh` removes that copy in either mode.

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

[[volume]]                                     # optional: volumes defined by hand (the tool can't remove these)
name = "Home"
path = "/home"
snapshot_dir = "/snapshots/home"
```
`volumes.d/<name>.toml` (normally written by New volume; the file name must match `name`):
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

`parents.d/<path>.toml` (written when you approve a location; the name is the path with `/` turned into `-`):
```toml
[parent]
path = "/mnt/vmstorage/vmdisks"
snapshot_root = "/mnt/vmstorage/snapshots"
```
There's no GUI button to withdraw an approval yet: use `btrfs-snapman-cli remove-location /mnt/vmstorage/vmdisks`, the `L` screen of the terminal interface, or delete the file. Volumes already created there stay registered, but their data can no longer be deleted from the tool.

## Recovering a removed volume
When you remove a volume and keep its snapshots (with or without the final snapshot), they stay in its snapshot folder but are no longer listed. To bring the volume back:
```
sudo btrfs subvolume snapshot /mnt/vmstorage/snapshots/X/X_<time>_final-before-remove /mnt/vmstorage/vmdisks/X
```
Then use **New volume → Use existing subvolume** with the same folder name (or `btrfs-snapman-cli new-volume X /mnt/vmstorage/vmdisks --existing`). The old snapshots reappear, but they show as "not from this source", because the restored subvolume is a new snapshot with a new UUID.

## VM disk notes
- A snapshot of a running VM's disk is **crash-consistent only**, the same as pulling the power.
- `libvirt-fsfreeze` (installed in `/usr/libexec/btrfs-snapman/`) freezes and thaws guest filesystems through `virsh` on `qemu:///system`. It needs `qemu-guest-agent` in each guest. It does **not** see GNOME Boxes or other `qemu:///session` VMs.
- NOCOW (`chattr +C`) reduces fragmentation for VM images, but turns off checksums and compression for those files. After a snapshot, the first write to each extent is copied anyway. It can only be set on an empty folder, which is why it's offered in New volume.

## Tests
| Test | Run as | What it covers |
|---|---|---|
| `python3 tests/test_client.py` | you | `snapman_client.py`: comment cleaning, name preview, the remove summaries, helper result classification, the snapshot-root rule |
| `sudo PY=/usr/bin/python3 tests/test_core.sh src` | root | 146 checks against the helpers on two 1 GB loopback btrfs filesystems: snapshots, hooks, path and symlink confinement, the received-snapshot guard, mounted and nested snapshots, drop-in loading and permissions, new-volume rollback, remove-volume with each option (including refusal while a file is open), add-parent / remove-parent, and the caller UID in the journal |
| `sudo PY=/usr/bin/python3 tests/test_cli.sh src` | root | every `btrfs-snapman-cli` subcommand on loopback btrfs: exit codes, stdout/stderr split, `--json`, confirmations with and without a terminal |
| `sudo PY=/usr/bin/python3 tests/test_tui.sh src` | root, needs `tmux` | the full-screen interface at 80×24 through `tmux send-keys` / `capture-pane`: every dialog, checked on screen and on disk, plus resizing, `LANG=C`, `TERM=screen`/`linux` and `NO_COLOR` |

These three create and remove users, packages or `/etc` files, so run them **only on a disposable VM or container** (Ubuntu 24.04):

| Test | What it covers |
|---|---|
| `sudo tests/test_sudo.sh` | with the 0.7.0 packages installed: the first `sudo -v`, timestamp reuse and expiry, manage verbs asking every time, a wrong password (exit 3), the TUI stepping aside for sudo, the sudoers example, and that the password never shows in the process list |
| `sudo tests/test_upgrade.sh OLD.deb NEW_DIR` | 0.6.0 → 0.7.0: an edited `config.toml` survives byte-identical with no prompt and no `.dpkg-*` files, `volumes.d` is untouched, and `btrfs-snapman-common` owns the conffile |
| `tests/test_headless.sh NEW_DIR` | installing common + CLI pulls in no GTK, gir, pkexec or polkit |

Build the packages with `dpkg-buildpackage -us -uc -b` and check them with `lintian --fail-on error,warning *.changes`. For the upgrade test, build the 0.6.0 package from its tag: `git archive --prefix=btrfs-snapman/ v0.6.0 | tar x -C /tmp`, then `dpkg-buildpackage -us -uc -b` in `/tmp/btrfs-snapman`.

## Not done (yet)
- Retention or pruning rules
- `send`/`receive` to another host
- Restoring a volume from a snapshot in the GUI (see the recipe above)
- Per-snapshot sizes (these need qgroups, which are deliberately not enabled)
