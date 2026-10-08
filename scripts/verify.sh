#!/bin/bash
# Generate one of each document with the extension's own writer and check that
# macOS recognises them as Office Open XML. Writes under /tmp, touches nothing else.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="$DEVELOPER_DIR/SDKs/MacOSX.sdk"
CLANG="$DEVELOPER_DIR/usr/bin/clang"

OUT="$(mktemp -d /tmp/finder-new-office-verify.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT

"$CLANG" -isysroot "$SDK" -fobjc-arc -mmacosx-version-min=14.0 \
  -Wno-deprecated-declarations \
  -framework Foundation -framework AppKit -framework FinderSync \
  -o "$OUT/probe" "$ROOT/src/probe/main.m"

OUTDIR="$OUT/docs" "$OUT/probe"

for f in "$OUT/docs"/*.docx "$OUT/docs"/*.xlsx "$OUT/docs"/*.pptx; do
  unzip -t "$f" >/dev/null
  textutil -info "$f" | grep -q "Office Open XML format"
  echo "ok: $(basename "$f")"
done

/usr/bin/python3 "$ROOT/scripts/verify_package.py" \
  "$OUT/docs/probe.docx" "$OUT/docs/probe.xlsx" "$OUT/docs/probe.pptx"
