#!/usr/bin/env bash
# P0-6: One-command build/test for Kytkin.
#   ./scripts/build.sh         generate the project and build the app (Debug)
#   ./scripts/build.sh test    generate the project, run the source lints (P2-4) and unit tests
# P2-28: Debug builds "Kytkin Dev.app", Release builds "Kytkin.app".
# P2-29: tests use their own derived data (build/test), so `test` never rebuilds or re-signs the
#        Debug app in build/Build/Products/Debug that the owner runs and has granted permissions to.
# P2-2: output is quiet. The full xcodebuild log goes to build/last-build.log.
set -euo pipefail

cd "$(dirname "$0")/.."

ACTION="${1:-build}"
CONFIG="${CONFIGURATION:-Debug}"
LOG="build/last-build.log"
if [[ "$ACTION" == "test" ]]; then DERIVED="build/test"; else DERIVED="build"; fi
case "$CONFIG" in
  Debug) PRODUCT="Kytkin Dev" ;;
  *) PRODUCT="Kytkin" ;;
esac

# P2-2: known Xcode plug-in noise that isn't about our code.
NOISE='DVTCoreDeviceCore|CoreSimulator|IDETestOperationsObserverDebug|DVTDeviceOperation|DVTPlugInManager'

case "$ACTION" in
  build|test) ;;
  *)
    echo "usage: $0 [build|test]" >&2
    exit 2
    ;;
esac

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 1
fi

# P2-1: fail early with a clear fix if xcodebuild can't find a full Xcode
# (e.g. xcode-select still points at the Command Line Tools).
if ! XCODE_VERSION="$(xcodebuild -version 2>&1)"; then
  echo "error: no working Xcode found (xcodebuild -version failed):" >&2
  echo "$XCODE_VERSION" | sed 's/^/  /' >&2
  echo "hint: install Xcode from the App Store, then run:" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

mkdir -p build "$DERIVED"
xcodegen generate --quiet >"$LOG" 2>&1 || {
  echo "❌ xcodegen generate failed:" >&2
  grep -Ev "$NOISE" "$LOG" | tail -20 >&2
  exit 1
}

# P2-2: print only the lines that explain a failure: compiler/linker errors,
# failing test assertions and test cases. Noise is filtered out.
print_failure() {
  local what="$1"
  echo "❌ $what failed." >&2
  local lines
  lines="$(grep -E "error:|: failed|Test Case .* failed|\*\* (BUILD|TEST) FAILED \*\*|Testing failed" "$LOG" \
    | grep -Ev "$NOISE" | grep -Ev '^[[:space:]]*\|' | awk '!seen[$0]++' | head -40 || true)"
  if [[ -n "$lines" ]]; then
    echo "$lines" >&2
  else
    # No recognizable error lines: show the tail so the cause isn't hidden.
    grep -Ev "$NOISE" "$LOG" | tail -20 >&2 || true
  fi
  echo "Full log: $PWD/$LOG" >&2
}

# P4-3: the Sparkle package's download never looks up GitHub credentials in the keychain (with the default
# provider xcodebuild waited there forever, headless), only ~/.netrc, which public packages don't need.
XCB=(xcodebuild -project Kytkin.xcodeproj -scheme Kytkin -configuration "$CONFIG"
     -destination 'platform=macOS' -derivedDataPath "$DERIVED" -packageAuthorizationProvider netrc)

# P2-3: dev signing. Ad-hoc signatures change on every build, so macOS forgets the
# Accessibility grant each time. A stable local certificate (KYTKIN_SIGN_IDENTITY, set in
# the environment or in the git-ignored scripts/local.env) keeps it. See the manual checklist.
if [[ -z "${KYTKIN_SIGN_IDENTITY:-}" && -f scripts/local.env ]]; then
  # shellcheck disable=SC1091
  source scripts/local.env
fi
SIGN_NOTICE=""
if [[ "$CONFIG" == "Debug" ]]; then
  if [[ -n "${KYTKIN_SIGN_IDENTITY:-}" ]]; then
    # Capture first: `security … | grep -q` can trip pipefail (SIGPIPE) when grep exits early.
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    if ! grep -qF "\"$KYTKIN_SIGN_IDENTITY\"" <<<"$IDENTITIES"; then
      echo "error: signing identity \"$KYTKIN_SIGN_IDENTITY\" (KYTKIN_SIGN_IDENTITY) not found or not trusted." >&2
      echo "hint: check with: security find-identity -v -p codesigning" >&2
      echo "      (setup steps: docs/manual-test-checklist.md, \"P2-3: Create your dev signing certificate\")" >&2
      exit 1
    fi
    XCB+=("CODE_SIGN_IDENTITY=$KYTKIN_SIGN_IDENTITY")
  else
    SIGN_NOTICE="ℹ️  Ad-hoc signed (no KYTKIN_SIGN_IDENTITY): permissions reset on each rebuild; run 'tccutil reset Accessibility io.github.kytkin.Kytkin.dev' if one looks on but doesn't work."
  fi
fi

case "$ACTION" in
  build)
    if ! "${XCB[@]}" build >>"$LOG" 2>&1; then
      print_failure "Build ($CONFIG)"
      exit 1
    fi
    APP="$PWD/$DERIVED/Build/Products/$CONFIG/$PRODUCT.app"
    echo "✅ Build succeeded ($CONFIG): $APP"
    if [[ -n "$SIGN_NOTICE" ]]; then echo "$SIGN_NOTICE"; fi
    ;;
  test)
    # P2-4: Core import + logging lints run before the tests.
    ./scripts/lint.sh
    ./scripts/lint.sh --self-test   # P3-6: the rules still catch a Logger( in a Browser/ folder, etc.
    if ! "${XCB[@]}" test >>"$LOG" 2>&1; then
      print_failure "Tests"
      exit 1
    fi
    SUMMARY="$(grep -E "Executed [0-9]+ tests?, with" "$LOG" | tail -1 | sed -E 's/^[[:space:]]+//' || true)"
    echo "✅ Tests passed: ${SUMMARY:-see log}"
    ;;
esac
