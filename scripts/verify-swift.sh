#!/bin/sh
# verify-swift: the Swift daemon verification gate.
#
# Runs, in order:
#   1. the full-product release build (zero errors, zero warnings),
#   2. every `*Checks` runner,
#   3. the frame-parity replay (Rust corpus vs the Swift core) — and it
#      FAILS on `skipped`, because a silently-skipped parity check is the
#      exact failure mode this script exists to prevent.
#
# The corpus is committed at swift-daemon/Tests/FrameParityChecks/corpus/
# (dumped from the Rust trace tests). Regenerate it with:
#
#   trace="$(mktemp -d)"
#   PANERU_TRACE_OUT="$trace" cargo test --all-targets trace
#   cp "$trace"/*.jsonl swift-daemon/Tests/FrameParityChecks/corpus/
#
# Usage: scripts/verify-swift.sh [--release]
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/swift-daemon"
CORPUS="$PKG/Tests/FrameParityChecks/corpus"
BUILD_FLAGS=""
if [ "${1:-}" = "--release" ]; then
    BUILD_FLAGS="-c release"
fi

if [ ! -d "$CORPUS" ] || [ -z "$(ls -A "$CORPUS" 2>/dev/null)" ]; then
    echo "verify-swift: no corpus at $CORPUS" >&2
    echo "verify-swift: run: PANERU_TRACE_OUT=\$(mktemp -d) cargo test --all-targets trace" >&2
    exit 1
fi

echo "== build (full product list) =="
# Census the whole log: debug builds once hid 58 warnings behind a tail.
if ! swift build $BUILD_FLAGS --package-path "$PKG" > /tmp/verify-swift-build.log 2>&1; then
    cat /tmp/verify-swift-build.log
    echo "verify-swift: build failed" >&2
    exit 1
fi
if grep -E 'warning:' /tmp/verify-swift-build.log > /tmp/verify-swift-warnings.log; then
    cat /tmp/verify-swift-build.log
    echo "verify-swift: build produced warnings" >&2
    exit 1
fi
echo "build: clean"

echo "== main-confinement lint =="
# The executable's model is nonisolated(unsafe) — top-level main.swift
# storage cannot carry a global actor — and main-confined by construction.
# Off-main worker blocks (axWorker/shadowQueue) must hop back to main
# (DispatchQueue.main.async / MainActor.assumeIsolated) before touching
# those globals; a direct touch is a data race. This caught a real one
# (`deadElements`, fixed) and guards against the next. `axWorker` itself
# (the dispatch line) and `axLaneGeneration` (a documented torn-read-safe
# Int check) are exempt.
#
# Hop scope is tracked by brace depth: a global touch is legal only when
# it sits inside a hop closure. A hop in a sibling branch does not cover
# the touch. Depth only ever counts brace characters, which is exact for
# this source (no braces-in-strings on these lines).
MAIN_SWIFT="$PKG/Sources/PaneruDaemon/main.swift"
if command -v awk >/dev/null 2>&1; then
    if ! awk '
        function is_offmain(l) { return (l ~ /axWorker\.async/ || l ~ /shadowQueue\.async/) }
        function is_hop(l) { return (l ~ /DispatchQueue\.main\.async/ || l ~ /MainActor\.assumeIsolated/) }
        function braces(code,   k, ch, n) {
            n = 0
            for (k = 1; k <= length(code); k++) {
                ch = substr(code, k, 1)
                if (ch == "{") n++
                else if (ch == "}") n--
            }
            return n
        }
        /^nonisolated\(unsafe\)[[:space:]]+(var|let)[[:space:]]/ {
            name = $3; globals[name] = 1; next
        }
        {
            code = $0; sub(/\/\/.*/, "", code)
            if (!inblock && is_offmain(code)) {
                inblock = 1; depth = 0; hopdepth = -1
            }
            if (inblock) {
                # A hop opening here enters hop scope at the depth it opens.
                if (is_hop(code) && hopdepth < 0) hopdepth = depth
                if (hopdepth < 0) {
                    n = split(code, toks, /[^A-Za-z0-9_]+/)
                    for (i = 1; i <= n; i++) {
                        g = toks[i]
                        if ((g in globals) && g != "axWorker" && g != "axLaneGeneration") {
                            printf "  off-main touch: %s:%d  %s\n", FILENAME, FNR, $0
                            bad = 1
                        }
                    }
                }
                depth += braces(code)
                # Leave hop scope once we close back past where it opened.
                if (hopdepth >= 0 && depth <= hopdepth) hopdepth = -1
                if (depth <= 0) inblock = 0
            }
        }
        END { exit bad }
    ' "$MAIN_SWIFT"; then
        echo "verify-swift: off-main global touch without a main hop (see above)" >&2
        exit 1
    fi
fi
echo "confinement: clean"

echo "== checks =="
CHECK_LIST="GeometryChecks LayoutChecks AXClientChecks EventCoreChecks \
PresentationChecks PresenterChecks ScriptingChecks IPCChecks ServiceChecks \
CommandsChecks DaemonChecks XPCChecks FocusChecks WorkspaceChecks \
ConfigChecks KeyChordsChecks SnippetChecks ProviderChecks WorkerChecks \
DisplaysChecks SessionChecks SkyBridgeChecks WindowSetChecks \
StateQueryChecks LuaAPIChecks ConfigFilesChecks ScriptHostChecks \
ScriptEventsChecks LuaBridgeChecks MenuBarChecks LiveProvidersChecks \
AnimationChecks ScrollChecks"
for checks in $CHECK_LIST; do
    if ! out="$(PANERU_TRACE_DIR="$CORPUS" swift run $BUILD_FLAGS --package-path "$PKG" "$checks" 2>&1)"; then
        echo "$out"
        echo "verify-swift: $checks failed" >&2
        exit 1
    fi
    # Require the runner's own verdict as its final line: every runner ends
    # with "<Name>: all checks passed", and a skipped runner does not. This
    # rejects skips without false-positiving on test log text (DaemonChecks
    # legitimately prints "reveal skipped window=…").
    if [ "$(echo "$out" | tail -1)" != "$checks: all checks passed" ]; then
        echo "$out"
        echo "verify-swift: $checks did not report success (skipped or partial)" >&2
        exit 1
    fi
done
echo "checks: $CHECK_LIST" | tr '\n' ' '; echo

echo "== frame parity =="
if ! out="$(PANERU_TRACE_DIR="$CORPUS" swift run $BUILD_FLAGS --package-path "$PKG" FrameParityChecks 2>&1)"; then
    echo "$out"
    echo "verify-swift: FrameParityChecks failed" >&2
    exit 1
fi
if ! echo "$out" | tail -1 | grep -q 'FrameParityChecks: all checks passed'; then
    echo "$out"
    echo "verify-swift: frame parity did not pass" >&2
    exit 1
fi
echo "$out" | tail -1

echo "verify-swift: OK"
