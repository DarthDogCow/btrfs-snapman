# btrfs-snapman-cli — spec for Claude Code

Nov 17, 2026

## Goal and scope

Build **btrfs-snapman-cli**: a terminal front end for btrfs-snapman that does everything the GTK GUI does, usable over SSH on headless Raspberry Pis. It talks to the **same root helpers, config and JSON contract** as the GUI. No root-side logic is duplicated, and the GUI keeps working unchanged.

It has two modes from one command:

- **Interactive** (`btrfs-snapman-cli` with no arguments, on a terminal): a full-screen curses TUI.
- **Scriptable** (`btrfs-snapman-cli <subcommand> …`): one operation, plain or JSON output, meaningful exit codes. For cron, pre-upgrade snapshots and shell scripts.

The work also splits the Debian packaging so a Pi can install the CLI without GTK, and adds `sudo` as the privilege path for the console (polkit stays for the GUI). Target release: **0.7.0**.

## Context: what exists (repo at 0.6.0)

The CLI is a second **unprivileged** client of the existing root helpers. Read `README.md`, `src/snapman_core.py` and `src/btrfs-snapman` before starting.

| Component | Path when installed | Runs as | Role |
| --- | --- | --- | --- |
| `btrfs-snapman` | `/usr/bin/` | user | GTK4/libadwaita GUI; calls helpers via `pkexec` |
| `snapman-query` | `/usr/libexec/btrfs-snapman/` | root | `list` |
| `snapman-admin` | `/usr/libexec/btrfs-snapman/` | root | `snapshot`, `delete`, `set-ro` |
| `snapman-manage` | `/usr/libexec/btrfs-snapman/` | root | `new-volume`, `remove-volume`, `add-parent`, `remove-parent` |
| `snapman_core.py` | `/usr/lib/btrfs-snapman/` | root | All validation and btrfs work (libbtrfsutil) |
| Config | `/etc/btrfs-snapman/config.toml`, `volumes.d/`, `parents.d/` | — | Root-owned allowlist of volumes and create parents |

Helper contract (exact usage strings are in `USAGE` in `snapman_core.py`):

- Each helper prints **one JSON object** on stdout: `{"ok": true, "result": …, "commands": […], "warnings": […]}` or `{"ok": false, "error": "…"}`. Exit 0 on success, 1 on failure.
- `commands` = equivalent shell commands for the command log. Lines starting `#` are notes, not commands.
- `result.notes` (informational) and `result.hooks` (hook output) may appear on snapshot results.
- `list` returns `volumes[]` (name, path, snapshot\_dir, source info, snapshots\[\], origin, removable, data\_deletable, error, hooks, name\_format, timestamp\_format, default\_read\_only), `create_parents[]` (path, snapshot\_root, origin, origin\_file) and `config_errors[]`.
- Error strings are user-facing. `RECEIVED_SNAPSHOT:` prefix on a `set-ro` error means "confirm, then retry with `--force`".

Invariants the CLI must keep:

1. **Never import `snapman_core` or `btrfsutil` in the CLI.** All privileged work goes through the three helpers, exactly as the GUI does.
2. **No new root-side verbs** unless strictly needed; if one is, add it to `snapman_core.py` with tests, not to the CLI.
3. The CLI never writes to `/etc/btrfs-snapman` itself.
4. Behaviour and wording match the GUI where both exist (name preview, comment sanitising, confirmation rules, summaries).

## Target environment

The primary target is a headless Raspberry Pi 5 reached over SSH; the CLI must also work on the existing Ubuntu desktop.

|  | Raspberry Pi (primary) | Desktop (secondary) |
| --- | --- | --- |
| OS | Ubuntu 24.04 LTS, raspi kernel, **arm64** | Ubuntu 24.04 / 26.04, amd64 |
| Session | SSH, no desktop, no polkit agent | local terminal or SSH |
| Python | system `/usr/bin/python3` (3.12 on 24.04) | same |
| btrfs | data volumes on btrfs (e.g. a multi-disk array, a USB SSD) | root + separate data disk |
| Terminal | `xterm-256color`, often inside `tmux` / `screen` | GNOME Terminal |

Constraints:

