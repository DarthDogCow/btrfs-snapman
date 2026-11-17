#!/bin/bash
# Upgrade test, 0.6.0 (one package) -> 0.7.0 or later (common + GUI + CLI). Installs packages and
# edits /etc, so run it as root ONLY on a disposable Ubuntu 24.04 machine or container.
# Usage: tests/test_upgrade.sh OLD.deb NEW_DIR
#   OLD.deb   btrfs-snapman_0.6.0_all.deb, built from the v0.6.0 commit
#   NEW_DIR   the folder with the three new .debs
# 1. An edited config.toml and a volumes.d file survive the move to btrfs-snapman-common,
#    which owns the conffile afterwards. If the packaged example changed since 0.6.0, dpkg
#    asks about it; the answer "keep yours" is given the way install.sh gives it.
# 2. An untouched config.toml is replaced by the new example with no prompt at all.
set -u
OLD=$(realpath "$1"); NEW=$(realpath "$2")
V=$(dpkg-deb -f "$NEW"/btrfs-snapman-common_*_all.deb Version)
ETC=/etc/btrfs-snapman
pass=0; fail=0
assert() {
  local desc=$1; shift
  if "$@"; then pass=$((pass+1)); echo "PASS  $desc"; else fail=$((fail+1)); echo "FAIL  $desc"; fi
}
export DEBIAN_FRONTEND=noninteractive
clean() {
  apt-get purge -y -q btrfs-snapman btrfs-snapman-cli btrfs-snapman-common </dev/null >/dev/null 2>&1
  rm -rf "$ETC"
}
# The new packaged example, and whether it differs from 0.6.0's
dpkg-deb -x "$NEW"/btrfs-snapman-common_"$V"_all.deb "$NEW/x-new"
dpkg-deb -x "$OLD" "$NEW/x-old"
new_example=$(sha256sum < "$NEW/x-new$ETC/config.toml")
changed=$(cmp -s "$NEW/x-new$ETC/config.toml" "$NEW/x-old$ETC/config.toml" || echo yes)
rm -rf "$NEW/x-new" "$NEW/x-old"

# ---------------------------------------------------------------- 1. edited config
clean
apt-get install -y -q "$OLD" >/dev/null 2>&1
assert "0.6.0 installed"                      eval '[ "$(dpkg-query -W -f="\${Version}" btrfs-snapman)" = 0.6.0 ]'
# Edit the conffile the way an admin would, and add a GUI-style drop-in
printf '\n# edited by hand before the upgrade\n' >> "$ETC/config.toml"
printf '[volume]\nname = "keep"\npath = "/srv/keep"\nsnapshot_dir = "/srv/snapshots/keep"\n' \
  > "$ETC/volumes.d/keep.toml"
before_cfg=$(sha256sum < "$ETC/config.toml"); before_vol=$(sha256sum < "$ETC/volumes.d/keep.toml")

# No terminal. Only when the example changed is there a question to answer at all.
opts=(); [ -n "$changed" ] && opts=(-o Dpkg::Options::=--force-confold)
apt-get install -y -q "${opts[@]}" "$NEW"/btrfs-snapman*_"$V"_all.deb </dev/null >"$NEW/upgrade.log" 2>&1
assert "upgrade succeeded"                    [ $? -eq 0 ]
assert "  all three $V packages installed" [ "$(dpkg-query -W -f='${Version} ' btrfs-snapman btrfs-snapman-common btrfs-snapman-cli)" = "$V $V $V " ]
assert "config.toml byte-identical"           [ "$(sha256sum < "$ETC/config.toml")" = "$before_cfg" ]
if [ -n "$changed" ]; then
  assert "  new example saved as .dpkg-dist"  [ "$(sha256sum < "$ETC/config.toml.dpkg-dist")" = "$new_example" ]
  assert "  no other .dpkg-* files"           [ "$(find "$ETC" -name '*.dpkg-*')" = "$ETC/config.toml.dpkg-dist" ]
else
  assert "  no conffile question in the log"  eval '! grep -qi "configuration file" "$NEW/upgrade.log"'
  assert "  no .dpkg-* files"                 eval '[ -z "$(find "$ETC" -name "*.dpkg-*")" ]'
fi
assert "volumes.d file untouched"             [ "$(sha256sum < "$ETC/volumes.d/keep.toml")" = "$before_vol" ]
assert "conffile owned by btrfs-snapman-common" [ "$(dpkg -S "$ETC/config.toml")" = "btrfs-snapman-common: $ETC/config.toml" ]
# The GUI may keep an "obsolete" record of it (dpkg's normal trace of a moved conffile);
# common's record keeps the packaged hash, so later upgrades prompt only as they should.
assert "  GUI's record of it only obsolete"   eval '! dpkg-query -W -f="\${Conffiles}\n" btrfs-snapman | grep config.toml | grep -vq obsolete'
assert "  common's record active"             eval 'dpkg-query -W -f="\${Conffiles}\n" btrfs-snapman-common | grep config.toml | grep -vq obsolete'

# Purging the GUI must not take the config with it
apt-get purge -y -q btrfs-snapman </dev/null >/dev/null 2>&1
assert "purging the GUI keeps config.toml"    [ "$(sha256sum < "$ETC/config.toml")" = "$before_cfg" ]
assert "  and volumes.d"                      [ -f "$ETC/volumes.d/keep.toml" ]
assert "  CLI still installed"                eval 'dpkg-query -W -f="\${Status}" btrfs-snapman-cli | grep -q "install ok installed"'

# ---------------------------------------------------------------- 2. untouched config
clean
apt-get install -y -q "$OLD" >/dev/null 2>&1
apt-get install -y -q "$NEW"/btrfs-snapman*_"$V"_all.deb </dev/null >"$NEW/upgrade2.log" 2>&1
assert "untouched config: upgrade with no options" [ $? -eq 0 ]
assert "  now the new example"                [ "$(sha256sum < "$ETC/config.toml")" = "$new_example" ]
assert "  no .dpkg-* files"                   eval '[ -z "$(find "$ETC" -name "*.dpkg-*")" ]'

echo; echo "passed=$pass failed=$fail"
[ $fail -eq 0 ]
