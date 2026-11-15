#!/bin/bash
# Integration tests for the root helper, run against a real btrfs filesystem in a
# 1 GB loopback file. Nothing outside the temporary directory is touched.
# Usage: sudo PY=/usr/bin/python3 tests/test_core.sh [path/to/src]
set -u
SRC=$(realpath "${1:-$(dirname "$0")/../src}")
PY=${PY:-/usr/bin/python3}
WORK=$(mktemp -d)
IMG=$WORK/fs.img
MNT=$WORK/mnt
CFGDIR=$WORK/etc
pass=0; fail=0

# Always unmount and clean up, even if a test blows up.
cleanup() { kill $HOLDER 2>/dev/null; umount "$MNT/mounted" 2>/dev/null; umount "$MNT" 2>/dev/null; rm -rf "$WORK"; }
HOLDER=""
trap cleanup EXIT

# ---------------------------------------------------------------- build a test filesystem
truncate -s 1G "$IMG" && mkfs.btrfs -q "$IMG" && mkdir -p "$MNT" && mount -o loop "$IMG" "$MNT" || exit 2
btrfs -q subvolume create "$MNT/@vms" >/dev/null
chattr +C "$MNT/@vms"
echo disk > "$MNT/@vms/win11.qcow2"
btrfs -q subvolume create "$MNT/@data" >/dev/null
mkdir -p "$MNT/snapshots/vms" "$MNT/snapshots/data" "$MNT/vmdisks" "$MNT/vmsnaps"
# a snapshot made by hand or by a script
btrfs -q subvolume snapshot -r "$MNT/@vms" "$MNT/snapshots/vms/manual-old" >/dev/null
# a symlink planted in a snapshot folder, which must never be followed
ln -s "$MNT/@data" "$MNT/snapshots/vms/evil"
HOOKLOG=$WORK/hooks.log

# ---------------------------------------------------------------- config + drop-ins
mkdir -p "$CFGDIR/volumes.d" && chmod 755 "$CFGDIR" "$CFGDIR/volumes.d"
cat > "$CFGDIR/config.toml" <<EOF
[defaults]
name_format = "{timestamp}_{label}"
read_only = true

[[volume]]
name = "vms"
path = "$MNT/@vms"
snapshot_dir = "$MNT/snapshots/vms"
pre_snapshot  = [["/bin/sh", "-c", "echo freeze >> $HOOKLOG"]]
post_snapshot = [["/bin/sh", "-c", "echo thaw >> $HOOKLOG"]]

[[volume]]
name = "data"
path = "$MNT/@data"
snapshot_dir = "$MNT/snapshots/data"
name_format = "{volume}-{timestamp}-{label}"
read_only = false

[[volume]]
name = "alice"
path = "$MNT/@data"
snapshot_dir = "$MNT/snapshots/data"
name_format = "{volume}_{timestamp}_{label}"
timestamp_format = "%Y-%m-%d_%H-%M-%S"

[[volume]]
name = "badhook"
path = "$MNT/@data"
snapshot_dir = "$MNT/snapshots/data"
pre_snapshot  = [["/bin/false"]]
post_snapshot = [["/bin/sh", "-c", "echo thaw-after-fail >> $HOOKLOG"]]

