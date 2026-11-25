#!/bin/bash
# Builds OmniFetch.app from the Swift package.
# Set UNIVERSAL=1 (or pass --universal) to produce an arm64 + x86_64 universal bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="OmniFetch"
GUI_PRODUCT="OmniFetchGUI"
VERSION="${VERSION:-1.0.0}"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
CONFIG="release"
UNIVERSAL="${UNIVERSAL:-0}"

for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    debug|release) CONFIG="$arg" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

cd "$ROOT"

ARCH_FLAGS=()
if [[ "$UNIVERSAL" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
  echo "==> swift build -c $CONFIG --arch arm64 --arch x86_64 --product $GUI_PRODUCT"
else
  echo "==> swift build -c $CONFIG --product $GUI_PRODUCT"
fi

swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --product "$GUI_PRODUCT"

BIN="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)/$GUI_PRODUCT"
if [[ ! -x "$BIN" ]]; then
  echo "binary not found: $BIN" >&2
  exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>OmniFetch</string>
    <key>CFBundleIdentifier</key><string>com.omnifetch.app</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>OmniFetch</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> icon"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
swift "$ROOT/scripts/make_icon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> codesign (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

echo "==> verify"
lipo -info "$APP/Contents/MacOS/$APP_NAME"
"$APP/Contents/MacOS/$APP_NAME" --selftest | tail -3

echo "Built: $APP"
echo "Run:   open \"$APP\""
