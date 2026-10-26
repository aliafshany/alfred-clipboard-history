#!/bin/zsh
# Builds ClipHistory.app into the workflow folder from ClipboardHistory.swift and signs it ad hoc.
# With --package, also zips the workflow into dist/clipboard-history.alfredworkflow at the repo root.
set -euo pipefail
here=${0:A:h}
app=$here/../ClipHistory.app
mkdir -p "$app/Contents/MacOS"
cp "$here/Info.plist" "$app/Contents/Info.plist"
# Without -target, swiftc builds for the macOS it runs on, so pin it to LSMinimumSystemVersion and build for Intel too.
min=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$here/Info.plist")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for arch in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target $arch-apple-macos$min "$here/ClipboardHistory.swift" -o "$tmp/$arch"
done
lipo -create "$tmp/arm64" "$tmp/x86_64" -output "$app/Contents/MacOS/ClipHistory"
codesign --force --sign - "$app"
if [[ ${1:-} == --package ]]; then
  dist=${here:h:h}/dist
  mkdir -p "$dist"
  rm -f "$dist/clipboard-history.alfredworkflow"
  (cd "$here/.." && zip -qry "$dist/clipboard-history.alfredworkflow" . -x '*.DS_Store')
  echo "$dist/clipboard-history.alfredworkflow"
fi
