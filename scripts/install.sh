#!/bin/bash
# Install the built app into ~/Applications and enable its Finder extension.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/FinderNewOffice.app"
DEST="$HOME/Applications/FinderNewOffice.app"
EXT_ENTITLEMENTS="$ROOT/build/FinderNewOffice-extension.entitlements"

[ -d "$SRC" ] && [ -f "$EXT_ENTITLEMENTS" ] || { echo "run scripts/build.sh first"; exit 1; }

# Refuse to replace anything that is not our own bundle.
if [ -d "$DEST" ]; then
  id="$(defaults read "$DEST/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || true)"
  [ "$id" = "local.xiaohan.FinderNewOffice" ] || { echo "refusing: $DEST is not ours ($id)"; exit 2; }
  rm -rf "$DEST"
fi

mkdir -p "$HOME/Applications"
cp -R "$SRC" "$DEST"
# Reuse the build-generated Desktop permission when signing the installed copy.
codesign --force --sign - --entitlements "$EXT_ENTITLEMENTS" \
  "$DEST/Contents/PlugIns/FinderNewOffice.appex"
codesign --force --sign - --entitlements "$ROOT/src/app/FinderNewOffice.entitlements" "$DEST"
codesign --verify --deep --strict "$DEST"

LS="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LS" -f -R -trusted "$DEST"
pluginkit -a "$DEST/Contents/PlugIns/FinderNewOffice.appex" >/dev/null 2>&1 || true
uuid="$(pluginkit -m -i local.xiaohan.FinderNewOffice.FinderSync -v | awk 'NR==1{print $2}')"
[ -n "$uuid" ] || { echo "extension registration failed; enable it in System Settings"; exit 3; }
pluginkit -e use -u "$uuid"
killall Finder || true

echo "installed and enabled: $DEST"
echo "right-click empty space inside a Finder window; the item sits at the bottom of the menu"
