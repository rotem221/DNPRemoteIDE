#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "▶︎ DNP Remote IDE — bootstrap"
echo

# 1. xcodegen
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "• xcodegen not found — installing via Homebrew"
  if ! command -v brew >/dev/null 2>&1; then
    echo "  Homebrew is required. Install it from https://brew.sh and re-run." >&2
    exit 1
  fi
  brew install xcodegen
fi

# 2. Build hook-relay (so the binary exists before Claude is launched)
echo "• Building dnp-hook-relay"
pushd tools/dnp-hook-relay >/dev/null
swift build -c release
ln -sf .build/release/dnp-hook-relay dnp-hook-relay
popd >/dev/null

# 3. Resolve / build shared package
echo "• Resolving DNPShared dependencies"
pushd Packages/DNPShared >/dev/null
swift package resolve
popd >/dev/null

# 4. Per-developer signing override. xcodegen-generated projects
#    consume Local.xcconfig for DEVELOPMENT_TEAM, which is gitignored.
#    Seed it from the sample on first run so signed local builds work
#    without each contributor having to find the file by hand.
if [[ ! -f apps/DNPRemoteMac/Local.xcconfig && -f apps/DNPRemoteMac/Local.sample.xcconfig ]]; then
  echo "• Seeding apps/DNPRemoteMac/Local.xcconfig from sample"
  echo "  (edit it to put your Apple DEVELOPMENT_TEAM in place)"
  cp apps/DNPRemoteMac/Local.sample.xcconfig apps/DNPRemoteMac/Local.xcconfig
fi

# 5. Generate Mac project
echo "• Generating Mac Xcode project"
pushd apps/DNPRemoteMac >/dev/null
xcodegen generate
popd >/dev/null

echo
echo "✅ Bootstrap complete."
echo
echo "Next:"
echo "  open apps/DNPRemoteMac/DNPRemoteMac.xcodeproj"
echo "  ./scripts/doctor.sh"
