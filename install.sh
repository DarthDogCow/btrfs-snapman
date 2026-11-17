#!/bin/bash
# btrfs-snapman installer for Ubuntu 24.04 / 26.04: builds the .debs and installs them with apt.
#   sudo ./install.sh               install or upgrade the GUI and the terminal interface
#   sudo ./install.sh --cli         terminal interface only, for headless machines (no GTK)
#   sudo ./install.sh --uninstall   remove the program (config in /etc is kept)
# Your config is never touched.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
cd "$(dirname "$0")"

VERSION=$(sed -n '1s/^btrfs-snapman (\([^)]*\)).*/\1/p' debian/changelog)
ETC=/etc/btrfs-snapman
PACKAGES=(btrfs-snapman-common btrfs-snapman btrfs-snapman-cli)
case "${1:-}" in
  "")          WANT=(btrfs-snapman-common btrfs-snapman btrfs-snapman-cli) ;;
  --cli)       WANT=(btrfs-snapman-common btrfs-snapman-cli) ;;
  --uninstall) ;;
  *)           echo "usage: $0 [--cli | --uninstall]" >&2; exit 2 ;;
esac
installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed'; }

# Versions before 0.5.0 were copied into /usr/local by this script. /usr/local/bin comes
# first on PATH, so a leftover copy would shadow the packaged one.
remove_legacy() {
  rm -rf /usr/local/lib/btrfs-snapman /usr/local/libexec/btrfs-snapman
  rm -f /usr/local/bin/btrfs-snapman \
        /usr/local/share/applications/dev.snapman.BtrfsSnapman.desktop \
        /usr/share/polkit-1/actions/dev.snapman.btrfs-snapman.policy
}

# Uninstall: "remove", not "purge", so dpkg keeps the conffile, volumes.d and parents.d.
if [ "${1:-}" = "--uninstall" ]; then
  remove_legacy
  remove=()
  for p in "${PACKAGES[@]}"; do installed "$p" && remove+=("$p"); done
  [ ${#remove[@]} -gt 0 ] && apt-get remove -y "${remove[@]}"
  echo "Removed. Config left in $ETC"; exit 0
fi

# Build tools: dpkg-buildpackage insists on build-essential; debhelper pulls in dpkg-dev.
tools=()
for p in build-essential debhelper; do
  installed "$p" || tools+=("$p")
done
if [ ${#tools[@]} -gt 0 ]; then
  echo "Installing build tools: ${tools[*]}"; apt-get install -y --no-install-recommends "${tools[@]}"
fi

# Build in a temporary copy: dpkg-buildpackage writes into the parent directory and
# leaves root-owned files in debian/. The directory is world-readable so apt's
# unprivileged _apt user can read the .deb.
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
chmod 755 "$BUILD"
mkdir "$BUILD/btrfs-snapman"
cp -r debian src data contrib README.md LICENSE "$BUILD/btrfs-snapman/"
(cd "$BUILD/btrfs-snapman" && dpkg-buildpackage -us -uc -b)

# Dependencies come from the packages. confold keeps an existing config.toml
# (e.g. from a /usr/local install) instead of prompting; the packaged example is
# saved as config.toml.dpkg-dist.
DEBS=()
for p in "${WANT[@]}"; do DEBS+=("${p}_${VERSION}_all.deb"); done
apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
  "${DEBS[@]/#/$BUILD/}"
remove_legacy

# Keep a copy of the .debs next to the source, owned by whoever ran sudo.
for d in "$BUILD"/btrfs-snapman*_"${VERSION}"_all.deb; do
  install -m 644 "$d" .
  [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER:" "$(basename "$d")"
done
echo "Installed ${WANT[*]} $VERSION."
installed btrfs-snapman && echo "GUI: 'Btrfs Snapshots' in the app grid, or run: btrfs-snapman"
echo "Terminal: btrfs-snapman-cli (full screen), or btrfs-snapman-cli --help"
