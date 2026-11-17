#!/bin/bash
# Tests for btrfs-snapman-cli's full-screen interface, driven through tmux (send-keys,
# capture-pane) at 80x24, as root with --libexec, on the same loopback fixture as
# test_cli.sh. Each step checks the screen text and, for changes, the state on disk.
# Usage: sudo PY=/usr/bin/python3 tests/test_tui.sh [path/to/src]     (needs tmux)
set -u
SRC=$(realpath "${1:-$(dirname "$0")/../src}")
PY=${PY:-/usr/bin/python3}
pass=0; fail=0
. "$(dirname "$0")/cli_fixture.sh"
command -v tmux >/dev/null || { echo "tmux is not installed"; exit 2; }

T="tmux -L snapman-test-$$"
trap '$T kill-server 2>/dev/null; cleanup' EXIT

# ---------------------------------------------------------------- test helpers
# start [VAR=value...] : (re)start the TUI in a fresh 80x24 tmux session
start() {
  $T kill-server 2>/dev/null; sleep 0.3
  $T new-session -d -x 80 -y 24 -s tui \
    "env $* $PY -B $SRC/btrfs-snapman-cli --libexec $LIBEXEC; echo EXIT=\$?; sleep 600"
  wait_for "q quit" || { echo "TUI did not start:"; screen; }
}
keys() { $T send-keys -t tui "$@"; sleep 0.3; }
text() { $T send-keys -t tui -l "$1"; sleep 0.3; }
screen() { $T capture-pane -p -t tui; }
wait_for() { local i; for i in $(seq 40); do screen | grep -qE -- "$1" && return 0; sleep 0.1; done; return 1; }
assert() {
  local desc=$1; shift
  if "$@"; then pass=$((pass+1)); echo "PASS  $desc"
  else fail=$((fail+1)); echo "FAIL  $desc"; screen | sed 's/^/      /'; fi
}
seen() { assert "$1" wait_for "$2"; }
ro() { btrfs property get -ts "$1" ro | grep -q true; }
SNAPS=$MNT/snapshots/docker

# ---------------------------------------------------------------- start-up
start
seen "start-up: header, running as root"            "btrfs-snapman · .* · running as root"
seen "  volumes with snapshot counts"               "│> Docker +1│"
seen "  second volume"                              "│  data +1│"
seen "  volume with an error marked !"              "│  gone +!│"
seen "  config banner"                              "1 config file\(s\) could not be loaded — press l for details"
seen "  details of the selected volume"             "Snapshots \(1\) +newest first"
seen "  key hints"                                  "s snapshot  d delete  r read-only"

keys End
seen "  its error in the right pane"                "Volume unavailable"
keys s
seen "  s on it explains instead of opening a dialog" "error: volume unavailable"
keys Home

# ---------------------------------------------------------------- snapshot
keys s
seen "snapshot dialog"                              "Snapshot “Docker”"
text "before pihole v6!"
seen "  live name preview"                          "Name: Docker_[0-9]{4}-[0-9-]+_[0-9-]+_before_pihole_v6 "
keys Enter
seen "  created, status line says so"               "Created Docker_[0-9_-]+_before_pihole_v6"
NEW=$(ls "$SNAPS" | grep before_pihole_v6)
assert "  on disk, read-only"                       eval '[ -n "$NEW" ] && ro "$SNAPS/$NEW"'
seen "  list refreshed"                             "│> Docker +2│"

# ---------------------------------------------------------------- delete
keys Tab Home d
seen "delete dialog for the newest snapshot"        "$NEW"
text "nope"; keys Enter
seen "  wrong word: dialog stays open"              "Delete snapshot\?"
assert "  still on disk"                            [ -d "$SNAPS/$NEW" ]
keys C-u; text " Delete "; keys Enter
seen "  ' Delete ' accepted"                        "Deleted $NEW"
assert "  gone from disk"                           [ ! -e "$SNAPS/$NEW" ]
seen "  list refreshed"                             "│> Docker +1│"

# ---------------------------------------------------------------- read-only toggle
keys r
seen "r: snapshot now writable"                     "docker_by-hand +just now  RW"
assert "  writable on disk"                         eval '! ro "$SNAPS/docker_by-hand"'
keys r
seen "r again: read-only"                           "docker_by-hand +just now  RO"
assert "  read-only on disk"                        ro "$SNAPS/docker_by-hand"
keys Enter
seen "Enter: details with every field"              "Received UUID +0{8}-"
seen "  full path"                                  "Path +$SNAPS/docker_by-hand"
keys Escape
keys Left Down Tab r
seen "received snapshot: y/N warning"               "Make received snapshot writable\?"
keys n
assert "  n keeps it read-only"                     ro "$MNT/snapshots/data/docker_by-hand"
keys r
wait_for "Make received snapshot writable\?"        # keys typed while "Working…" are dropped
keys y
seen "  y forces it, with the stale-uuid warning"   "warning: received_uuid is now stale"
assert "  writable on disk"                         eval '! ro "$MNT/snapshots/data/docker_by-hand"'

