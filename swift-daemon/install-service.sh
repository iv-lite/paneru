#!/bin/sh
# Install (or remove) the paneru-swift launchd agent.
#
#   swift-daemon/install-service.sh install   - build, sign, install, start
#   swift-daemon/install-service.sh uninstall - stop, remove
#   swift-daemon/install-service.sh start     - start an installed agent
#   swift-daemon/install-service.sh stop      - stop a running agent
#
# Per-user agent (never a system daemon: AX grants and config live in the
# login session). Swift identity only — the Rust agent
# (`com.github.karinushka.paneru`, no suffix) is never touched.
#
# Signing: ad-hoc `codesign -s -` embeds a cdhash-only designated
# requirement, so every rebuild looks like a new app to TCC and voids the
# Accessibility grant (the earlier "stable identifier" claim was wrong —
# the identifier is not part of an ad-hoc DR). Sign with a persistent
# identity instead, resolved via the sibling installer's
# `ensure-signing-identity` when present, else the "Paneru Local" cert
# directly, so grants survive rebuilds. Override with
# $PANERU_SIGN_IDENTITY (or force ad-hoc with "-").
set -eu

LABEL="com.github.iv-lite.paneru-swift"
IDENTIFIER="com.github.iv-lite.paneru-swift"
# Previous Swift label: one-time migration below stops it and removes
# its plist/logs on install. The Rust label is not matched.
OLD_LABEL="com.github.karinushka.paneru.swift"
BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/paneru-swift"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_LOG="/tmp/${LABEL}_${UID_NUM}.out.log"
ERR_LOG="/tmp/${LABEL}_${UID_NUM}.err.log"
XDG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
# Sibling installer's helper (creates/reads the "Paneru Local" identity).
ENSURE_IDENTITY="$ROOT/../rift-wm-installer/scripts/ensure-signing-identity"

# Resolve the code-signing identity. Order: explicit $PANERU_SIGN_IDENTITY,
# the sibling helper, then the "Paneru Local" cert directly in the login
# keychain. "-" means ad-hoc (grants will not survive rebuilds).
resolve_sign_identity() {
    if [ -n "${PANERU_SIGN_IDENTITY:-}" ]; then
        echo "$PANERU_SIGN_IDENTITY"
        return 0
    fi
    if [ -f "$ENSURE_IDENTITY" ]; then
        bash "$ENSURE_IDENTITY" 2>/dev/null || echo "-"
        return 0
    fi
    if command -v security >/dev/null 2>&1 \
        && security find-identity -v -p codesigning 2>/dev/null | grep -qF "Paneru Local"; then
        echo "Paneru Local"
        return 0
    fi
    echo "-"
}

bootstrapped() {
    launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1
}

do_install() {
    # Migrate the previous Swift label once: stop it and remove its
    # plist/logs so two Swift agents never overlap. Rust (unsuffixed)
    # is out of scope and keeps running.
    if launchctl print "gui/$UID_NUM/$OLD_LABEL" >/dev/null 2>&1; then
        launchctl bootout "gui/$UID_NUM" "$HOME/Library/LaunchAgents/$OLD_LABEL.plist" 2>/dev/null || \
            launchctl kill SIGTERM "gui/$UID_NUM/$OLD_LABEL" 2>/dev/null || true
        echo "migrated away from $OLD_LABEL"
    fi
    rm -f "$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
    rm -f "/tmp/${OLD_LABEL}_${UID_NUM}.out.log" "/tmp/${OLD_LABEL}_${UID_NUM}.err.log"
    # One product per invocation: swift build silently honors only the
    # last --product flag. Bin dir resolves via --show-bin-path so the
    # script tracks whatever layout the active toolchain uses.
    swift build -c release --package-path "$ROOT/swift-daemon" \
        --product paneru-swift
    swift build -c release --package-path "$ROOT/swift-daemon" \
        --product RenderPlist
    BIN_PATH="$(swift build -c release --package-path "$ROOT/swift-daemon" \
        --show-bin-path)"
    mkdir -p "$BIN_DIR" "$HOME/Library/LaunchAgents"
    install -m755 "$BIN_PATH/paneru-swift" "$BIN"
    SIGN_IDENTITY="$(resolve_sign_identity)"
    codesign --force --sign "$SIGN_IDENTITY" --identifier "$IDENTIFIER" "$BIN"
    if [ "$SIGN_IDENTITY" = "-" ]; then
        echo "warning: ad-hoc signed — the Accessibility grant will not" >&2
        echo "  survive the next rebuild; run the sibling installer's" >&2
        echo "  scripts/ensure-signing-identity to fix." >&2
    else
        echo "signed with stable identity '$SIGN_IDENTITY'"
    fi
    "$BIN_PATH/RenderPlist" \
        "$LABEL" "$BIN" "$OUT_LOG" "$ERR_LOG" "$XDG_HOME" > "$PLIST"
    touch "$OUT_LOG" "$ERR_LOG"
    echo "installed $BIN and $PLIST"
}

do_start() {
    if [ ! -f "$PLIST" ]; then
        do_install
    fi
    launchctl enable "gui/$UID_NUM/$LABEL" 2>/dev/null || true
    if bootstrapped; then
        launchctl kickstart "gui/$UID_NUM/$LABEL"
    else
        launchctl bootstrap "gui/$UID_NUM" "$PLIST"
    fi
    echo "started $LABEL"
}

do_stop() {
    if bootstrapped; then
        launchctl bootout "gui/$UID_NUM" "$PLIST" 2>/dev/null || \
            launchctl kill SIGTERM "gui/$UID_NUM/$LABEL" 2>/dev/null || true
        echo "stopped $LABEL"
    else
        echo "$LABEL is not running"
    fi
}

case "${1-install}" in
    install) do_install; do_start ;;
    uninstall) do_stop || true; rm -f "$PLIST"; echo "removed $PLIST" ;;
    start) do_start ;;
    stop) do_stop ;;
    *) echo "usage: $0 [install|uninstall|start|stop]" >&2; exit 1 ;;
esac
