#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -d apps/DNPRemoteMac/DNPRemoteMac.xcodeproj ]; then
  echo "Mac project not generated. Run ./scripts/bootstrap.sh first." >&2
  exit 1
fi

xcodebuild -project apps/DNPRemoteMac/DNPRemoteMac.xcodeproj \
           -scheme DNPRemoteMac \
           -configuration Debug \
           -destination 'platform=macOS' \
           build
