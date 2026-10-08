#!/bin/bash
# Build FinderNewOffice.app from source using only the Command Line Tools.
# No Xcode project, no paid developer account: the result is ad-hoc signed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src"
BUILD="$ROOT/build"
APP="$BUILD/FinderNewOffice.app"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="$DEVELOPER_DIR/SDKs/MacOSX.sdk"
CLANG="$DEVELOPER_DIR/usr/bin/clang"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/PlugIns/FinderNewOffice.appex/Contents/MacOS"

# Generate the Desktop permission for the person building the app. Keep local
# absolute paths in ignored build output, never in the public source tree.
EXT_ENTITLEMENTS="$BUILD/FinderNewOffice-extension.entitlements"
cp "$SRC/extension/FinderNewOffice.entitlements" "$EXT_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.temporary-exception.files.absolute-path.read-write array" "$EXT_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.temporary-exception.files.absolute-path.read-write:0 string $HOME/Desktop/" "$EXT_ENTITLEMENTS"

cp "$SRC/app/Info.plist" "$APP/Contents/Info.plist"
cp "$SRC/extension/Info.plist" "$APP/Contents/PlugIns/FinderNewOffice.appex/Contents/Info.plist"

"$CLANG" -isysroot "$SDK" -fobjc-arc -mmacosx-version-min=14.0 \
  -framework AppKit -framework Foundation \
  -o "$APP/Contents/MacOS/FinderNewOffice" \
  "$SRC/app/main.m"

"$CLANG" -isysroot "$SDK" -fobjc-arc -mmacosx-version-min=14.0 \
  -fapplication-extension -Wno-deprecated-declarations \
  -framework AppKit -framework Foundation -framework FinderSync \
  -e _NSExtensionMain \
  -o "$APP/Contents/PlugIns/FinderNewOffice.appex/Contents/MacOS/FinderNewOffice" \
  "$SRC/extension/NewDocSync.m"

codesign --force --sign - --entitlements "$EXT_ENTITLEMENTS" \
  "$APP/Contents/PlugIns/FinderNewOffice.appex"
codesign --force --sign - --entitlements "$SRC/app/FinderNewOffice.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

echo "built: $APP"
