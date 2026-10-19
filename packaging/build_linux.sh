#!/usr/bin/env bash
# Builds Linux packages into dist/:
#   meshtasks-<ver>-linux-x64.tar.gz   portable, any distro (has install.sh)
#   meshtasks_<ver>_amd64.deb          Debian / Ubuntu / Mint
#   meshtasks-<ver>-1-x86_64.pkg.tar.zst  Arch (only when makepkg exists)
# Needs glibc >= 2.34 on the target (Ubuntu 22.04+, Debian 12+, Fedora 35+).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_ID=dev.henseries.meshtasks
VERSION=$(grep '^version:' pubspec.yaml | sed 's/version: *//; s/+.*//')
DIST=dist
WORK=build/pkg
BUNDLE=build/linux/x64/release/bundle

[[ ${SKIP_BUILD:-} ]] || flutter build linux --release
rm -rf "$WORK" && mkdir -p "$WORK" "$DIST"

desktop_entry() { # $1 = Exec path
  cat <<EOF
[Desktop Entry]
Type=Application
Name=MeshTasks
GenericName=Team task manager
Comment=Team tasks synced peer-to-peer, no server
Exec=$1
Icon=$APP_ID
Terminal=false
Categories=Office;ProjectManagement;
Keywords=todo;tasks;todoist;team;
StartupWMClass=$APP_ID
EOF
}

install_icons() { # $1 = share dir
  for s in 16 32 48 64 128 256 512; do
    install -Dm644 packaging/icons/meshtasks-$s.png "$1/icons/hicolor/${s}x${s}/apps/$APP_ID.png"
  done
  install -Dm644 packaging/icons/meshtasks.svg "$1/icons/hicolor/scalable/apps/$APP_ID.svg"
}

# ---- filesystem tree shared by .deb and Arch: /opt/meshtasks + /usr ----
ROOT=$WORK/root
mkdir -p "$ROOT/opt/meshtasks" "$ROOT/usr/bin"
cp -r "$BUNDLE"/. "$ROOT/opt/meshtasks/"
ln -s /opt/meshtasks/meshtasks "$ROOT/usr/bin/meshtasks"
desktop_entry /opt/meshtasks/meshtasks | install -Dm644 /dev/stdin "$ROOT/usr/share/applications/$APP_ID.desktop"
install_icons "$ROOT/usr/share"

# ---- portable tarball ----
TAR=$WORK/meshtasks-$VERSION
mkdir -p "$TAR"
cp -r "$BUNDLE"/. "$TAR/"
mkdir -p "$TAR/share" && install_icons "$TAR/share"
cat > "$TAR/install.sh" <<'EOF'
#!/usr/bin/env bash
# Installs MeshTasks for the current user (no root needed).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}
APP_ID=dev.henseries.meshtasks
rm -rf "$DEST/meshtasks" && mkdir -p "$DEST/meshtasks"
cp -r "$HERE"/meshtasks "$HERE"/lib "$HERE"/data "$DEST/meshtasks/"
cp -r "$HERE"/share/icons "$DEST/"
mkdir -p "$HOME/.local/bin" "$DEST/applications"
ln -sf "$DEST/meshtasks/meshtasks" "$HOME/.local/bin/meshtasks"
sed "s|@EXEC@|$DEST/meshtasks/meshtasks|" "$HERE/share/$APP_ID.desktop.in" > "$DEST/applications/$APP_ID.desktop"
command -v update-desktop-database >/dev/null && update-desktop-database "$DEST/applications" || true
echo "Installed. Launch MeshTasks from your app menu or run: meshtasks"
EOF
cat > "$TAR/uninstall.sh" <<'EOF'
#!/usr/bin/env bash
DEST=${XDG_DATA_HOME:-$HOME/.local/share}
rm -rf "$DEST/meshtasks" "$HOME/.local/bin/meshtasks" "$DEST/applications/dev.henseries.meshtasks.desktop"
find "$DEST/icons/hicolor" -name 'dev.henseries.meshtasks.*' -delete 2>/dev/null
echo "Removed MeshTasks (your task database in ~/.local/share/dev.henseries.meshtasks is kept)."
EOF
chmod +x "$TAR/install.sh" "$TAR/uninstall.sh"
desktop_entry @EXEC@ > "$TAR/share/$APP_ID.desktop.in"
tar -C "$WORK" -czf "$DIST/meshtasks-$VERSION-linux-x64.tar.gz" "meshtasks-$VERSION"

# ---- .deb (assembled with ar/tar so it builds on any distro) ----
DEB=$WORK/deb && mkdir -p "$DEB"
SIZE=$(du -sk "$ROOT" | cut -f1)
cat > "$DEB/control" <<EOF
Package: meshtasks
Version: $VERSION
Section: utils
Priority: optional
Architecture: amd64
Depends: libgtk-3-0 | libgtk-3-0t64, libc6 (>= 2.34)
Installed-Size: $SIZE
Maintainer: Jorge Restrepo <gi.dev.labs@gmail.com>
Description: Team task manager synced peer-to-peer
 Todoist-style tasks for a work team. Every device keeps a full copy and
 syncs directly with the others over the local network or a VPN.
EOF
echo 2.0 > "$DEB/debian-binary"
tar --owner=0 --group=0 -C "$DEB" -cJf "$DEB/control.tar.xz" ./control
tar --owner=0 --group=0 -C "$ROOT" -cJf "$DEB/data.tar.xz" .
rm -f "$DIST/meshtasks_${VERSION}_amd64.deb"
(cd "$DEB" && ar rc "../../../$DIST/meshtasks_${VERSION}_amd64.deb" debian-binary control.tar.xz data.tar.xz)

# ---- Arch package ----
if command -v makepkg >/dev/null; then
  ARCH=$WORK/arch && mkdir -p "$ARCH"
  cp -a "$ROOT" "$ARCH/root"
  cat > "$ARCH/PKGBUILD" <<EOF
pkgname=meshtasks
pkgver=$VERSION
pkgrel=1
pkgdesc="Team task manager synced peer-to-peer, no server"
arch=(x86_64)
license=(custom)
depends=(gtk3)
options=(!strip !debug)
package() { cp -a "\$startdir/root/." "\$pkgdir/"; }
EOF
  (cd "$ARCH" && PKGDEST="$PWD/../../../$DIST" makepkg -f --nodeps >/dev/null)
fi

ls -lh "$DIST"
