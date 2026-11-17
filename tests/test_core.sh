#!/bin/bash
# Integration tests for the root helper, run against real btrfs filesystems in two
# 1 GB loopback files. Nothing outside the temporary directory is touched.
# Usage: sudo PY=/usr/bin/python3 tests/test_core.sh [path/to/src]
set -u
SRC=$(realpath "${1:-$(dirname "$0")/../src}")
PY=${PY:-/usr/bin/python3}
WORK=$(mktemp -d)
IMG=$WORK/fs.img
MNT=$WORK/mnt
IMG2=$WORK/fs2.img      # a second filesystem, for add-parent's same-filesystem check
MNT2=$WORK/mnt2
CFGDIR=$WORK/etc
pass=0; fail=0

# Always unmount and clean up, even if a test blows up.
cleanup() {
  kill $HOLDER 2>/dev/null
  umount "$MNT/mounted" "$WORK/datamnt" "$MNT" "$MNT2" "$WORK/tmpfs" 2>/dev/null
  rm -rf "$WORK"
}
HOLDER=""
trap cleanup EXIT

# ---------------------------------------------------------------- build a test filesystem
truncate -s 1G "$IMG" && mkfs.btrfs -q "$IMG" && mkdir -p "$MNT" && mount -o loop "$IMG" "$MNT" || exit 2
truncate -s 1G "$IMG2" && mkfs.btrfs -q "$IMG2" && mkdir -p "$MNT2" && mount -o loop "$IMG2" "$MNT2" || exit 2
mkdir -p "$WORK/tmpfs" && mount -t tmpfs tmpfs "$WORK/tmpfs" || exit 2
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

# ---------------------------------------------------------------- add-parent / remove-parent
PDIR=$CFGDIR/parents.d
mkdir -p "$MNT/approved" "$MNT/other" "$MNT2/othersnaps"
ln -s "$MNT/other" "$MNT/other-link"
ln -s "$MNT/snapshots" "$MNT/snaps-link"
ln -s "$MNT" "$WORK/mnt-link"

