#!/bin/bash
# btrfs-snapman installer for Ubuntu 24.04 / 26.04: builds the .deb and installs it with apt.
#   sudo ./install.sh               install or upgrade (never touches your config)
#   sudo ./install.sh --uninstall   remove the program (config in /etc is kept)
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
cd "$(dirname "$0")"

VERSION=$(sed -n '1s/^btrfs-snapman (\([^)]*\)).*/\1/p' debian/changelog)
DEB=btrfs-snapman_${VERSION}_all.deb
ETC=/etc/btrfs-snapman

# Versions before 0.5.0 were copied into /usr/local by this script. /usr/local/bin comes
# first on PATH, so a leftover copy would shadow the packaged one.
remove_legacy() {
  rm -rf /usr/local/lib/btrfs-snapman /usr/local/libexec/btrfs-snapman
  rm -f /usr/local/bin/btrfs-snapman \
        /usr/local/share/applications/dev.snapman.BtrfsSnapman.desktop \
        /usr/share/polkit-1/actions/dev.snapman.btrfs-snapman.policy
}

# Uninstall: "remove", not "purge", so dpkg keeps the conffile and volumes.d.
if [ "${1:-}" = "--uninstall" ]; then
  remove_legacy
  if dpkg-query -W -f='${Status}' btrfs-snapman 2>/dev/null | grep -q '^install ok installed'; then
    apt-get remove -y btrfs-snapman
  fi
  echo "Removed. Config left in $ETC"; exit 0
fi

# Build tools (debhelper pulls in dpkg-dev).
dpkg-query -W -f='${Status}' debhelper 2>/dev/null | grep -q '^install ok installed' \
  || { echo "Installing build tools: debhelper"; apt-get install -y --no-install-recommends debhelper; }

# Build in a temporary copy: dpkg-buildpackage writes into the parent directory and
# leaves root-owned files in debian/. The directory is world-readable so apt's
# unprivileged _apt user can read the .deb.
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
chmod 755 "$BUILD"
mkdir "$BUILD/btrfs-snapman"
cp -r debian src data contrib README.md LICENSE "$BUILD/btrfs-snapman/"
(cd "$BUILD/btrfs-snapman" && dpkg-buildpackage -us -uc -b)

# Dependencies come from the package. confold keeps an existing config.toml
# (e.g. from a /usr/local install) instead of prompting; the packaged example is
# saved as config.toml.dpkg-dist.
apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
  "$BUILD/$DEB"
remove_legacy

# Keep a copy of the .deb next to the source, owned by whoever ran sudo.
install -m 644 "$BUILD/$DEB" .
[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER:" "$DEB"
echo "Installed $DEB. Launch 'Btrfs Snapshots' from the app grid, or run: btrfs-snapman"
