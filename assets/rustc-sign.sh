#!/bin/sh
# Transparent rustc wrapper (wired up via `.cargo/config.toml`
# `build.rustc-wrapper`).
#
# Ad-hoc-signs the final `paneru` binary with a STABLE identifier. Without
# this, every rebuild gets a synthesized per-build signing identity, and
# macOS TCC (Accessibility) grants key off that identity — so each rebuild
# silently voided the grant and paneru parked in the menu bar. Everything
# else (dependencies, build scripts, test harnesses, non-macOS hosts)
# passes straight through to rustc untouched.
set -u

RUSTC_BIN="$1"
shift

on_macos=0
if command -v uname >/dev/null 2>&1 && [ "$(uname -s)" = "Darwin" ]; then
    on_macos=1
fi

out_dir=""
crate_name=""
crate_type=""
extra_filename=""
test_only=0
prev=""
for arg in "$@"; do
    case "$prev" in
        --out-dir) out_dir="$arg" ;;
        --crate-name) crate_name="$arg" ;;
        --crate-type) crate_type="$arg" ;;
    esac
    case "$arg" in
        --out-dir | --crate-name | --crate-type) prev="$arg" ;;
        --test) test_only=1; prev="" ;;
        -C) prev="-C" ;;
        *)
            if [ "$prev" = "-C" ]; then
                case "$arg" in
                    extra-filename=*) extra_filename="${arg#extra-filename=}" ;;
                esac
            fi
            prev=""
            ;;
    esac
done

"$RUSTC_BIN" "$@"
status=$?
# NOTE: sccache is intentionally NOT chained here. It only pays off for cold
# builds and branch switches, while the incremental loop (this repo's hot
# path) is served by cargo's own incremental cache — sccache would just add
# hashing overhead per unit. For cold builds set `RUSTC_WRAPPER=sccache`
# explicitly (env overrides this script per `.cargo/config.toml`), then
# re-sign with `codesign --force --sign - --identifier
# com.github.karinushka.paneru target/debug/paneru` as CI does.
if [ "$status" -ne 0 ]; then
    exit "$status"
fi

# Only the final binary, never test harnesses or metadata-only runs.
if [ "$on_macos" -ne 1 ] \
    || [ "$crate_name" != "paneru" ] \
    || [ "$crate_type" != "bin" ] \
    || [ "$test_only" -ne 0 ] \
    || [ -z "$out_dir" ]; then
    exit 0
fi

bin="$out_dir/$crate_name$extra_filename"
if [ ! -f "$bin" ]; then
    exit 0
fi

if ! command -v codesign >/dev/null 2>&1; then
    echo "rustc-sign: codesign not found, leaving $bin unsigned" >&2
    exit 0
fi

exec codesign --force --sign - \
    --identifier com.github.karinushka.paneru \
    "$bin"
