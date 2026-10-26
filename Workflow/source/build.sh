#!/bin/zsh
# Builds ClipHistory.app into the workflow folder from ClipboardHistory.swift and signs it ad hoc.
# With --package, also zips the workflow into dist/clipboard-history.alfredworkflow at the repo root.
set -euo pipefail
here=${0:A:h}
app=$here/../ClipHistory.app
mkdir -p "$app/Contents/MacOS"
cp "$here/Info.plist" "$app/Contents/Info.plist"
xcrun swiftc -O -swift-version 5 "$here/ClipboardHistory.swift" -o "$app/Contents/MacOS/ClipHistory"
codesign --force --sign - "$app"
if [[ ${1:-} == --package ]]; then
  dist=${here:h:h}/dist
  mkdir -p "$dist"
  rm -f "$dist/clipboard-history.alfredworkflow"
  (cd "$here/.." && zip -qry "$dist/clipboard-history.alfredworkflow" . -x '*.DS_Store')
  echo "$dist/clipboard-history.alfredworkflow"
fi
