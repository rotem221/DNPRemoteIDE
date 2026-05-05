#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v swiftformat >/dev/null 2>&1; then
  swiftformat .
else
  echo "swiftformat not installed. brew install swiftformat to enable."
fi

if command -v swiftlint >/dev/null 2>&1; then
  swiftlint
else
  echo "swiftlint not installed. brew install swiftlint to enable."
fi
