#!/bin/bash
#
# make-pkg.sh — build the oh-my-dsh installer package (and a DMG) for the
# current architecture (arm64 on Apple Silicon), so the app can be installed
# into /Applications.
#
# Produces (in dist/):
#   oh-my-dsh-<version>-<arch>.pkg   — installer package (install to /Applications)
#   oh-my-dsh-<version>-<arch>.dmg   — drag-and-drop disk image (bonus)
#
# Requires: the app built by build-app.sh (dist/oh-my-dsh.app), plus Xcode
# Command Line Tools (pkgbuild, hdiutil).
#
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"

APP_NAME="oh-my-dsh"
APP="$ROOT/dist/$APP_NAME.app"
DIST="$ROOT/dist"
BUILD_DIR="$ROOT/.build"

[ -d "$APP" ] || { echo "ERROR: $APP not found — run ./platforms/macos/build-app.sh first" >&2; exit 1; }

ARCH="${DSH_ARCH:-$(uname -m)}"
case "$ARCH" in
  aarch64) ARCH="arm64" ;;
  amd64)   ARCH="x86_64" ;;
esac
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")"
PKG="$DIST/${APP_NAME}-${VERSION}-${ARCH}.pkg"
DMG="$DIST/${APP_NAME}-${VERSION}-${ARCH}.dmg"

echo "==> [1/3] preparing preinstall script (clean reinstall)"
SCRIPTS="$BUILD_DIR/pkg-scripts"
rm -rf "$SCRIPTS"
mkdir -p "$SCRIPTS"
cat > "$SCRIPTS/preinstall" <<'EOF'
#!/bin/sh
# Remove any previous installation so reinstalls never leave stale files.
rm -rf "/Applications/oh-my-dsh.app"
exit 0
EOF
chmod +x "$SCRIPTS/preinstall"

echo "==> [2/3] building installer package"
rm -f "$PKG"
# Ad-hoc sign if the toolchain accepts "-"; otherwise leave unsigned (local
# install still works, macOS just asks for confirmation).
if pkgbuild --component "$APP" \
            --install-location /Applications \
            --identifier "$BUNDLE_ID" \
            --version "$VERSION" \
            --scripts "$SCRIPTS" \
            --sign - \
            "$PKG" 2>/dev/null; then
  echo "    pkg (ad-hoc signed): $PKG"
else
  pkgbuild --component "$APP" \
           --install-location /Applications \
           --identifier "$BUNDLE_ID" \
           --version "$VERSION" \
           --scripts "$SCRIPTS" \
           "$PKG"
  echo "    pkg (unsigned): $PKG"
fi

echo "==> [3/3] building DMG (drag to /Applications)"
rm -f "$DMG"
STAGE="$BUILD_DIR/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo ""
echo "Built:"
du -sh "$PKG" "$DMG" | sed 's/^/  /'
echo ""
echo "Install with:"
echo "  open \"$(pwd)/$PKG\"        (installer → /Applications)"
echo "  open \"$(pwd)/$DMG\"        (drag oh-my-dsh.app to Applications)"