- **Python standard library only** on the client side (curses, argparse, json, subprocess). Nothing from pip.
- Must work at **80×24** and degrade cleanly below that (show "terminal too small", don't crash). Handle resize.
- Must work with `TERM=screen`, `tmux-256color`, `linux` and without colour; respect `NO_COLOR`.
- Must work in a non-UTF-8 locale (`LANG=C`): fall back to ASCII for borders and markers.
- No mouse required; keyboard only.
- Do **not** commit machine-specific configs, hostnames or IPs to the repo; use `local/` (git-ignored) for anything per-Pi.

## Privilege model: sudo, not pkexec

The CLI runs as the user and reaches the helpers through **`sudo`**. Over SSH there is no active local session and no polkit agent, so the GUI's polkit rules don't fit; `sudo` is the established tool for administering a box over SSH.

Rules:

1. **Already root** (euid 0, e.g. cron or `sudo -i`): call the helper path directly, no `sudo`. Show "running as root" in the TUI header.
2. **Not root**: before curses starts (and before any scriptable operation), run `sudo -v` on the real terminal. If it fails (wrong password, not in sudoers), exit 1 with a plain message.
3. **Every helper call**: `sudo -n /usr/libexec/btrfs-snapman/snapman-<mode> <args>` as an argv list. Absolute path, no shell, no environment passing.
4. **Expired timestamp**: if `sudo -n` fails with empty stdout and stderr beginning `sudo:`, suspend curses (`def_prog_mode()` + `endwin()`), run `sudo -v`, restore the screen, retry **once**. Second failure = show the error.
5. **`snapman-admin`** (snapshot, delete, set-ro) relies on the sudo timestamp (15 min by default on Ubuntu). This mirrors polkit `auth_admin_keep`.
6. **`snapman-manage`** (new/remove volume, add/remove parent) asks for the password **every time**: `sudo -k` then `sudo -v` immediately before the call, mirroring polkit `auth_admin`. In scriptable mode without a TTY this fails with a clear message; unattended manage operations must run as root.
7. **`snapman-query`** also needs root. Listing therefore uses the timestamp like admin calls.
8. Never read, store or pipe the password (`sudo -S` is forbidden). Never call `sudo` through a shell.

Optional, documented but **not** installed by the package: a sudoers example in `/usr/share/doc/btrfs-snapman-cli/examples/sudoers.example`, e.g. password-free listing for the `sudo` group and snapshot rights for a dedicated `snapman` group:

```
%sudo    ALL=(root) NOPASSWD: /usr/libexec/btrfs-snapman/snapman-query
%snapman ALL=(root) /usr/libexec/btrfs-snapman/snapman-query, /usr/libexec/btrfs-snapman/snapman-admin
```

The README must tell people to install it with `visudo -f /etc/sudoers.d/btrfs-snapman` and check it with `visudo -c`.

Root-side changes this needs (small, in `snapman_core.py`, with tests):

- `_log()` records the caller as `PKEXEC_UID`, else `SUDO_UID`, else `getuid()`, so the journal shows who acted via either path.
- The "must run as root" error says "via pkexec or sudo".

## Command-line interface

One command, `btrfs-snapman-cli`, built on `argparse` with subcommands. No subcommand on a TTY starts the TUI; no subcommand without a TTY prints usage and exits 2.

| Subcommand | Helper call | Notes |
| --- | --- | --- |
| `list [VOLUME]` | query `list` | No VOLUME: one line per volume (name, path, snapshot count, error). With VOLUME: its snapshots, newest first (name, created, age, RO/RW, flags: received, mounted, not from this source). |
| `locations` | query `list` | The create parents: path, snapshot root, where defined. |
| `snapshot VOLUME [COMMENT] [--ro\|--rw]` | admin `snapshot` | COMMENT sanitised exactly as the GUI does. Prints the created snapshot name. |
| `delete VOLUME SNAPSHOT [--yes]` | admin `delete` | On a TTY: prompt "Type delete to confirm" (case and surrounding spaces ignored). Without a TTY: refuses unless `--yes`. |
| `set-ro VOLUME SNAPSHOT on\|off [--force]` | admin `set-ro` | On `RECEIVED_SNAPSHOT:` error: TTY asks y/N, then retries with `--force`; without a TTY, needs `--force`. |
| `new-volume NAME PARENT [--folder F] [--nocow] [--existing]` | manage `new-volume` | PARENT must be a listed location. |
| `remove-volume NAME [--delete-data] [--no-final-snapshot] [--delete-snapshots] [--yes]` | manage `remove-volume` | Prints the same plain-English summary as the GUI, then: TTY asks to type the volume name; without a TTY, needs `--yes`. |
| `add-location PATH [--snapshot-root DIR]` | manage `add-parent` | Default snapshot root = `<mount point of PATH>/snapshots`, the GUI's rule. |
| `remove-location PATH [--yes]` | manage `remove-parent` | Confirm as for delete. |

Global options: `--json` (print the helper's JSON object unchanged, one per call), `--no-color`, `--version`, `-h`. A hidden `--libexec DIR` for tests, as in the GUI.

Output rules:

- Results go to **stdout**. Equivalent commands (`$ …`), notes, hook output and warnings go to **stderr**, so scripts can capture the result cleanly.
- Times in local time, `YYYY-MM-DD HH:MM:SS`, plus a relative age in `list`.
- No colour when stdout is not a TTY or `NO_COLOR` is set.

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | The helper refused or failed (`ok: false`); its error is printed to stderr |
| 2 | Usage error |
| 3 | Authentication failed or cancelled |
| 4 | Confirmation declined, or needed but no TTY and no `--yes` / `--force` |
| 130 | Interrupted (Ctrl-C) |

Example, the typical Pi use case before a container upgrade:

```
btrfs-snapman-cli snapshot Docker "before pihole v6"
# -> Docker_2026-11-17_09-45-02_before_pihole_v6
```

## Interactive TUI

Use the standard library **`curses`** (run under `curses.wrapper`, `ESCDELAY=25`). Two panes over a collapsible command log, like the GUI, keyboard only.

```
 btrfs-snapman · <hostname>                                  ? help  q quit
 1 config file could not be loaded — press l for details
┌ Volumes ──────────────┐┌ docker · /srv/docker ──────────────────────────────┐
│> docker          4   ││ Snapshots  /srv/snapshots/docker                    │
│  homeassistant   2   ││ Subvolume  ID 258 · 1a2b3c4d-…                      │
│  backups         !   ││ Registered volumes.d/docker.toml (managed)          │
│                      ││                                                     │
│                      ││ Snapshots (4)                       newest first    │
│                      ││ > docker_2026-11-17_09-45-02_before  3m ago  RO     │
│                      ││   docker_2026-11-10_08-00-00        7d ago  RO     │
└──────────────────────┘└───────────────────────────────────────────┘
 Log ─ $ btrfs subvolume snapshot -r /srv/docker /srv/snapshots/docker/…
 s snapshot  d delete  r read-only  n new vol  x remove vol  a location  l log
```

Keys:

| Key | Action |
| --- | --- |
| ↑ ↓ / j k, PgUp PgDn, Home End | Move in the focused pane |
| Tab, ← → | Switch pane |
| Enter (on a snapshot) | Details popup: every field from `list`, including full path and UUIDs, for copying with the terminal |
| s | Snapshot the selected volume |
| d, Delete | Delete the selected snapshot |
| r | Toggle the selected snapshot's read-only flag |
| n | New volume |
| x | Remove the selected volume (only if `removable`) |
| a | Approve a new location |
| L | Locations screen: list create parents; remove `parents.d` ones |
| l | Expand / collapse the command log to full screen |
| F5, Ctrl-R | Refresh |
| ? | Help screen listing these keys |
| q | Quit (Esc closes a dialog; in the main view it does nothing) |

Dialogs (one generic modal form component: text fields with ← → Home End Backspace Delete Ctrl-U; Space toggles; ← → cycles choices; info lines that update live; Enter submits only when valid; Esc cancels):

| Dialog | Fields and behaviour (same as the GUI) |
| --- | --- |
| Snapshot | Comment; live **Name** preview; Read-only toggle (default from the volume); notes when hooks will run or the source is NOCOW |
| Delete snapshot | Shows the name; type `delete` (case and surrounding spaces ignored) |
| Read-only | No dialog. On a received snapshot going writable: y/N warning, then `--force` |
| New volume | Parent (choice); Name; Folder (optional, defaults to Name); Use existing; NOCOW (disabled with Use existing); live "Will create" lines. Button text Create / Register |
| Remove volume | Delete data (disabled with the reason when not `data_deletable` or on error); Final snapshot (default on); Also delete N snapshots (turns Final off); live plain-English summary using the GUI's wording; type the volume name |
| Approve location | Path with **Tab completion** of directories; Snapshot root pre-filled as `<mount point>/snapshots`, recomputed while untouched; note that the password is asked every time |

Behaviour:

- Errors show in the status line in red and in the log, like GUI toasts. Warnings likewise; notes go to the log only.
- Every mutating call is followed by a refresh; selection is kept by name.
- While a helper runs, show "Working…" and discard keys typed meanwhile (`curses.flushinp()`).
- Volumes with an `error` show `!` in the list and the error text in the right pane.
- Below 80×24: one centred "Terminal too small (need 80×24)" line until resized.
- Colour: selection reversed, errors red, warnings yellow, secondary text dim. Everything must still be readable with colour off.

## Shared code and changes to existing code

Factor the GUI's unprivileged logic into one module so the GUI and CLI can't drift apart.

**New `src/snapman_client.py`**, installed as `/usr/lib/btrfs-snapman/snapman_client.py`. Pure Python, no `gi`, no `btrfsutil`, no `curses`. It holds what is currently in `src/btrfs-snapman` or must match it:

- `NAME_RE`, `sanitise_label()`, `preview_name()`, `fmt_time()`, `fmt_age()`, `mount_of()`
- `suggest_snapshot_root(path)`: the `<mount point>/snapshots` rule
- `remove_summary(volume, delete_data, final, delete_snapshots)` and `new_volume_preview(…)`: the plain-English lines both front ends show
- `helper_argv(mode, args, via)` where `via` is `"pkexec"`, `"sudo"` or `None` (already root), and `parse_helper_output(returncode, stdout, stderr)` returning the dict plus a classification: `ok`, `failed`, `auth_needed`, `auth_cancelled`, `bad_output`

**`src/btrfs-snapman` (GUI):** import these from `snapman_client` instead of defining them. Its visible behaviour must not change.

**`src/btrfs-snapman-cli` (new):** entry point, `#!/usr/bin/python3`, adds `/usr/lib/btrfs-snapman` to `sys.path` like the helpers do. Split into readable sections (CLI subcommands, sudo handling, TUI screens, form component). Comment style as in the rest of the repo: one short comment per block where it isn't obvious.

**`src/snapman_core.py`:** only the two small changes in the privilege section (`SUDO_UID` in `_log()`, error wording). No new verbs expected.

**`snapman-query`, `snapman-admin`, `snapman-manage`:** update the header comments to mention sudo as well as polkit. No logic change.

## Packaging: three binary packages from one source

Split the source package so a Pi installs the helpers and CLI without pulling in GTK, polkit or pkexec. All are `Architecture: all`.

| Package | Contains | Depends |
| --- | --- | --- |
| `btrfs-snapman-common` | `snapman_core.py`, `snapman_client.py`, the three helpers, `libvirt-fsfreeze`, `/etc/btrfs-snapman/config.toml` (conffile), empty `volumes.d/` and `parents.d/`, README, config example | `python3`, `python3-btrfsutil` |
| `btrfs-snapman` (GUI) | `/usr/bin/btrfs-snapman`, desktop file, polkit policy, `btrfs-snapman.1` | `btrfs-snapman-common (= ${binary:Version})`, `python3-gi`, `gir1.2-gtk-4.0`, `gir1.2-adw-1`, `pkexec` |
| `btrfs-snapman-cli` | `/usr/bin/btrfs-snapman-cli`, `btrfs-snapman-cli.1`, `sudoers.example` | `btrfs-snapman-common (= ${binary:Version})`, `python3`, `sudo` |

Upgrade path from 0.6.0 (where `btrfs-snapman` owns everything, including the conffile):

- `btrfs-snapman-common`: `Breaks: btrfs-snapman (<< 0.7.0)` and `Replaces: btrfs-snapman (<< 0.7.0)`, so files and the conffile move to it.
- An **edited `config.toml` must survive** the move with no prompt and no `.dpkg-dist` noise. Verify this with a real upgrade test (Testing section); don't assume it.
- `volumes.d/*.toml` and `parents.d/*.toml` must be untouched.

Build changes:

- Move `debian/rules` from hand-written `install` lines to `debian/<package>.install`, `.manpages`, `.docs` and `.examples` files per package (standard debhelper). Keep compat 13.
- `lintian --fail-on error,warning` must pass for all three packages.
- Release workflow: attach `btrfs-snapman*_all.deb` (the current glob only matches the GUI package).
- `install.sh`: default installs common + GUI + CLI; `install.sh --cli` installs common + CLI only (for headless machines). Keep the `/usr/local` legacy clean-up and `--uninstall`.
- `debian/changelog`: 0.7.0 entry.

Installing on a Pi from a release:

```
sudo apt install ./btrfs-snapman-common_0.7.0_all.deb ./btrfs-snapman-cli_0.7.0_all.deb
```

## Testing

Everything below is automated except the final Pi smoke test. Tests that create users or install packages run only in a disposable container or VM, never on a real machine.

| Test | How | Must show |
| --- | --- | --- |
| Existing core tests | `sudo PY=/usr/bin/python3 tests/test_core.sh src` | All 140 checks still pass, plus new ones for the caller UID (`PKEXEC_UID` > `SUDO_UID` > `getuid()`) |
| Client module | New `tests/test_client.py` (unittest, no root) | `sanitise_label`, `preview_name` (empty comment tidies separators), all four remove summaries, output classification (sudo needs password, pkexec 126/127, bad JSON), `suggest_snapshot_root` against a fake mountinfo |
| CLI subcommands | New `tests/test_cli.sh`, root, loopback btrfs like `test_core.sh`, `--libexec` pointing at the helpers | Every subcommand; exit codes 0/1/2/4; `--json` passes the helper object through; results on stdout and commands/warnings on stderr; `delete` / `remove-volume` refuse without a TTY unless `--yes` |
| sudo flow | Disposable container: a test user with a password and the sudoers example; drive prompts with `tmux` or `script` | First `sudo -v`; expired timestamp (`sudo -k` mid-session) re-prompts and retries once; manage verbs prompt every time; wrong password exits 3; no password ever appears in argv or the process list |
| TUI | `tmux new-session -d -x 80 -y 24`, `send-keys`, `capture-pane -p`, as root with `--libexec` | Start-up list; snapshot with a comment (preview visible); delete with a wrong then the right confirmation; read-only toggle; new volume then remove with final snapshot; approve a location using Tab completion; resize to 70×20 and back; `LANG=C`; `NO_COLOR`. Check screen text **and** on-disk state |
| Packaging | Build all three; `lintian --fail-on error,warning` | Clean |
| Upgrade 0.6.0 → 0.7.0 | Clean Ubuntu 24.04 container: install the 0.6.0 GUI .deb (built from its commit), edit `config.toml`, add a `volumes.d` file, then `apt install` the three 0.7.0 debs with `DEBIAN_FRONTEND=noninteractive` and no `--force-conf*` options | `config.toml` byte-identical, no `.dpkg-dist` / `.dpkg-old`, `volumes.d` intact, `dpkg -S /etc/btrfs-snapman/config.toml` shows `btrfs-snapman-common` |
| Headless install | `apt-get install --simulate ./btrfs-snapman-common_*.deb ./btrfs-snapman-cli_*.deb` on a server image | No `gir1.2-*`, GTK, `pkexec` or polkit packages pulled in |
| Pi smoke test (manual) | On a Pi 5 over SSH, inside `tmux` | `list`, TUI start-up, snapshot, delete, read-only toggle; sudo prompts behave; nothing GUI-related installed |

## Acceptance criteria

- [ ] `btrfs-snapman-cli` with no arguments opens the TUI over SSH on a Pi 5 and does everything in the Interactive TUI section
- [ ] Every subcommand in the CLI table works, with the exit codes and stdout/stderr split as specified
- [ ] All privileged work goes through the existing helpers via `sudo` (or directly as root); the CLI never imports `snapman_core` or `btrfsutil`
- [ ] GUI behaviour unchanged; GUI and CLI share `snapman_client.py`
- [ ] Three packages build, lintian-clean; CLI-only install pulls in no GTK or polkit
- [ ] 0.6.0 → 0.7.0 upgrade keeps an edited `config.toml` and `volumes.d` untouched, with no prompt
- [ ] All tests in the Testing section pass; README, both man pages and the changelog updated

## Out of scope

- Retention / pruning, `send`/`receive`, restore-from-snapshot, per-snapshot sizes (same as the GUI's "not done yet" list)
- Mouse support, themes, a config editor
- Remote management of another host from one CLI (run it on each Pi over SSH instead)

## Decisions already made

| Decision | Chosen | Rejected, and why |
| --- | --- | --- |
| Name | `btrfs-snapman-cli` | — (requested) |
| TUI library | stdlib `curses` | Textual: nicer, but not packaged for Ubuntu 24.04 as far as I know (\~60%), and a pip install alongside a root tool is unwanted |
| Privilege path | `sudo` | `pkexec`: no polkit agent or active local session over SSH |
| Packaging | split common / GUI / CLI | One package with GTK as `Recommends`: still drags GUI files onto headless Pis and muddles dependencies |
| Password-free listing | off by default, sudoers example provided | On by default: widens what a compromised user account can see |

## How to work

1. Read the repo first, then propose a short plan before writing code.
2. Order: `snapman_client.py` + GUI refactor (GUI unchanged) → core tweaks → CLI subcommands → TUI → packaging split → tests and docs.
3. Commit in logical steps. Don't push or tag without asking me.
4. Anything that creates users, edits sudoers or installs packages runs in a disposable container only.
