# Shared by test_cli.sh and test_tui.sh: a loopback btrfs filesystem with two volumes (plus
# one whose subvolume is missing), a received snapshot, a config with one create parent and
# a broken drop-in, and --libexec wrappers that run the helpers from the source tree with
# that config.
# Expects SRC and PY; sets WORK, MNT, CFGDIR and LIBEXEC, and cleans up on exit.
WORK=$(mktemp -d)
MNT=$WORK/mnt
CFGDIR=$WORK/etc
LIBEXEC=$WORK/libexec

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

[[volume]]
name = "gone"
path = "$MNT/@gone"
snapshot_dir = "$MNT/snapshots/gone"

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

