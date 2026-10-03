# Agent Instructions: Paneru macOS Window Manager (Bevy-based)

This document provides project-specific guidance for AI agents contributing to Paneru. It builds upon the core philosophy and technical architecture of the codebase.

## 0. Required Skills (load first)

Always load these before any Paneru work — they are normative and override conflicting defaults:

* `paneru-rust` — for any change under `src/`, `crates/`, `Cargo.toml`, `build.rs`. Bevy-first ECS, idle-when-static systems, main-thread macOS bridge, `LayoutStrip`, harness tests, `cargo fmt --check` + `clippy --all-targets -- -D warnings` + `cargo test --all-targets` gate.
* `paneru-swift` — for any change under `swift-daemon/`, `src/overlay.rs`. NOTE: the skill text still describes the deleted `overlay-swift/` C ABI (`overlay-swift/ABI.swift`, `PANERU_SWIFT_OVERLAY`, `OVERLAY_ABI_VERSION`); current Swift truth is `swift-daemon/Sources/{Daemon,Layout,Presenter,LiveProviders}/` per `ARCHITECTURE.md §8`. Follow the repo, not the stale skill paths.
* If a task touches both Rust truth and Swift presentation, load both and keep ECS gating/rect math in Rust.

## 1. Bevy ECS Architecture & Patterns (Bevy First)

Paneru is built on Bevy and strictly follows Data-Driven Design (ECS). **Always prioritize Bevy ECS rules over conventional Rust patterns**:
*   Avoid traditional Object-Oriented patterns, abstract trait hierarchies, or "god structs" holding internal state machines.
*   Model state as small, queryable Components and compose functionality through Systems and Observers.
*   **Marker Components:** Use markers extensively for filtering and state tracking (e.g., `ActiveWorkspaceMarker`, `FocusedMarker`, `FreshMarker`, `Unmanaged`). Most markers are found in `src/ecs.rs` or `src/ecs/mod.rs`.
*   **Avoid Unbounded / Constantly Running Systems:** Systems should not run unconditionally on every tick if there is nothing to process.
    *   **Use `Populated<Query<...>>` instead of `Query<...>`** where a system only acts when matching entities exist. Bevy automatically adds a run condition for `Populated`, ensuring the system is not even scheduled if the query is empty.
    *   Pair queries with change filters (`Changed<T>`, `Added<T>`) and explicit run conditions (`run_if(...)`) so systems remain idle when state is static.
*   **Triggers & Observers:** Prefer Bevy's observer pattern for reactive logic. See `src/ecs/triggers.rs` and `src/ecs/workspace.rs` for examples like `SpawnWindowTrigger` and `WMEventTrigger`.
*   **System Grouping:** Systems are registered in `src/ecs.rs` via `register_systems`. Follow the existing schedule-based organization (`PreUpdate`, `Update`, `PostUpdate`).
*   **System Params:** Use custom system parameters like `Windows` and `ActiveDisplay` (defined in `src/ecs/params.rs`) to simplify queries.

## 2. macOS & AppKit Integration (The Bridge)

*   **Main Thread Constraint:** All AppKit/CoreGraphics calls MUST happen on the main thread.
*   **NonSend Resources:** Use `NonSend` and `NonSendMut` for resources that are not thread-safe (e.g., `WindowManager`, `OverlayManager`).
*   **FFI Wrappers:** Interact with macOS via the abstractions in `src/manager/` and `src/platform/`. Avoid direct `objc2` or `icrate` calls in ECS systems; use the `WindowManager` API.
*   **Change Detection:** Use `Changed<T>` to trigger expensive macOS API updates (like window repositioning) only when the ECS state actually changes.
*   **The Lua Worker:** The scripting runtime (`src/lua/worker.rs`, `lua` feature) runs on its own thread — handlers are user code of unbounded duration and must never stall `pump_events`. Every message to the worker carries the frame's `BatchSnapshot`, which handlers read synchronously; only script-state *writes* round-trip for their ack. Anything crossing that boundary must be plain `Send` data, never a Lua value or an ECS borrow. If you add a main-thread-only FFI call to a path a script can reach (`resolve_chord` is the existing example), compute it on the main thread and cache it — see `config::prime_virtual_keymap`.

## 2b. Swift Daemon (`swift-daemon/Sources/PaneruDaemon/main.swift`)

*   **Top-level state initializes in source order — declare before first use.** The integrator file mixes top-level executable statements (startup discovery, config layering, log lines) with global state. A global read before its declaration executes against zeroed storage: harmless for plain structs/ints, but an instant `EXC_BAD_ACCESS` for reference payloads (arrays, dictionaries, strings, class refs, optionals with non-zero nil layouts). This crashed the daemon five times with misleading stacks (tuple copies, `Date` stores, string compares, array counts). Keep ALL top-level `var`/`let` storage above the first statement that reads it; functions may live anywhere.

## 3. Layout & Workspace Logic

