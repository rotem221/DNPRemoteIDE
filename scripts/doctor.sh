#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/.."
ok=0; fail=0
status() {
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then
    printf "  ✅ %s\n" "$name"; ok=$((ok+1))
  else
    printf "  ❌ %s\n" "$name"; fail=$((fail+1))
  fi
}

echo "▶︎ DNP Remote IDE — doctor"
echo
echo "Tooling:"
status "swift"               command -v swift
status "xcodegen"            command -v xcodegen
status "claude (Claude Code)" command -v claude
echo
echo "Repo state:"
status "DNPShared/Package.swift exists"             test -f Packages/DNPShared/Package.swift
status "Mac project.yml exists"                     test -f apps/DNPRemoteMac/project.yml
status "Mac Xcode project generated"                test -d apps/DNPRemoteMac/DNPRemoteMac.xcodeproj
status "hook-relay binary built"                    test -x tools/dnp-hook-relay/dnp-hook-relay
status ".claude/settings.json present"              test -f .claude/settings.json
echo
echo "Claude Code probe:"
if command -v claude >/dev/null 2>&1; then
  claude --version 2>/dev/null | sed 's/^/  /' || echo "  (no version output)"
else
  echo "  claude not on PATH — install per https://docs.claude.com/en/docs/claude-code/overview"
fi
echo
echo "Summary: $ok ok, $fail problems"
exit $fail
