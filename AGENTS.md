# Agent Instructions: Paneru macOS Window Manager (Swift daemon)

This document provides project-specific guidance for AI agents contributing to Paneru. The daemon is `swift-daemon/` (product `paneru-swift`); the Rust daemon was removed and its trace corpus frozen as the parity gate's truth.

## 0. Required Skill (load first)

Load these before any Paneru work — they are normative and override conflicting defaults:

* `paneru-swift` — for any change under `swift-daemon/`. NOTE: the skill text still describes the deleted `overlay-swift/` C ABI (`overlay-swift/ABI.swift`, `PANERU_SWIFT_OVERLAY`, `OVERLAY_ABI_VERSION`); current Swift truth is `swift-daemon/Sources/{Daemon,Layout,Presenter,LiveProviders}/` per `ARCHITECTURE.md §8`. Follow the repo, not stale skill paths.

There is no Rust in this repo: no `src/`, no `Cargo.toml`, no `cargo` gate. Do not run or reference `cargo`/`cargo fmt`/`clippy`/`cargo test`.

## 1. Swift Daemon Architecture

* **`DaemonCore`** (`Sources/Daemon/Daemon.swift`) is the serial assembly: `ingest → layout → commit → paint` per 60Hz tick against injected frame providers and per-workspace viewports.
* **Pure modules** (no AppKit, unit-pinned by checks): `Geometry` (rect math, clamps, CG↔Cocoa), `Layout` (`LayoutStrip`/`Column`/`StackItem`, `binpackHeights`), `Focus`, `Animation`/`Scroll`, `Config` (resolve/clamp/decode), `EventCore`, `Session`, plus `Commands`, `Workspace`, `StateQuery`, `Scripting`/`LuaBridge`, `IPC`/`PaneruXPC`.
* **Live host seams** (permissioned Mac only): `LiveProviders` (AX reads/writes/observers, tap, writer coalescing), `Presenter` (borders/dim/flash/drop-preview), `MenuBar`, `Service`, `PaneruDaemon/main.swift` (roster, observers, tick, job application, XPC, Lua host loop, `install-service.sh` launchd bundle).
* **Value types + `Sendable` by default** everywhere; new modules must be v6-clean.

## 2. macOS & AppKit Integration

* **Main-Thread Confinement:** All AppKit/CoreGraphics/AX calls MUST happen on the main thread. Plain `Send` data crosses the AX-worker boundary.
* **Swift 6 (`swiftLanguageModes: [.v6]`, complete checking on):** the checker is satisfied structurally — `nonisolated(unsafe)` vouches main-confined globals (audit thread-affinity, not the annotation), Sendable boxes carry cross-lane state, `@unchecked Sendable` only where lane confinement makes it true, `MainActor.assumeIsolated` at AppKit call sites that cannot move. Never regress to warning-silencing flags.
* **Top-level init order (`main.swift`):** top-level state initializes in source order — declare before first use. A global read before its declaration executes against zeroed storage: harmless for plain structs/ints, but an instant `EXC_BAD_ACCESS` for reference payloads. This crashed the process repeatedly with misleading stacks. Keep ALL top-level `var`/`let` storage above the first statement that reads it; functions may live anywhere.
* **The Lua worker:** runs on its own thread — handlers are user code of unbounded duration and must never stall the tick. Only plain `Send` data crosses (script-state writes round-trip for their ack; nothing else). Main-thread-only FFI reachable from scripts must be computed on the main thread and cached.

## 3. Layout & Workspace Logic (normative invariants — mirror the Rust era, do not redesign)

