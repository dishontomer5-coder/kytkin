#!/usr/bin/env bash
# P2-4: Source lints, run by `./scripts/build.sh test` (or directly: ./scripts/lint.sh [sources-dir]).
#   1. Core import rule (design.md, 001 §2): files in Sources/Core may import only
#      Foundation, Observation, CryptoKit.
#   2. Logging rule (design.md privacy invariants, 001 §7 B12):
#      - nowhere in Sources: print, debugPrint, NSLog, dump (a shipped app has no console;
#        use os.Logger outside Keyboard/ and Text/ for non-sensitive events).
#      - in any Keyboard/, Text/ or Browser/ folder: no logging at all (no os_log, os.Logger, OSLog import),
#        because that code handles keystrokes, typed text and browser addresses (P3-6, 001 §14.3.6).
# `./scripts/lint.sh --self-test` checks that the rules still catch what they should (run by build.sh test).
# Lines whose first non-blank characters are `//` or `*` (comments) are ignored.
set -euo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.."

# P3-6: self-test. Plants one file at a time in a temp tree and checks the lint fails or passes as expected.
if [[ "${1:-}" == "--self-test" ]]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  expect() {   # expect <pass|fail> <path under Sources> <one Swift line>
    rm -rf "$tmp/Sources"
    mkdir -p "$tmp/Sources/$(dirname "$2")"
    printf '%s\n' "$3" >"$tmp/Sources/$2"
    local got=pass
    "$SELF" "$tmp/Sources" >/dev/null 2>&1 || got=fail
    if [[ "$got" != "$1" ]]; then
      echo "❌ lint self-test: expected $1 for $2: $3" >&2
      exit 1
    fi
  }
  expect fail "Core/Browser/A.swift" 'let log = Logger(subsystem: "x", category: "y")'
  expect fail "System/Browser/A.swift" 'import os'
  expect fail "System/Browser/A.swift" 'os_log("x")'
  expect fail "System/Browser/Live/A.swift" 'let l = os.Logger()'
  expect fail "Core/Keyboard/A.swift" 'let l = os.Logger()'
  expect fail "Core/Text/A.swift" 'import OSLog'
  expect fail "App/A.swift" 'print("x")'
  expect fail "Core/Browser/A.swift" 'import AppKit'
  expect pass "System/Other/A.swift" 'let log = Logger(subsystem: "x", category: "y")'
  expect pass "Core/Browser/A.swift" '// Logger( in a comment is fine'
  expect pass "Core/Browser/A.swift" 'struct SiteReader {}'
  exit 0
fi

SRC="${1:-Sources}"
ALLOWED_CORE_IMPORTS="Foundation|Observation|CryptoKit"

problems=()

# Prints "file:line:text" for non-comment Swift lines under $1 matching the ERE $2.
scan() {
  local dir="$1" pattern="$2"
  [[ -d "$dir" ]] || return 0
  find "$dir" -name '*.swift' -type f -print0 \
    | xargs -0 grep -nHE "$pattern" 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|\*)' || true
}

# 1. Core imports. Handles `import X`, `import X.Sub`, `import struct X.Y`, `@preconcurrency import X`.
IMPORT_RE='^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*'
while IFS= read -r hit; do
  [[ -z "$hit" ]] && continue
  module="$(sed -E 's/^[^:]+:[0-9]+:[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*).*$/\4/' <<<"$hit")"
  if ! [[ "$module" =~ ^($ALLOWED_CORE_IMPORTS)$ ]]; then
    problems+=("${hit%%:*}:$(cut -d: -f2 <<<"$hit"): Core may import only Foundation, Observation, CryptoKit (found '$module')")
  fi
done < <(scan "$SRC/Core" "$IMPORT_RE")

# 2a. Console printing anywhere in Sources.
PRINT_RE='(^|[^.[:alnum:]_]|Swift\.)(print|debugPrint|NSLog|dump)[[:space:]]*\('
while IFS= read -r hit; do
  [[ -z "$hit" ]] && continue
  problems+=("${hit%%:*}:$(cut -d: -f2 <<<"$hit"): no print/debugPrint/NSLog/dump in Sources (privacy, design.md)")
done < <(scan "$SRC" "$PRINT_RE")

# 2b. Any logging inside Keyboard/, Text/ and Browser/ folders (P3-6: Browser/ code sees page addresses).
LOG_RE='(^|[^.[:alnum:]_]|os\.)(os_log|os_signpost|Logger)[[:space:]]*\(|^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+(os|OSLog)([[:space:].]|$)'
while IFS= read -r dir; do
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    problems+=("${hit%%:*}:$(cut -d: -f2 <<<"$hit"): no logging in Keyboard/, Text/ or Browser/ (keystrokes, typed text, browser addresses: B12)")
  done < <(scan "$dir" "$LOG_RE")
done < <(find "$SRC" -type d \( -name Keyboard -o -name Text -o -name Browser \) 2>/dev/null)

if (( ${#problems[@]} > 0 )); then
  echo "❌ Lint failed:" >&2
  printf '%s\n' "${problems[@]}" >&2
  exit 1
fi