[[create.parent]]
path = "$MNT/vmdisks"
snapshot_root = "$MNT/vmsnaps"
EOF
chmod 644 "$CFGDIR/config.toml"
# a drop-in volume that is NOT under a create parent (like /home)
cat > "$CFGDIR/volumes.d/dataalias.toml" <<EOF
[volume]
name = "dataalias"
path = "$MNT/@data"
snapshot_dir = "$MNT/snapshots/data"
EOF
# a broken drop-in, which must be reported but not break everything else
printf '[volume]\nname = "broken"\npath = "relative"\nsnapshot_dir = "/x"\n' > "$CFGDIR/volumes.d/broken.toml"
# a drop-in that clashes with a config.toml volume name
printf '[volume]\nname = "vms"\npath = "/x"\nsnapshot_dir = "/x"\n' > "$CFGDIR/volumes.d/vms.toml"
chmod 644 "$CFGDIR"/volumes.d/*.toml

# ---------------------------------------------------------------- test helpers
# run MODE ARGS... : call the helper exactly as an entry script would, with the test config
run() {
  local mode=$1; shift
  "$PY" -I -c "import sys; sys.path.insert(0, '$SRC'); import snapman_core as c; sys.exit(c.main('$mode', sys.argv[1:], '$CFGDIR/config.toml'))" "$@"
}
is_ok() { "$PY" -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d['ok'] else 1)"; }
# check DESCRIPTION ok|fail MODE ARGS... : run and compare against the expected outcome
check() {
  local desc=$1 expect=$2; shift 2
  local out; out=$(run "$@")
  if echo "$out" | is_ok; then got=ok; else got=fail; fi
  if [ "$got" = "$expect" ]; then pass=$((pass+1)); echo "PASS  $desc"
  else fail=$((fail+1)); echo "FAIL  $desc"; echo "      $out"; fi
  LAST=$out
}
# field EXPR : evaluate a Python expression against the last JSON result (as d)
field() { echo "$LAST" | "$PY" -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }
# assert DESCRIPTION COMMAND... : pass if the shell command succeeds
assert() { local desc=$1; shift; if "$@"; then pass=$((pass+1)); echo "PASS  $desc"; else fail=$((fail+1)); echo "FAIL  $desc"; echo "      ${LAST:-}"; fi; }
vol() { echo "$LAST" | "$PY" -c "import json,sys; d=json.load(sys.stdin); v={x['name']:x for x in d['result']['volumes']}; print(eval(sys.argv[1]))" "$1"; }

# ---------------------------------------------------------------- listing
check "list works"                              ok   query list
assert "NOCOW detected on @vms"                 [ "$(vol "v['vms']['source']['nocow']")" = "True" ]
assert "manual snapshot listed, symlink ignored" [ "$(vol "[s['name'] for s in v['vms']['snapshots']]")" = "['manual-old']" ]
assert "manual snapshot linked via parent_uuid" [ "$(vol "v['vms']['snapshots'][0]['of_source']")" = "True" ]
assert "drop-in volume loaded"                  [ "$(vol "v['dataalias']['origin']")" = "dropin" ]
assert "broken + clashing drop-ins reported"    [ "$(field "len(d['result']['config_errors'])")" = "2" ]
assert "clashing drop-in did not replace vms"   [ "$(vol "v['vms']['origin']")" = "config" ]
assert "config.toml volume not removable"       [ "$(vol "v['vms']['removable']")" = "False" ]
assert "drop-in outside parent: data not deletable" [ "$(vol "v['dataalias']['data_deletable']")" = "False" ]
check "query helper refuses mutating verb"      fail query delete vms manual-old
check "admin helper refuses manage verb"        fail admin new-volume x "$MNT/vmdisks"
check "manage helper refuses admin verb"        fail manage snapshot vms

# ---------------------------------------------------------------- snapshots
check "snapshot vms (ro default, hooks)"        ok   admin snapshot vms pre-upgrade
SNAP=$(field "d['result']['name']")
assert "ro snapshot + freeze/thaw order"        [ "$(field "d['result']['read_only']")" = "True" -a "$(cat $HOOKLOG)" = "$(printf 'freeze\nthaw')" ]
assert "NOCOW note emitted"                     grep -q NOCOW <<<"$LAST"
assert "snapshot content present"               [ -f "$MNT/snapshots/vms/$SNAP/win11.qcow2" ]

check "snapshot data (rw default, custom fmt)"  ok   admin snapshot data
DSNAP=$(field "d['result']['name']")
assert "name_format + rw default ($DSNAP)"      [ -n "$(grep -E '^data-[0-9]{8}-[0-9]{6}$' <<<"$DSNAP")" -a "$(field "d['result']['read_only']")" = "False" ]

check "volume-first name, no comment"           ok   admin snapshot alice
assert "  $(field "d['result']['name']")"       grep -qE '^alice_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$' <<<"$(field "d['result']['name']")"
sleep 1
check "volume-first name, with comment"         ok   admin snapshot alice Clean_Build
assert "  $(field "d['result']['name']")"       grep -qE '^alice_.*_Clean_Build$' <<<"$(field "d['result']['name']")"

: > "$HOOKLOG"
check "failing pre-hook aborts snapshot"        fail admin snapshot badhook x
assert "post hook still ran after pre failure"  [ "$(cat $HOOKLOG)" = "thaw-after-fail" ]

# ---------------------------------------------------------------- input validation and confinement
check "bad comment rejected"                    fail admin snapshot vms 'a/b'
check "unknown volume rejected"                 fail admin snapshot nope
check "path traversal rejected"                 fail admin delete vms ../../@data
check "symlink entry rejected"                  fail admin delete vms evil
check "source cannot be targeted"               fail admin delete vms @vms
assert "@data still exists"                     [ -d "$MNT/@data" ]

# ---------------------------------------------------------------- read-only flag
check "set rw on own snapshot"                  ok   admin set-ro vms "$SNAP" false
check "set ro again"                            ok   admin set-ro vms "$SNAP" true
btrfs send -q "$MNT/snapshots/vms/manual-old" | btrfs receive -q "$MNT/snapshots/data/" || echo "receive failed"
check "rw on received refused without force"    fail admin set-ro data manual-old false
assert "received guard message"                 grep -q RECEIVED_SNAPSHOT <<<"$LAST"
check "rw on received with --force"             ok   admin set-ro data manual-old false --force

# ---------------------------------------------------------------- snapshot deletion guards
SID=$(btrfs subvolume show "$MNT/snapshots/vms/manual-old" | awk '/Subvolume ID/{print $3}')
mkdir -p "$MNT/mounted" && mount -o loop,subvolid=$SID,ro "$IMG" "$MNT/mounted"
check "mounted snapshot delete refused"         fail admin delete vms manual-old
assert "  refused because mounted"              grep -q mounted <<<"$LAST"
umount "$MNT/mounted"
btrfs -q subvolume create "$MNT/snapshots/data/$DSNAP/nested" >/dev/null
check "nested subvolume delete refused"         fail admin delete data "$DSNAP"
assert "  refused because nested"               grep -q nested <<<"$LAST"
btrfs -q subvolume delete "$MNT/snapshots/data/$DSNAP/nested" >/dev/null
check "delete snapshot"                         ok   admin delete vms "$SNAP"
assert "snapshot gone"                          [ ! -e "$MNT/snapshots/vms/$SNAP" ]

# ---------------------------------------------------------------- new-volume
check "new-volume with NOCOW"                   ok   manage new-volume WinTest "$MNT/vmdisks" wintest --nocow
assert "subvolume created"                      sh -c "btrfs subvolume show '$MNT/vmdisks/wintest' >/dev/null 2>&1"
assert "NOCOW set"                              grep -q C <<<"$(lsattr -d "$MNT/vmdisks/wintest" | cut -d' ' -f1)"
assert "snapshot dir created"                   [ -d "$MNT/vmsnaps/wintest" ]
assert "drop-in written, root 0644"             [ "$(stat -c '%U %a' "$CFGDIR/volumes.d/WinTest.toml")" = "root 644" ]
check "new volume appears in list"              ok   query list
assert "  listed as removable + deletable"      [ "$(vol "(v['WinTest']['removable'], v['WinTest']['data_deletable'])")" = "(True, True)" ]
check "snapshot the new volume"                 ok   admin snapshot WinTest first

check "duplicate volume name refused"           fail manage new-volume WinTest "$MNT/vmdisks" other
check "existing folder refused w/o --existing"  fail manage new-volume Other "$MNT/vmdisks" wintest
check "parent not in config refused"            fail manage new-volume Other "$MNT" other
check "bad folder name refused"                 fail manage new-volume Other "$MNT/vmdisks" ../escape
# rollback: a non-empty snapshot folder makes step 2 fail -> the new subvolume must be removed
mkdir -p "$MNT/vmsnaps/rollme" && touch "$MNT/vmsnaps/rollme/junk"
check "non-empty snapshot dir refused"          fail manage new-volume Roll "$MNT/vmdisks" rollme
assert "  nothing left behind"                  [ ! -e "$MNT/vmdisks/rollme" -a ! -e "$CFGDIR/volumes.d/Roll.toml" ]
# rollback: make the final step (writing the drop-in) fail by putting a directory where
# the file should go -> the subvolume and snapshot folder created earlier must be undone
mkdir "$CFGDIR/volumes.d/Roll2.toml"
check "failure while writing drop-in"           fail manage new-volume Roll2 "$MNT/vmdisks" roll2 --nocow
assert "  subvolume + snapshot dir rolled back" [ ! -e "$MNT/vmdisks/roll2" -a ! -e "$MNT/vmsnaps/roll2" ]
rmdir "$CFGDIR/volumes.d/Roll2.toml"
# adopting an existing subvolume
btrfs -q subvolume create "$MNT/vmdisks/legacy" >/dev/null
check "adopt existing subvolume"                ok   manage new-volume Legacy "$MNT/vmdisks" legacy --existing
check "NOCOW with --existing refused"           fail manage new-volume Legacy2 "$MNT/vmdisks" legacy --existing --nocow

# ---------------------------------------------------------------- remove-volume
check "config.toml volume can't be removed"     fail manage remove-volume vms
check "unregister only (keep data)"             ok   manage remove-volume Legacy
assert "  drop-in gone, data kept"              [ ! -e "$CFGDIR/volumes.d/Legacy.toml" -a -d "$MNT/vmdisks/legacy" ]
check "delete data outside parent refused"      fail manage remove-volume dataalias --delete-data
assert "  @data untouched"                      [ -d "$MNT/@data" -a -e "$CFGDIR/volumes.d/dataalias.toml" ]

# a process holding a file open inside the volume blocks deletion (stands in for a running VM)
echo img > "$MNT/vmdisks/wintest/disk.img"
sleep 60 < "$MNT/vmdisks/wintest/disk.img" & HOLDER=$!
sleep 0.3
check "delete refused while file is open"       fail manage remove-volume WinTest --delete-data
assert "  names the process"                    grep -q "sleep (pid $HOLDER)" <<<"$LAST"
kill $HOLDER; wait $HOLDER 2>/dev/null; HOLDER=""

check "delete with final snapshot (default)"    ok   manage remove-volume WinTest --delete-data
FINAL=$(field "d['result']['final_snapshot']")
assert "  source gone, final snapshot kept"     [ ! -e "$MNT/vmdisks/wintest" -a -f "$FINAL/disk.img" ]
assert "  drop-in gone"                         [ ! -e "$CFGDIR/volumes.d/WinTest.toml" ]

# full delete: data + every snapshot + snapshot folder
check "new-volume for full delete"              ok   manage new-volume Gone "$MNT/vmdisks" gone
check "  snapshot it twice"                     ok   admin snapshot Gone a
sleep 1; run admin snapshot Gone b >/dev/null
check "delete data + snapshots"                 ok   manage remove-volume Gone --delete-data --delete-snapshots
assert "  everything gone"                      [ ! -e "$MNT/vmdisks/gone" -a ! -e "$MNT/vmsnaps/gone" -a ! -e "$CFGDIR/volumes.d/Gone.toml" ]
assert "  reported 2 snapshots deleted"         [ "$(field "d['result']['deleted_snapshots']")" = "2" ]

# ---------------------------------------------------------------- config hardening
chmod 666 "$CFGDIR/config.toml"
check "world-writable config refused"           fail query list
chmod 644 "$CFGDIR/config.toml"
chmod 666 "$CFGDIR/volumes.d/dataalias.toml"
check "world-writable drop-in skipped"          ok   query list
assert "  and reported"                         grep -q "dataalias.toml" <<<"$(field "d['result']['config_errors']")"

echo; echo "passed=$pass failed=$fail"
[ $fail -eq 0 ]
