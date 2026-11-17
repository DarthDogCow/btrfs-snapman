#!/bin/bash
# Headless install check: on a server image, installing btrfs-snapman-common and
# btrfs-snapman-cli must not pull in GTK, GObject introspection, pkexec or polkit.
# Only simulates, but run it on a clean machine (a disposable VM or container) so the
# answer reflects a fresh Pi rather than whatever is already installed.
# Usage: tests/test_headless.sh NEW_DIR      (the folder with the new .debs)
set -u
NEW=$(realpath "$1")
OUT=$(apt-get install --simulate "$NEW"/btrfs-snapman-common_*_all.deb \
        "$NEW"/btrfs-snapman-cli_*_all.deb 2>&1)
rc=$?
echo "$OUT" | grep '^Inst '
bad=$(echo "$OUT" | grep '^Inst ' | grep -E 'gir1\.2-|gtk|libadwaita|pkexec|polkit' || true)
if [ $rc -eq 0 ] && [ -z "$bad" ]; then
  echo "PASS  CLI-only install pulls in no GTK, gir, pkexec or polkit"
else
  echo "FAIL  rc=$rc"; echo "$bad"; exit 1
fi
