#!/bin/bash
# Upgrade test, 0.6.0 (one package) -> 0.7.0 (common + GUI + CLI). Installs packages and
# edits /etc, so run it as root ONLY on a disposable Ubuntu 24.04 machine or container.
# Usage: tests/test_upgrade.sh OLD.deb NEW_DIR
#   OLD.deb   btrfs-snapman_0.6.0_all.deb, built from the v0.6.0 commit
#   NEW_DIR   the folder with the three 0.7.0 .debs
# Checks that an edited config.toml and a volumes.d file survive with no prompt and no
# .dpkg-* leftovers, and that btrfs-snapman-common owns the conffile afterwards.
set -u
OLD=$(realpath "$1"); NEW=$(realpath "$2")
ETC=/etc/btrfs-snapman
pass=0; fail=0
assert() {
  local desc=$1; shift
  if "$@"; then pass=$((pass+1)); echo "PASS  $desc"; else fail=$((fail+1)); echo "FAIL  $desc"; fi
}
export DEBIAN_FRONTEND=noninteractive

apt-get install -y -q "$OLD" >/dev/null 2>&1
assert "0.6.0 installed"                      eval '[ "$(dpkg-query -W -f="\${Version}" btrfs-snapman)" = 0.6.0 ]'
# Edit the conffile the way an admin would, and add a GUI-style drop-in
printf '\n# edited by hand before the upgrade\n' >> "$ETC/config.toml"
printf '[volume]\nname = "keep"\npath = "/srv/keep"\nsnapshot_dir = "/srv/snapshots/keep"\n' \
  > "$ETC/volumes.d/keep.toml"
before_cfg=$(sha256sum < "$ETC/config.toml"); before_vol=$(sha256sum < "$ETC/volumes.d/keep.toml")

# No --force-conf* options, and no terminal: a conffile prompt would fail the install.
apt-get install -y -q "$NEW"/btrfs-snapman*_0.7.0_all.deb </dev/null >"$NEW/upgrade.log" 2>&1
assert "upgrade succeeded without a prompt"   [ $? -eq 0 ]
assert "  no conffile question in the log"    eval '! grep -qi "configuration file" "$NEW/upgrade.log"'
assert "  all three 0.7.0 packages installed" [ "$(dpkg-query -W -f='${Version} ' btrfs-snapman btrfs-snapman-common btrfs-snapman-cli)" = "0.7.0 0.7.0 0.7.0 " ]
assert "config.toml byte-identical"           [ "$(sha256sum < "$ETC/config.toml")" = "$before_cfg" ]
assert "no .dpkg-dist / .dpkg-old / .dpkg-new" eval '[ -z "$(find "$ETC" -name "*.dpkg-*")" ]'
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

echo; echo "passed=$pass failed=$fail"
[ $fail -eq 0 ]
