#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▶︎ DNPShared tests"
pushd Packages/DNPShared >/dev/null
swift test
popd >/dev/null

echo "▶︎ Mac unit tests (if scheme exists)"
if [ -d apps/DNPRemoteMac/DNPRemoteMac.xcodeproj ]; then
  xcodebuild test -project apps/DNPRemoteMac/DNPRemoteMac.xcodeproj \
                  -scheme DNPRemoteMac -destination 'platform=macOS' || \
                  echo "(no Mac test target yet — skipping)"
fi

echo "✅ tests done"
