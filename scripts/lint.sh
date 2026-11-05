#!/usr/bin/env bash
# P2-4: Source lints, run by `./scripts/build.sh test` (or directly: ./scripts/lint.sh [sources-dir]).
#   1. Core import rule (design.md, 001 §2): files in Sources/Core may import only
#      Foundation, Observation, CryptoKit.
#   2. Logging rule (design.md privacy invariants, 001 §7 B12):
#      - nowhere in Sources: print, debugPrint, NSLog, dump (a shipped app has no console;
#        use os.Logger outside Keyboard/ and Text/ for non-sensitive events).
#      - in any Keyboard/ or Text/ folder: no logging at all (no os_log, os.Logger, OSLog import),
#        because that code handles keystrokes and typed text.
# Lines whose first non-blank characters are `//` or `*` (comments) are ignored.
set -euo pipefail

cd "$(dirname "$0")/.."
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

# 2b. Any logging inside Keyboard/ and Text/ folders.
LOG_RE='(^|[^.[:alnum:]_]|os\.)(os_log|os_signpost|Logger)[[:space:]]*\(|^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+(os|OSLog)([[:space:].]|$)'
while IFS= read -r dir; do
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    problems+=("${hit%%:*}:$(cut -d: -f2 <<<"$hit"): no logging in Keyboard/ or Text/ (keystrokes and typed text, B12)")
  done < <(scan "$dir" "$LOG_RE")
done < <(find "$SRC" -type d \( -name Keyboard -o -name Text \) 2>/dev/null)

if (( ${#problems[@]} > 0 )); then
  echo "❌ Lint failed:" >&2
  printf '%s\n' "${problems[@]}" >&2
  exit 1
fi
