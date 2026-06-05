#!/usr/bin/env bash
# Assemble EffeTune.app from the built Swift binary, the native DSP dylibs, and
# (optionally) the web UI. Ad-hoc codesigns so it runs locally and so the
# microphone TCC prompt can attribute to a stable bundle id.
#
# Usage:
#   native/app/make-app.sh [--release] [--bundle-web]
#
# Dev: omit --bundle-web and launch with EFFETUNE_WEBROOT pointing at the repo.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NATIVE="$REPO_ROOT/native"
CONFIG="debug"
BUNDLE_WEB=0
for a in "$@"; do
  case "$a" in
    --release) CONFIG="release" ;;
    --bundle-web) BUNDLE_WEB=1 ;;
  esac
done

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "[make-app] building DSP dylibs"
node "$REPO_ROOT/scripts/build-native-dsp.js"

echo "[make-app] building EffeTuneApp ($CONFIG)"
( cd "$NATIVE" && swift build -c "$CONFIG" --product EffeTuneApp )
BIN="$NATIVE/.build/$CONFIG/EffeTuneApp"

APP="$NATIVE/.build/EffeTune.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/dsp"
cp "$NATIVE/app/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/EffeTuneApp"
cp "$NATIVE"/dsp/*.dylib "$APP/Contents/Resources/dsp/"
# App icon (Info.plist references CFBundleIconFile = icon.icns).
[ -f "$NATIVE/app/icon.icns" ] && cp "$NATIVE/app/icon.icns" "$APP/Contents/Resources/icon.icns"

if [ "$BUNDLE_WEB" = "1" ]; then
  echo "[make-app] bundling web UI"
  WEB="$APP/Contents/Resources/web"
  mkdir -p "$WEB"
  for item in effetune.html effetune.css manifest.json js plugins locales presets images; do
    [ -e "$REPO_ROOT/$item" ] && cp -R "$REPO_ROOT/$item" "$WEB/"
  done
fi

echo "[make-app] ad-hoc codesign"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "[make-app] codesign skipped"

echo "[make-app] -> $APP"
echo "Run (dev, UI from repo):"
echo "  EFFETUNE_WEBROOT=\"$REPO_ROOT\" open \"$APP\""