* **Slots always abut.** Between-window gaps live entirely in the host AX layer as per-window padding insets (`LiveWindow.setPadding`; writes do `origin+pad`, `size-2*pad`; reads expand back out). Never add slot pitch to `DaemonCore` — it holds no gap state.
* **Focus centers via the strip** under `autoCenter` (`strip_target = center - size/2 - layout`, deliberately unclamped); the window rides rigidly. `windowHiddenRatio` minimal-expose is the `autoCenter=false` fallback.
* **Edge warp is a display circle** ordered by left edge. Seam suppression runs first so native crossings are never yanked; landings sit 6px inside the opposite edge. Nil paths set `lastWarpKind`. In a clean vertical stack (X-aligned column) the above/below warp maps strictly and the circle is inert (it needs vertical overlap, i.e. a horizontal row); the proportional mapping only serves diagonally-offset "stairs" rigs.
* **Tabbed windows are never reveal/center targets** (`revealFocus`, `applyPendingCenters` skip `tabbed` members); native-tab grouping (`regroupNativeTabs`) collapses same-app same-frame siblings so a background tab never holds a slot that can show nothing.
* **New apps open on the display under the cursor**, and that display becomes active; space-return restores never steal the active workspace.
* **Mouse-follows-focus is keyboard/raise-only** — ambient arrivals never warp (they would compete with focus-follows-mouse).
* **Animations are a single toggle** (`animations`); pacing is internal (250/80/320 from `Animation.swift`) and owned by the daemon — movement, resize, and strip translation share one burst clock.
* **Frames passed to `tick` are padded truth** (raw CG expanded by the window's insets). Keep the re-basing pure — no AX round trips on config reload.

## 4. Coding Standards & Idioms

* **Formatting:** swift-format style; trailing whitespace and proper trailing newlines.
* **Logging:** `print` is used for live diagnostics in `main.swift` and `Daemon.swift` (mirrors legacy Rust `tracing`); keep log lines cheap, descriptive, and on the main thread.
* **Error handling:** no force-unwraps in live paths; guard + early return, log loudly on invariant violations instead of trapping where a retry path exists.
* **No `animations`-duration knobs in config:** `animation_duration_ms`/min/max were removed; adding them back is a regression.

## 5. Testing Strategy

* **Pure math** goes in the pure modules with direct unit checks (`Tests/GeometryChecks`, `LayoutChecks`, `AnimationChecks`, `ScrollChecks`, `ConfigChecks`…).
* **`DaemonChecks` style:** fixed mock frames → `tick` → assert `positions`/`offsets`/`offsetTarget`/`axJobs`/`committedSlot`; drain with empty ticks for glide settle; snap with `animationsEnabled=false` for exact rest asserts.
* **Frame parity:** `Tests/FrameParityChecks` replays the FROZEN Rust-truth corpus (`corpus/`, committed; falls back to it when `PANERU_TRACE_DIR` is unset). It fails, never skips, without a corpus. A layout change that intentionally diverges must update the corpus deliberately — never silently. New geometry needs both directions pinned (wrap, seams, steps).

## 6. Code Cleanup & Verification

Before concluding a task, creating a commit, or presenting work as complete, agents MUST run:

```sh
scripts/verify-swift.sh
```

`verify-swift.sh` runs the full Swift gate and is the single command to run before merging Swift changes:
1. **Release build, full product list** — zero errors AND zero warnings. Census the whole log, never `tail` it (debug builds hid 58 warnings once).
2. **Every `*Checks` runner** — each must end with `<Name>: all checks passed`.
3. **Frame-parity replay** — against the frozen corpus; a skipped replay is a failure.

Targeted debugging of one checks runner: `swift run --package-path swift-daemon DaemonChecks`.

## 7. Contribution Workflow

* **Testing branch:** Use the `testing` branch as a base for the PR, unless the change is very small or is an urgent fix for an issue in the `main` branch. This way the changes get additional baking before unleashing them into the `main` population.
* **Research:** Before implementing, check `swift-daemon/Sources/...` (and the checks) to see if a similar system already exists.
* **Implementation:** Follow the **Plan -> Act -> Validate** cycle.
* **Verification:** Execute the cleanup and verification steps in Section 6. If changes affect window tiling or animation, verify that existing layout interactions continue to work as expected.