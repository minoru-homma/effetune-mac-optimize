#!/usr/bin/env bash
# Build a distributable EffeTune.app (Release):
#   - universal Rust DSP dylibs (arm64 + x86_64)
#   - universal Swift app binary
#   - web UI bundled into the app (runs without EFFETUNE_WEBROOT)
#   - app icon (.icns generated from images/icon_1024x1024.png)
#   - ad-hoc codesign + a UDZO .dmg
#
# Real distribution to other Macs additionally needs Developer ID signing +
# notarization (requires an Apple Developer account); see the note at the end.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NATIVE="$REPO_ROOT/native"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$NATIVE/app/Info.plist" 2>/dev/null || echo 0.1.0)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# 1. App icon: reuse the existing build/icon.icns; else generate from a PNG.
ICNS="$NATIVE/app/icon.icns"
if [ -f "$REPO_ROOT/build/icon.icns" ]; then
  echo "[release] using build/icon.icns"
  cp "$REPO_ROOT/build/icon.icns" "$ICNS"
else
  ICON_SRC=""
  for c in images/icon_1024x1024.png images/icon_512x512.png images/icon.png build/icon.png; do
    [ -f "$REPO_ROOT/$c" ] && { ICON_SRC="$REPO_ROOT/$c"; break; }
  done
  if [ -n "$ICON_SRC" ]; then
    echo "[release] generating icon.icns from $ICON_SRC"
    ICONSET="$(mktemp -d)/icon.iconset"; mkdir -p "$ICONSET"
    for sz in 16 32 128 256 512; do
      sips -z $sz $sz "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
      sips -z $((sz*2)) $((sz*2)) "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$ICNS"
  fi
fi

# 2. Universal native DSP dylibs (build-native-dsp.js lipos installed arches).
echo "[release] building DSP dylibs"
node "$REPO_ROOT/scripts/build-native-dsp.js"

# 3. Universal Swift release binary.
echo "[release] building EffeTuneApp (release, universal)"
( cd "$NATIVE" && swift build -c release --arch arm64 --arch x86_64 --product EffeTuneApp )
BIN="$NATIVE/.build/apple/Products/Release/EffeTuneApp"
[ -f "$BIN" ] || BIN="$NATIVE/.build/release/EffeTuneApp" # fallback (single arch)

# 4. Assemble the bundle.
APP="$NATIVE/.build/EffeTune.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/dsp"
cp "$NATIVE/app/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/EffeTuneApp"
cp "$NATIVE"/dsp/*.dylib "$APP/Contents/Resources/dsp/"
[ -f "$ICNS" ] && cp "$ICNS" "$APP/Contents/Resources/icon.icns"

echo "[release] bundling web UI"
WEB="$APP/Contents/Resources/web"
mkdir -p "$WEB"
for item in effetune.html effetune.css manifest.json js plugins locales presets images; do
  [ -e "$REPO_ROOT/$item" ] && cp -R "$REPO_ROOT/$item" "$WEB/"
done

# 5. Sign (ad-hoc) the whole bundle.
echo "[release] ad-hoc codesign"
codesign --force --deep --options runtime --sign - "$APP" || echo "[release] codesign warning"
codesign --verify --deep --strict "$APP" && echo "[release] codesign OK"

echo "[release] app arch: $(lipo -archs "$APP/Contents/MacOS/EffeTuneApp" 2>/dev/null)"

# 6. DMG (app + /Applications drop target).
DMG="$NATIVE/.build/EffeTune-$VERSION.dmg"
STAGE="$(mktemp -d)/EffeTune"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "EffeTune $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "[release] -> $APP"
echo "[release] -> $DMG"
echo
echo "Note: ad-hoc signed (runs locally / right-click Open on other Macs)."
echo "For Gatekeeper-clean distribution: sign with a Developer ID certificate and"
echo "notarize (xcrun notarytool submit ... + xcrun stapler staple)."
