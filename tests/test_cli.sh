#!/bin/bash
# Integration tests for btrfs-snapman-cli's subcommands, run as root against a real btrfs
# filesystem in a loopback file. --libexec points the CLI at wrappers that run the helpers
# from the source tree with a test config. Nothing outside the temporary directory is touched.
# Usage: sudo PY=/usr/bin/python3 tests/test_cli.sh [path/to/src]
set -u
SRC=$(realpath "${1:-$(dirname "$0")/../src}")
PY=${PY:-/usr/bin/python3}
WORK=$(mktemp -d)
MNT=$WORK/mnt
CFGDIR=$WORK/etc
LIBEXEC=$WORK/libexec
pass=0; fail=0

cleanup() {
  umount "$MNT" "$WORK/tmpfs" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------- test filesystem
truncate -s 1G "$WORK/fs.img" && mkfs.btrfs -q "$WORK/fs.img" && mkdir -p "$MNT" \
  && mount -o loop "$WORK/fs.img" "$MNT" || exit 2
mkdir -p "$WORK/tmpfs" && mount -t tmpfs tmpfs "$WORK/tmpfs" || exit 2
btrfs -q subvolume create "$MNT/@docker" >/dev/null
btrfs -q subvolume create "$MNT/@data" >/dev/null
mkdir -p "$MNT/snapshots/docker" "$MNT/snapshots/data" "$MNT/vmdisks" "$MNT/vmsnaps" "$MNT/approve-me"
btrfs -q subvolume snapshot -r "$MNT/@docker" "$MNT/snapshots/docker/docker_by-hand" >/dev/null
# a snapshot created by btrfs receive, for the read-only guard
btrfs send -q "$MNT/snapshots/docker/docker_by-hand" | btrfs receive -q "$MNT/snapshots/data/"

mkdir -p "$CFGDIR/volumes.d" "$CFGDIR/parents.d"
cat > "$CFGDIR/config.toml" <<EOF
[defaults]
name_format = "{volume}_{timestamp}_{label}"
timestamp_format = "%Y-%m-%d_%H-%M-%S"
read_only = true

[[volume]]
name = "Docker"
path = "$MNT/@docker"
snapshot_dir = "$MNT/snapshots/docker"

[[volume]]
name = "data"
path = "$MNT/@data"
snapshot_dir = "$MNT/snapshots/data"
read_only = false

[[create.parent]]
path = "$MNT/vmdisks"
snapshot_root = "$MNT/vmsnaps"
EOF
printf '[volume]\nname = "broken"\npath = "relative"\nsnapshot_dir = "/x"\n' > "$CFGDIR/volumes.d/broken.toml"
chmod 755 "$CFGDIR" "$CFGDIR"/*.d; chmod 644 "$CFGDIR/config.toml" "$CFGDIR"/volumes.d/*

# The helpers as installed, but importing snapman_core from the source tree with the test config
mkdir -p "$LIBEXEC"
for mode in query admin manage; do
  cat > "$LIBEXEC/snapman-$mode" <<EOF
#!/bin/sh
exec "$PY" -IB -c "import sys; sys.path.insert(0, '$SRC'); import snapman_core as c; sys.exit(c.main('$mode', sys.argv[1:], '$CFGDIR/config.toml'))" "\$@"
EOF
  chmod 755 "$LIBEXEC/snapman-$mode"
done

# ---------------------------------------------------------------- test helpers
# cli ARGS... : run without a terminal; sets RC, OUT (stdout) and ERR (stderr)
cli() {
  OUT=$("$PY" -B "$SRC/btrfs-snapman-cli" --libexec "$LIBEXEC" "$@" </dev/null 2>"$WORK/err")
  RC=$?; ERR=$(cat "$WORK/err")
}
# tty INPUT ARGS... : run on a pseudo-terminal (script), typing INPUT; output in OUT
tty() {
  local input=$1; shift
  local cmd; cmd=$(printf '%q ' "$PY" -B "$SRC/btrfs-snapman-cli" --libexec "$LIBEXEC" "$@")
  OUT=$(printf '%s\n' "$input" | script -qec "$cmd" /dev/null); RC=$?; ERR=""
}
assert() {
  local desc=$1; shift
  if "$@"; then pass=$((pass+1)); echo "PASS  $desc"
  else fail=$((fail+1)); echo "FAIL  $desc"; echo "      rc=${RC:-} out=${OUT:-}"; echo "      err=${ERR:-}"; fi
}
rc() { [ "$RC" -eq "$1" ]; }
has() { grep -qE -- "$1" <<<"$2"; }
ro() { btrfs property get -ts "$1" ro | grep -q true; }
helper() { "$LIBEXEC/snapman-$1" "${@:2}"; }

# ---------------------------------------------------------------- usage and isolation
cli;                       assert "no command without a terminal: usage, exit 2" eval 'rc 2 && has usage "$ERR"'
cli frobnicate;            assert "unknown command: exit 2"                     rc 2
cli snapshot Docker --ro --rw; assert "--ro and --rw together: exit 2"          rc 2
cli new-volume X "$MNT/vmdisks" --nocow --existing; assert "--nocow with --existing: exit 2" rc 2
cli remove-volume X --delete-snapshots; assert "--delete-snapshots needs --delete-data: exit 2" rc 2
cli --version;             assert "--version"                                   has "^btrfs-snapman-cli [0-9]" "$OUT"
assert "CLI never imports snapman_core or btrfsutil" \
  eval '! grep -qE "^\s*(import|from)\s+(snapman_core|btrfsutil)" "$SRC/btrfs-snapman-cli" "$SRC/snapman_client.py"'

# ---------------------------------------------------------------- listing
cli list
assert "list: exit 0"                                   rc 0
assert "  one line per volume, with snapshot count"     has "^Docker +$MNT/@docker +1$" "$OUT"
assert "  data volume listed"                           has "^data +$MNT/@data +1$" "$OUT"
assert "  no header when piped"                         eval '! has VOLUME "$OUT"'
assert "  broken drop-in reported on stderr"            has "warning: config: .*broken.toml" "$ERR"
assert "  no colour when piped"                         eval '! grep -q $'"'"'\033'"'"' <<<"$OUT$ERR"'
cli list data
assert "list VOLUME: received snapshot flagged"         has "^docker_by-hand +[0-9-]{10} [0-9:]{8} +(just now|[0-9]+[mhd] ago) +RO +received, not from this source$" "$OUT"
cli list nope
assert "list unknown volume: exit 1, error on stderr"   eval 'rc 1 && has "unknown volume" "$ERR" && [ -z "$OUT" ]'
cli --json list
assert "--json list: the helper's object unchanged"     eval 'rc 0 && [ "$OUT" = "$(helper query list)" ]'
assert "  nothing else on stderr"                       [ -z "$ERR" ]
cli list --json
assert "--json also works after the command"            eval 'rc 0 && [ "$OUT" = "$(helper query list)" ]'
cli locations
assert "locations: path, snapshot root, where defined"  has "^$MNT/vmdisks +$MNT/vmsnaps +$CFGDIR/config.toml$" "$OUT"

# ---------------------------------------------------------------- snapshot
cli snapshot Docker "before pihole v6!"
SNAP=$OUT
assert "snapshot: exit 0, prints only the name"         has "^Docker_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}_before_pihole_v6$" "$SNAP"
assert "  equivalent command on stderr"                 has "^\\$ btrfs subvolume snapshot -r " "$ERR"
assert "  exists, read-only (volume default)"           ro "$MNT/snapshots/docker/$SNAP"
sleep 1
cli snapshot Docker --rw
SNAP2=$OUT
assert "snapshot --rw, no comment: tidy name, writable" eval 'has "^Docker_[0-9_-]+[0-9]$" "$SNAP2" && ! ro "$MNT/snapshots/docker/$SNAP2"'
cli snapshot nope
assert "snapshot unknown volume: exit 1"                eval 'rc 1 && [ -z "$OUT" ] && has "^error: " "$ERR"'
cli --json snapshot data "json test"
assert "--json snapshot: one object, ok"                eval 'rc 0 && [ "$(wc -l <<<"$OUT")" = 1 ] && has "\"ok\": true" "$OUT" && [ -z "$ERR" ]'
cli --json snapshot nope
assert "--json failure: exit 1, ok false on stdout"     eval 'rc 1 && has "\"ok\": false" "$OUT"'

# ---------------------------------------------------------------- delete
cli delete Docker "$SNAP2"
assert "delete without a terminal refused: exit 4"      eval 'rc 4 && has -- "--yes" "$ERR" && [ -d "$MNT/snapshots/docker/$SNAP2" ]'
tty "nope" delete Docker "$SNAP2"
assert "delete on a terminal, wrong word: exit 4"       eval 'rc 4 && [ -d "$MNT/snapshots/docker/$SNAP2" ]'
assert "  prompt shown"                                 has "Type delete to confirm" "$OUT"
tty "  Delete " delete Docker "$SNAP2"
assert "delete on a terminal, ' Delete ': exit 0"       eval 'rc 0 && [ ! -e "$MNT/snapshots/docker/$SNAP2" ]'
cli delete Docker "$SNAP" --yes
assert "delete --yes: exit 0, gone"                     eval 'rc 0 && has "^Deleted $SNAP$" "$OUT" && [ ! -e "$MNT/snapshots/docker/$SNAP" ]'
assert "  command on stderr"                            has "^\\$ btrfs subvolume delete" "$ERR"
cli delete Docker nope --yes
assert "delete missing snapshot: exit 1"                rc 1

# ---------------------------------------------------------------- set-ro
cli set-ro Docker docker_by-hand off
assert "set-ro off: exit 0, writable"                   eval 'rc 0 && ! ro "$MNT/snapshots/docker/docker_by-hand"'
cli set-ro Docker docker_by-hand on
assert "set-ro on: read-only again"                     eval 'rc 0 && ro "$MNT/snapshots/docker/docker_by-hand"'
cli set-ro Docker docker_by-hand maybe
assert "set-ro bad state: exit 2"                       rc 2
cli set-ro data docker_by-hand off
assert "received, no terminal, no --force: exit 4"      eval 'rc 4 && has -- "--force" "$ERR" && ro "$MNT/snapshots/data/docker_by-hand"'
tty "n" set-ro data docker_by-hand off
assert "received, terminal, answer n: exit 4"           eval 'rc 4 && has "Make received snapshot writable" "$OUT" && ro "$MNT/snapshots/data/docker_by-hand"'
tty "y" set-ro data docker_by-hand off
assert "received, terminal, answer y: forced"           eval 'rc 0 && ! ro "$MNT/snapshots/data/docker_by-hand"'
assert "  stale received_uuid warning shown"            has "warning: received_uuid is now stale" "$OUT"
cli set-ro data docker_by-hand on
cli set-ro data docker_by-hand off --force
assert "received with --force: exit 0"                  eval 'rc 0 && ! ro "$MNT/snapshots/data/docker_by-hand"'

# ---------------------------------------------------------------- new-volume / remove-volume
cli new-volume WinTest "$MNT/vmdisks/" --folder wintest --nocow
assert "new-volume --folder --nocow: exit 0"            eval 'rc 0 && has "^Volume WinTest ready$" "$OUT"'
assert "  subvolume, NOCOW, snapshot folder, drop-in"   eval 'btrfs subvolume show "$MNT/vmdisks/wintest" >/dev/null && lsattr -d "$MNT/vmdisks/wintest" | grep -q C && [ -d "$MNT/vmsnaps/wintest" -a -f "$CFGDIR/volumes.d/WinTest.toml" ]'
cli new-volume Other "$MNT"
assert "new-volume under an unapproved parent: exit 1"  eval 'rc 1 && has "not an approved location" "$ERR"'
cli snapshot WinTest
cli remove-volume WinTest --delete-data
assert "remove-volume without a terminal: exit 4"       eval 'rc 4 && [ -f "$CFGDIR/volumes.d/WinTest.toml" ]'
assert "  prints the GUI's summary first"               has "^A final read-only snapshot is taken, then the subvolume is deleted. Snapshots stay in $MNT/vmsnaps/wintest but are no longer listed here.$" "$ERR"
tty "wintest" remove-volume WinTest
assert "remove-volume on a terminal, wrong name: 4"     eval 'rc 4 && [ -f "$CFGDIR/volumes.d/WinTest.toml" ]'
assert "  unregister-only summary"                      has "Only the registration is removed" "$OUT"
cli remove-volume data --yes
assert "remove-volume of a config.toml volume: exit 1"  eval 'rc 1 && has "remove it there" "$ERR"'
cli remove-volume WinTest --delete-data --yes
assert "remove-volume --delete-data --yes: exit 0"      eval 'rc 0 && has "^Removed WinTest; final snapshot kept at $MNT/vmsnaps/wintest/WinTest_.*final" "$OUT"'
assert "  data gone, drop-in gone, snapshots kept"      eval '[ ! -e "$MNT/vmdisks/wintest" -a ! -e "$CFGDIR/volumes.d/WinTest.toml" ] && [ "$(ls "$MNT/vmsnaps/wintest" | wc -l)" = 2 ]'
cli new-volume Gone "$MNT/vmdisks"
tty "Gone" remove-volume Gone --delete-data --delete-snapshots
assert "remove-volume on a terminal, right name: 0"     eval 'rc 0 && [ ! -e "$MNT/vmdisks/Gone" -a ! -e "$MNT/vmsnaps/Gone" ]'
assert "  delete-everything summary"                    has "The subvolume, all 0 snapshot\(s\) and the snapshot folder are deleted" "$OUT"
cli new-volume Legacy "$MNT/vmdisks" --folder legacy
cli remove-volume Legacy --yes
cli new-volume Legacy "$MNT/vmdisks" --folder legacy --existing
assert "new-volume --existing registers it again"       eval 'rc 0 && [ -f "$CFGDIR/volumes.d/Legacy.toml" ]'

# ---------------------------------------------------------------- locations
cli add-location "$MNT/approve-me/"
assert "add-location: exit 0"                           eval 'rc 0 && has "^Approved $MNT/approve-me$" "$OUT"'
assert "  default snapshot root <mount>/snapshots"      eval 'ls "$CFGDIR"/parents.d/*.toml >/dev/null && grep -q "snapshot_root = \"$MNT/snapshots\"" "$CFGDIR"/parents.d/*.toml'
cli locations
assert "  listed with its parents.d file"               has "^$MNT/approve-me +$MNT/snapshots +$CFGDIR/parents.d/" "$OUT"
cli add-location "$WORK/tmpfs"
assert "add-location on tmpfs refused: exit 1"          eval 'rc 1 && has "not on a btrfs filesystem \(tmpfs\)" "$ERR"'
cli remove-location "$MNT/approve-me"
assert "remove-location without a terminal: exit 4"     eval 'rc 4 && ls "$CFGDIR"/parents.d/*.toml >/dev/null'
cli remove-location "$MNT/approve-me" --yes
assert "remove-location --yes: exit 0, file gone"       eval 'rc 0 && ! ls "$CFGDIR"/parents.d/*.toml >/dev/null 2>&1'
cli remove-location "$MNT/vmdisks" --yes
assert "config.toml location can't be removed: exit 1"  rc 1
mkdir "$MNT/second"
cli add-location "$MNT/second" --snapshot-root "$MNT/second-snaps"
assert "add-location --snapshot-root"                   eval 'rc 0 && [ -d "$MNT/second-snaps" ]'
tty "delete" remove-location "$MNT/second"
assert "remove-location on a terminal: exit 0"          eval 'rc 0 && ! ls "$CFGDIR"/parents.d/*.toml >/dev/null 2>&1'

echo; echo "passed=$pass failed=$fail"
[ $fail -eq 0 ]