# ---------------------------------------------------------------- new volume, remove volume
keys n
seen "new volume dialog"                            "New volume"
keys Down; text "PiVol"
seen "  live 'Will create' lines"                   "Subvolume: $MNT/vmdisks/PiVol"
seen "  snapshot folder"                            "Snapshots: $MNT/vmsnaps/PiVol/"
keys Down Down Space
seen "  Use existing turns the button into Register" "Enter Register"
seen "  and disables NOCOW"                         "NOCOW +\[ \]  not with Use existing"
keys Space Down Space Enter
seen "  created"                                    "Volume PiVol ready"
assert "  NOCOW subvolume and drop-in on disk"      eval 'lsattr -d "$MNT/vmdisks/PiVol" | grep -q C && [ -f "$CFGDIR/volumes.d/PiVol.toml" ]'
seen "  new volume selected"                        "PiVol · $MNT/vmdisks/PiVol"
keys x
seen "remove dialog"                                "Remove volume “PiVol”\?"
seen "  unregister-only summary"                    "Only the registration is removed"
keys Space
seen "  delete data: final snapshot summary"        "A final read-only snapshot is taken"
keys Down Down Down; text "PiVo"; keys Enter
seen "  wrong name: dialog stays open"              "Remove volume “PiVol”\?"
text "l"; keys Enter
seen "  removed, final snapshot kept"               "Removed PiVol; final snapshot kept at "
keys l
seen "  full message in the log"                    "Removed PiVol; final snapshot kept at"
keys l
assert "  data and drop-in gone, final snapshot kept" eval '[ ! -e "$MNT/vmdisks/PiVol" -a ! -e "$CFGDIR/volumes.d/PiVol.toml" ] && ls "$MNT/vmsnaps/PiVol" | grep -q final'

# ---------------------------------------------------------------- approve a location
keys a
seen "approve dialog"                               "Approve new location"
keys C-u; text "$MNT/appr"; keys Tab
seen "  Tab completes the folder"                   "Folder +\[$MNT/approve-me/ "
seen "  snapshot root follows: <mount>/snapshots"   "Snapshot root +\[$MNT/snapshots "
seen "  filesystem shown"                           "Filesystem mounted at $MNT"
keys Enter
seen "  approved"                                   "Approved $MNT/approve-me"
assert "  parents.d file written"                   eval 'grep -q "path = \"$MNT/approve-me\"" "$CFGDIR"/parents.d/*.toml'
keys L
seen "locations screen lists it"                    "$MNT/approve-me"
keys Down d; text "delete"; keys Enter
seen "  removed from the locations screen"          "Removed location $MNT/approve-me"
assert "  parents.d file gone"                      eval '! ls "$CFGDIR"/parents.d/*.toml >/dev/null 2>&1'
keys Escape

# ---------------------------------------------------------------- help, log, resize, quit
keys "?"
seen "help screen"                                  "Toggle read-only on the selected snapshot"
keys Escape l
seen "log screen with the equivalent commands"      "\\$ btrfs subvolume delete"
keys l
$T resize-window -t tui -x 70 -y 20; sleep 0.5
seen "70x20: too small"                             "Terminal too small \(need 80×24\)"
$T resize-window -t tui -x 80 -y 24; sleep 0.5
seen "  back to 80x24"                              "q quit"
keys Escape
seen "Esc in the main view does nothing"            "q quit"
keys q
seen "q quits with exit 0"                          "EXIT=0"

# ---------------------------------------------------------------- terminals and locales
start LANG=C LC_ALL= TERM=screen
seen "LANG=C, TERM=screen: ASCII borders"           "^\+ Volumes -+\+\+ Docker - "
assert "  nothing but ASCII on screen"              eval '! screen | LC_ALL=C grep -q "[^ -~]"'
keys q
start TERM=linux
seen "TERM=linux starts"                            "q quit"
keys q
start NO_COLOR=1
assert "NO_COLOR: no colour escapes"                eval '! $T capture-pane -e -p -t tui | grep -qE $'"'"'\033\[(3|4)[0-7]m'"'"
keys q
start
assert "colour by default (banner in yellow)"       eval '$T capture-pane -e -p -t tui | grep -q $'"'"'\033\[33m'"'"
keys C-c
seen "Ctrl-C exits with 130"                        "EXIT=130"

echo; echo "passed=$pass failed=$fail"
[ $fail -eq 0 ]