check "approve a new parent"                    ok   manage add-parent "$MNT/approved" "$MNT/approved-snaps"
PFILE=$(field "d['result']['origin_file']")
assert "  parents.d file written, root 0644"    [ "$(stat -c '%U %a' "$PFILE")" = "root 644" ]
assert "  named after the path"                 [ "$PFILE" = "$PDIR/$(tr / - <<<"${MNT#/}/approved").toml" ]
assert "  missing snapshot_root created"        [ -d "$MNT/approved-snaps" ]
check "approved parent is listed"               ok   query list
assert "  as a drop-in parent"                  [ "$(field "[p['origin'] for p in d['result']['create_parents'] if p['path'] == '$MNT/approved']")" = "['dropin']" ]
check "approving it twice refused"              fail manage add-parent "$MNT/approved" "$MNT/approved-snaps"
check "config.toml parent can't be re-approved" fail manage add-parent "$MNT/vmdisks" "$MNT/vmsnaps"

check "new-volume under approved parent"        ok   manage new-volume Approved "$MNT/approved" appvol --nocow
assert "  subvolume + snapshot dir created"     [ -d "$MNT/approved/appvol" -a -d "$MNT/approved-snaps/appvol" ]
assert "  subvolume is a subvolume"             sh -c "btrfs subvolume show '$MNT/approved/appvol' >/dev/null 2>&1"
check "  snapshot it"                           ok   admin snapshot Approved first
assert "  snapshot is in the snapshot root"     [ -d "$MNT/approved-snaps/appvol/$(field "d['result']['name']")" ]
check "  list"                                  ok   query list
assert "  data deletable under approved parent" [ "$(vol "v['Approved']['data_deletable']")" = "True" ]

check "different filesystem refused"            fail manage add-parent "$MNT/other" "$MNT2/othersnaps"
assert "  because of the filesystem"            grep -q "different btrfs filesystems" <<<"$LAST"
check "missing root on other fs refused"        fail manage add-parent "$MNT/other" "$MNT2/newsnaps"
assert "  and not created"                      [ ! -e "$MNT2/newsnaps" ]
check "non-btrfs path refused"                  fail manage add-parent "$WORK/tmpfs" "$MNT/tmpsnaps"
assert "  as not btrfs"                         grep -q "not on a btrfs" <<<"$LAST"

for p in / /boot /etc /usr /var/lib /proc/self /sys/kernel /dev/shm; do
  check "system path $p refused"                fail manage add-parent "$p" "$MNT/syssnaps"
  assert "  as a system location"               grep -q "system location" <<<"$LAST"
done
check "system snapshot_root refused"            fail manage add-parent "$MNT/other" /usr
assert "  as a system location"                 grep -q "system location" <<<"$LAST"

check "symlinked path refused"                  fail manage add-parent "$MNT/other-link" "$MNT/othersnaps"
check "symlink inside the path refused"         fail manage add-parent "$WORK/mnt-link/other" "$MNT/othersnaps"
check "symlinked snapshot_root refused"         fail manage add-parent "$MNT/other" "$MNT/snaps-link"
check "root under a symlink refused"            fail manage add-parent "$MNT/other" "$MNT/snaps-link/new"
assert "  and not created"                      [ ! -e "$MNT/snapshots/new" ]
check "relative path refused"                   fail manage add-parent other "$MNT/othersnaps"
check "'..' in path refused"                    fail manage add-parent "$MNT/approved/../other" "$MNT/othersnaps"
check "missing path refused"                    fail manage add-parent "$MNT/nope" "$MNT/othersnaps"
check "path == snapshot_root refused"           fail manage add-parent "$MNT/other" "$MNT/other"
assert "refusals wrote nothing"                 [ "$(ls "$PDIR")" = "$(basename "$PFILE")" -a ! -e "$MNT/othersnaps" ]

# bad parents.d files are skipped and reported, like volumes.d
printf '[parent]\npath = "relative"\nsnapshot_root = "/x"\n' > "$PDIR/broken.toml"
printf '[parent]\npath = "%s"\nsnapshot_root = "%s"\n' "$MNT/vmdisks" "$MNT/x" > "$PDIR/dup.toml"
printf '[parent]\npath = "%s"\nsnapshot_root = "%s"\n' "$MNT/other" "$MNT/snapshots" > "$PDIR/open.toml"
chmod 644 "$PDIR/broken.toml" "$PDIR/dup.toml"; chmod 666 "$PDIR/open.toml"
check "bad parents.d files don't break list"    ok   query list
assert "  all three reported"                   [ "$(field "sum('parents.d' in e for e in d['result']['config_errors'])")" = "3" ]
assert "  none of them loaded"                  [ "$(field "sorted(p['path'] for p in d['result']['create_parents'])")" = "['$MNT/approved', '$MNT/vmdisks']" ]
check "world-writable parent not usable"        fail manage new-volume Open "$MNT/other" open
rm "$PDIR/broken.toml" "$PDIR/dup.toml" "$PDIR/open.toml"

check "config.toml parent can't be removed"     fail manage remove-parent "$MNT/vmdisks"
check "unknown parent can't be removed"         fail manage remove-parent "$MNT/other"
check "remove approved parent"                  ok   manage remove-parent "$MNT/approved"
assert "  warns about the volume under it"      grep -q "Approved" <<<"$(field "d['warnings']")"
assert "  file gone, data untouched"            [ ! -e "$PFILE" -a -d "$MNT/approved/appvol" -a -d "$MNT/approved-snaps/appvol" ]
check "  list"                                  ok   query list
assert "  parent gone, volume still listed"     [ "$(field "[p['path'] for p in d['result']['create_parents']]")" = "['$MNT/vmdisks']" -a "$(vol "v['Approved']['data_deletable']")" = "False" ]
check "new-volume under removed parent refused" fail manage new-volume Late "$MNT/approved" late
check "approve it again"                        ok   manage add-parent "$MNT/approved" "$MNT/approved-snaps"
assert "  same file name"                       [ "$(field "d['result']['origin_file']")" = "$PFILE" ]

# ---------------------------------------------------------------- discover / register
btrfs -q subvolume create "$MNT/@reg1" >/dev/null
btrfs -q subvolume create "$MNT/@reg2" >/dev/null
btrfs -q subvolume create "$MNT/@reg1/inner" >/dev/null
DATAMNT=$WORK/datamnt; mkdir -p "$DATAMNT" && mount -o loop,subvol=@data "$IMG" "$DATAMNT"
check "discover works"                          ok   query discover
# fs(): the test filesystem's entry; sub(PATH): one of its subvolumes, by path in the fs
fs() { echo "$LAST" | "$PY" -c "import json,sys; d=json.load(sys.stdin); f=[f for f in d['result']['filesystems'] if any(m['path']=='$MNT' for m in f['mounts'])][0]; s={x['path']:x for x in f['subvolumes']}; print(eval(sys.argv[1]))" "$1"; }
assert "  both mounts of it listed"             [ "$(fs "sorted(m['path'] for m in f['mounts'])")" = "['$DATAMNT', '$MNT']" ]
assert "  subvolumes reachable via the top level" [ "$(fs "s['@data']['reachable']")" = "$MNT/@data" ]
assert "  nested subvolume found"               [ "$(fs "s['@reg1/inner']['reachable']")" = "$MNT/@reg1/inner" ]
assert "  snapshot: read-only, parent uuid"     [ "$(fs "s['snapshots/vms/manual-old']['read_only'] and s['snapshots/vms/manual-old']['parent_uuid'] == s['@vms']['uuid']")" = True ]
assert "  received snapshot flagged"            [ "$(fs "s['snapshots/data/manual-old']['received']")" = True ]
# Where a subvolume shows under a mount; a mount on / must not give "//snapshots/..."
mp() { "$PY" -I -c "import sys; sys.path.insert(0, '$SRC'); import snapman_core as c; print(c._mount_path(*sys.argv[1:]))" "$@"; }
assert "mount path: under a mount of / (laptop)"    [ "$(mp / /@ @/snapshots/home/Home_1)" = /snapshots/home/Home_1 ]
assert "mount path: the mounted subvolume itself"   [ "$(mp / /@ @)" = / -a "$(mp /home /@home @home)" = /home ]
assert "mount path: top level mounted elsewhere"    [ "$(mp /media/SSD1 / docker/archive)" = /media/SSD1/docker/archive ]
assert "mount path: not shown by that mount"        [ "$(mp / /@ @home)" = None -a "$(mp / /@ @x/y)" = None ]
btrfs -q subvolume create "$MNT/@data/sub" >/dev/null
check "discover again"                          ok   query discover
assert "  reached through a subvolume mount only" [ "$(echo "$LAST" | "$PY" -c "import sys; sys.path.insert(0, '$SRC'); import snapman_core as c, btrfsutil; print(c._reachable('@data/sub', btrfsutil.subvolume_id('$MNT/@data/sub'), [('$DATAMNT', '/@data')]))")" = "$DATAMNT/sub" ]
btrfs -q subvolume delete "$MNT/@data/sub" >/dev/null
umount "$DATAMNT"
check "admin helper refuses register"           fail admin register a "$MNT/@reg1" "$MNT/rs" - -
check "register: not a multiple of five"        fail manage register a "$MNT/@reg1" "$MNT/rs" -
check "register: plain folder refused"          fail manage register a "$MNT/vmdisks" "$MNT/rs" - -
assert "  says not a subvolume"                 grep -q "not a btrfs subvolume" <<<"$LAST"
ln -s "$MNT/@reg1" "$MNT/reglink"
check "register: symlinked path refused"        fail manage register a "$MNT/reglink" "$MNT/rs" - -
check "register: relative path refused"         fail manage register a "@reg1" "$MNT/rs" - -
check "register: existing name refused"         fail manage register vms "$MNT/@reg1" "$MNT/rs" - -
check "register: same name twice refused"       fail manage register a "$MNT/@reg1" "$MNT/rs" - - a "$MNT/@reg2" "$MNT/rs" - -
check "register: snapshot_dir holding live subvolumes" fail manage register a "$MNT/@reg1" "$MNT" - -
assert "  says why"                             grep -q "holds the live subvolume" <<<"$LAST"
check "register: snapshot_dir = path refused"   fail manage register a "$MNT/@reg1" "$MNT/@reg1" - -
check "register: other filesystem refused"      fail manage register a "$MNT/@reg1" "$MNT2/rs" - -
check "register: system location refused"       fail manage register a "$MNT/@reg1" /etc - -
check "register: name_format without timestamp" fail manage register a "$MNT/@reg1" "$MNT/rs" "{volume}_{label}" -
check "register: unknown name_format field"     fail manage register a "$MNT/@reg1" "$MNT/rs" "{evil}{timestamp}" -
check "register: name_format with a slash"      fail manage register a "$MNT/@reg1" "$MNT/rs" "a/{timestamp}" -
check "register: bad timestamp_format"          fail manage register a "$MNT/@reg1" "$MNT/rs" - "%Y/%m"
check "register: bad second volume, none written" fail manage register a "$MNT/@reg1" "$MNT/rs" - - b "$MNT/nope" "$MNT/rs" - -
assert "refusals wrote nothing"                 [ ! -e "$CFGDIR/volumes.d/a.toml" -a ! -e "$CFGDIR/volumes.d/b.toml" -a ! -e "$MNT/rs" ]
rm "$MNT/reglink"
check "register two volumes in one call"        ok   manage register reg1 "$MNT/@reg1" "$MNT/regsnaps/reg1" "r1-{timestamp}_{label}" "%Y%m%d" reg2 "$MNT/@reg2" "$MNT/regsnaps/shared" - -
assert "  missing folders created"              [ -d "$MNT/regsnaps/reg1" -a -d "$MNT/regsnaps/shared" ]
assert "  formats written only when given"      eval 'grep -q "name_format = \"r1-{timestamp}_{label}\"" "$CFGDIR/volumes.d/reg1.toml" && ! grep -q name_format "$CFGDIR/volumes.d/reg2.toml"'
check "  list shows them, managed"              ok   query list
assert "  removable, no error"                  [ "$(vol "(v['reg1']['removable'], v['reg2']['error'])")" = "(True, None)" ]
check "  snapshot uses the name format"         ok   admin snapshot reg1 first
assert "  named r1-<date>_first"                [ "$(field "d['result']['name']")" = "r1-$(date +%Y%m%d)_first" ]
check "  already registered: refused"           fail manage register reg1 "$MNT/@reg1" "$MNT/regsnaps/reg1" - -
check "  unregister works as for any drop-in"   ok   manage remove-volume reg2
assert "  file gone, data kept"                 [ ! -e "$CFGDIR/volumes.d/reg2.toml" -a -d "$MNT/@reg2" ]

# ---------------------------------------------------------------- config hardening
chmod 666 "$CFGDIR/config.toml"
check "world-writable config refused"           fail query list
chmod 644 "$CFGDIR/config.toml"
chmod 666 "$CFGDIR/volumes.d/dataalias.toml"
check "world-writable drop-in skipped"          ok   query list
assert "  and reported"                         grep -q "dataalias.toml" <<<"$(field "d['result']['config_errors']")"

# ---------------------------------------------------------------- privilege
# The journal names the caller: pkexec's PKEXEC_UID, else sudo's SUDO_UID, else our own UID.
caller() { env -u PKEXEC_UID -u SUDO_UID "$@" "$PY" -I -c "import sys; sys.path.insert(0, '$SRC'); import snapman_core as c; print(c._caller_uid())"; }
assert "caller uid: PKEXEC_UID wins"            [ "$(caller PKEXEC_UID=1001 SUDO_UID=1002)" = 1001 ]
assert "caller uid: then SUDO_UID"              [ "$(caller SUDO_UID=1002)" = 1002 ]
assert "caller uid: empty PKEXEC_UID ignored"   [ "$(caller PKEXEC_UID= SUDO_UID=1002)" = 1002 ]
assert "caller uid: else getuid()"              [ "$(caller)" = "$(id -u)" ]
LAST=$("$PY" -I -c "import os, sys; sys.path.insert(0, '$SRC'); import snapman_core as c; os.seteuid(65534); sys.exit(c.main('query', ['list'], '$CFGDIR/config.toml'))")
assert "non-root refused"                       [ $? -eq 1 ]
assert "  error names pkexec and sudo"          grep -q "via pkexec or sudo" <<<"$LAST"

echo; echo "passed=$pass failed=$fail"
[ $fail -eq 0 ]