*   **LayoutStrip:** The core layout data structure is `LayoutStrip` (in `src/ecs/layout.rs`). It manages columns, stacks, and tabs.
*   **Virtual Workspaces:** Paneru manages virtual workspaces that map to macOS "Spaces". See `src/ecs/workspace.rs` for how window movement and workspace switching are handled.
*   **Coordinate Systems:** Be aware of the difference between Bevy's coordinate system (often Y-up) and macOS/AppKit (Y-down). Use the `Position` and `Size` abstractions to handle conversions.

## 4. Coding Standards & Idioms

*   **Clippy:** Paneru enforces strict Clippy lints. Run `cargo clippy` before finalizing changes.
*   **Formatting:** All code must be formatted using `cargo fmt`.
*   **Tracing:** Use the `tracing` crate for logging. Use `#[instrument(level = Level::DEBUG, skip_all, fields(...))]` for complex systems.
*   **Error Handling:** Use the project's `Result` type and `Error` enum in `src/errors.rs`. Avoid `unwrap()` in systems; log errors or use `inspect_err`.

## 5. Testing Strategy

*   **Mocking:** When adding features that interact with macOS, ensure the logic is separable so it can be tested with a mock `WindowManager`.
*   **Harness-Based Integration Tests:** Unit and integration tests drive an isolated Bevy `World` via `TestHarness`. Tests should adhere to the established harness structure:
    1. Define a list of input events/commands (`vec![Event::..., Event::Command { ... }]`).
    2. Configure the harness (e.g., `TestHarness::new().with_windows(n)` or `.with_config(...)`).
    3. Assert expected world/state outcomes on specific, 1-indexed iterations using `.on_iteration(step, |world, state| { ... })`.
    4. Execute via `.run(commands)`.

    **Example:**
    ```rust
    #[test]
    fn test_stack_focus_or_switch_virtual() {
        let commands = vec![
            Event::MenuOpened { window_id: 0 },
            Event::Command {
                command: Command::Window(Operation::FocusOrVirtual(Direction::South)),
            },
            Event::Command {
                command: Command::Window(Operation::FocusOrVirtual(Direction::South)),
            },
        ];

        TestHarness::new()
            .with_windows(2)
            .on_iteration(1, |world, _state| {
                // First step: focus moves to sibling window in stack
                assert_focused!(world, 1);
                assert_eq!(active_virtual_index(world), 0);
            })
            .on_iteration(2, |world, _state| {
                // Second step: at bottom of stack, falls through to workspace switch
                assert_eq!(active_virtual_index(world), 1);
            })
            .run(commands);
    }
    ```
*   **Pure Functions:** Extract complex layout math into pure functions (e.g., in `src/ecs/layout.rs`) and add unit tests.

## 6. Code Cleanup & Verification

Before concluding a task, creating a commit, or presenting work as complete, agents MUST run the standard cleanup and verification suite:

1. **Format Code:**
   ```sh
   cargo fmt
   ```
   Ensures all code across the workspace complies with standard formatting rules and contains proper trailing newlines. Verify with `cargo fmt --check`.

2. **Lint with Clippy:**
   ```sh
   cargo clippy --all-targets -- -D warnings
   ```
   Paneru enforces strict lints. Fix all warnings; do not leave warnings unaddressed.

3. **Run All Tests:**
   ```sh
   cargo test --all-targets
   ```
   Ensure the complete test suite passes without regressions across all packages in the workspace. For targeted debugging of a specific test:
   ```sh
   RUST_LOG=debug cargo test <test_name> -- --nocapture
   ```
   `cargo nextest run --workspace --all-targets` also works and is the CI runner. Each harness command gets a 200ms simulated window (`COMMAND_WINDOW` in `src/tests/harness.rs`, just above the 150ms delayed-refresh timeout); tests asserting exact rest positions of long-settling animations opt back into 500ms via `TestHarness::with_command_window`. Suite logs default to `warn` — `RUST_LOG` overrides still apply.

4. **Frame-parity replay (Swift ↔ Rust):** after any `swift-daemon/Sources` change, replay the Rust trace corpus against the Swift core. The corpus is committed at `swift-daemon/Tests/FrameParityChecks/corpus/` and `FrameParityChecks` falls back to it when `PANERU_TRACE_DIR` is unset, so a bare run is a real gate (it fails, never skips, without a corpus). Regenerate it after any Rust-side layout change:
   ```sh
   trace="$(mktemp -d)"
   PANERU_TRACE_OUT="$trace" cargo test --all-targets trace
   cp "$trace"/*.jsonl swift-daemon/Tests/FrameParityChecks/corpus/
   ```
   `scripts/verify-swift.sh` runs the full Swift gate (release build with zero warnings, every `*Checks` runner, then the parity replay) and is the single command to run before merging Swift changes.

## 7. Contribution Workflow

*   **Testing branch:** Use the `testing` branch as a base for the PR, unless the change is very small or is an urgent fix for an issue in the `main` branch. This way the changes get additional baking before unleashin them into the `main` population.
*   **Research:** Before implementing, check `src/ecs/...` to see if a similar system already exists.
*   **Implementation:** Follow the **Plan -> Act -> Validate** cycle.
*   **Verification:** Execute the cleanup and verification steps in Section 6. If changes affect window tiling or animation, verify that existing layout interactions continue to work as expected.

