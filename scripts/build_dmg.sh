#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64) OmniFetch.app and packages it into a distributable DMG.
# Pass --install to also copy OmniFetch.app into /Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="OmniFetch"
VERSION="${VERSION:-1.0.0}"
BUILD_DIR="$ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
STAGE_DIR="$BUILD_DIR/dmg-stage"
DMG_NAME="${APP_NAME}-${VERSION}-universal.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
SHA_PATH="$BUILD_DIR/SHA256SUMS.txt"
INSTALL_LOCAL=0

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL_LOCAL=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

VERSION="$VERSION" "$ROOT/scripts/build_app.sh" release --universal

echo "==> staging DMG content"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
ditto "$APP_BUNDLE" "$STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"

echo "==> creating $DMG_NAME"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  -fs HFS+ \
  "$DMG_PATH" >/dev/null

rm -rf "$STAGE_DIR"

echo "==> verifying DMG mount"
MOUNT_DIR="$(mktemp -d /tmp/omnifetch-dmg.XXXXXX)"
cleanup() {
  hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
  rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT
hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_DIR" -nobrowse -readonly -quiet
test -x "$MOUNT_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME"
test -f "$MOUNT_DIR/$APP_NAME.app/Contents/Resources/AppIcon.icns"
test -L "$MOUNT_DIR/Applications"
hdiutil detach "$MOUNT_DIR" -quiet
rmdir "$MOUNT_DIR"
trap - EXIT

(cd "$BUILD_DIR" && shasum -a 256 "$DMG_NAME") | tee "$SHA_PATH"

if [[ "$INSTALL_LOCAL" == "1" ]]; then
  echo "==> installing to /Applications/$APP_NAME.app"
  rm -rf "/Applications/$APP_NAME.app"
  ditto "$APP_BUNDLE" "/Applications/$APP_NAME.app"
  codesign --verify --deep --strict "/Applications/$APP_NAME.app"
  echo "Installed: /Applications/$APP_NAME.app"
fi

du -sh "$APP_BUNDLE" "$DMG_PATH"
echo "Built: $DMG_PATH"
