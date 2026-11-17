#!/usr/bin/env bash
# P2-4: Source lints, run by `./scripts/build.sh test` (or directly: ./scripts/lint.sh [sources-dir]).
#   1. Core import rule (design.md, 001 §2): files in Sources/Core may import only
#      Foundation, Observation, CryptoKit.
#   2. Logging rule (design.md privacy invariants, 001 §7 B12):
#      - nowhere in Sources: print, debugPrint, NSLog, dump (a shipped app has no console).
#      - P3-65 (P3-18 audit L2): no logging at all (os_log, os_signpost, Logger, `import os` / `import OSLog`)
#        anywhere in Sources except the one allowlisted file, App/ConvertDiagnosticsLog.swift (the DEBUG convert
#        trace), and there every Logger( line must sit inside `#if DEBUG` (before its `#else` / `#endif`).
#        Was: only Keyboard/, Text/ and Browser/ folders (P3-6); text and hosts also pass through Controllers/,
#        Context/, App/ and UI/.
#   3. P6-3: network (CLAUDE.md: the only network call is the optional update check): URLSession, NWConnection,
#      CFNetwork / Network imports and raw sockets only in Sources/System/Network/.
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
  # P3-65 (audit L2): everywhere now, not only Keyboard/ Text/ Browser/.
  expect fail "System/Other/A.swift" 'let log = Logger(subsystem: "x", category: "y")'
  expect fail "Core/Controllers/A.swift" 'let log = Logger(subsystem: "x", category: "y")'
  expect fail "Core/Context/A.swift" 'import os'
  expect fail "UI/A.swift" 'os_log("x")'
  expect fail "App/A.swift" 'import OSLog'
  expect pass "App/ConvertDiagnosticsLog.swift" $'import os\n#if DEBUG\nlet l = Logger(subsystem: "x", category: "y")\n#else\nlet l: Int? = nil\n#endif'
  expect fail "App/ConvertDiagnosticsLog.swift" 'let l = Logger(subsystem: "x", category: "y")'
  expect fail "App/ConvertDiagnosticsLog.swift" $'#if DEBUG\n#else\nlet l = Logger(subsystem: "x", category: "y")\n#endif'
  expect fail "App/Other/ConvertDiagnosticsLog.swift" $'#if DEBUG\nlet l = Logger()\n#endif'
  # P6-3: the network only from System/Network/.
  expect fail "Core/Updates/A.swift" 'let s = URLSession.shared'
  expect fail "UI/A.swift" 'import Network'
  expect fail "App/A.swift" 'let c = NWConnection(host: "x", port: 1, using: .tcp)'
  expect pass "System/Network/A.swift" 'let s = URLSession(configuration: .ephemeral)'
  expect fail "Core/A.swift" 'let c = NSURLConnection(request: r, delegate: nil)'
  expect pass "Core/Browser/A.swift" '// Logger( in a comment is fine'
  expect pass "Core/Browser/A.swift" 'struct SiteReader {}'
  # P6-0c QA: a SwiftUI view interpolated into a string renders its debug description ("Image(provider: ...)").
  expect fail "UI/A.swift" 'Text("Look for \(Image(systemName: "k")) " + "x")'
  expect fail "UI/A.swift" 'let s = "a \(Text("b"))"'
  expect pass "UI/A.swift" 'Text("Look for ") + Text(Image(systemName: "k"))'
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

# 2b. P3-65 (audit L2): any logging anywhere in Sources, except the allowlisted DEBUG trace file.
LOG_RE='(^|[^.[:alnum:]_]|os\.)(os_log|os_signpost|Logger)[[:space:]]*\(|^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+(os|OSLog)([[:space:].]|$)'
LOG_ALLOWED="$SRC/App/ConvertDiagnosticsLog.swift"
while IFS= read -r hit; do
  [[ -z "$hit" ]] && continue
  [[ "${hit%%:*}" == "$LOG_ALLOWED" ]] && continue
  problems+=("${hit%%:*}:$(cut -d: -f2 <<<"$hit"): no logging in Sources except App/ConvertDiagnosticsLog.swift (keystrokes, typed text, addresses: B12)")
done < <(scan "$SRC" "$LOG_RE")
# The allowlisted file: every Logger( / os_log( line inside `#if DEBUG`, before its `#else` / `#endif`.
if [[ -f "$LOG_ALLOWED" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    problems+=("$LOG_ALLOWED:$line: a Logger in ConvertDiagnosticsLog.swift must be inside #if DEBUG (Release logs nothing)")
  done < <(awk '
    /^[[:space:]]*(\/\/|\*)/ { next }
    /^[[:space:]]*#if[[:space:]]+DEBUG/ { debug = 1; next }
    /^[[:space:]]*#(else|endif)/ { debug = 0; next }
    /(^|[^.[:alnum:]_]|os\.)(os_log|os_signpost|Logger)[[:space:]]*\(/ { if (!debug) print NR }
  ' "$LOG_ALLOWED")
fi

# 3. P6-0c QA: never a SwiftUI view inside a string interpolation (`"\\(Image(...))"`, `"\\(Text(...))"`): in a plain
#    String it renders the view's debug description. Use `Text(...) + Text(Image(...))`.
VIEW_INTERP_RE='\\\((Image|Text|Label|Button|HStack|VStack|ZStack)[[:space:]]*\('
while IFS= read -r hit; do
  [[ -z "$hit" ]] && continue
  problems+=("${hit%%:*}:$(cut -d: -f2 <<<"$hit"): a SwiftUI view inside a string interpolation (use Text + Text(Image(...)))")
done < <(scan "$SRC" "$VIEW_INTERP_RE")

# 3. P6-3: the network only from Sources/System/Network/ (the update check's one client).
NET_RE='(^|[^.[:alnum:]_])(URLSession|NSURLConnection|NWConnection|NWPathMonitor|NWBrowser|NWListener|CFStream|CFSocket|CFHTTP)[[:alnum:]_]*[[:space:].(]|^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+(Network|CFNetwork)([[:space:].]|$)|(^|[^.[:alnum:]_])socket[[:space:]]*\('
while IFS= read -r hit; do
  [[ -z "$hit" ]] && continue
  [[ "${hit%%:*}" == "$SRC/System/Network/"* ]] && continue
  problems+=("${hit%%:*}:$(cut -d: -f2 <<<"$hit"): network code only in System/Network/ (the optional update check)")
done < <(scan "$SRC" "$NET_RE")

if (( ${#problems[@]} > 0 )); then
  echo "❌ Lint failed:" >&2
  printf '%s\n' "${problems[@]}" >&2
  exit 1
fi
