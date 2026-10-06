<div align="center">
  <img src="./images/paneru.png" alt="paneru-swift" width="600"/>
</div>

# paneru-swift

A sliding, tiling window manager for MacOS.

> **Origin.** `paneru-swift` is a fork of
> [karinushka/paneru](https://github.com/karinushka/paneru) by
> [Karinushka](https://github.com/karinushka). Upstream Paneru is a Bevy/ECS
> Rust window manager; this fork is a **native Swift daemon**
> (`swift-daemon/`, product `paneru-swift`) that ports the same tiling core,
> AppKit presentation, XPC command/query/subscribe server, Lua scripting, and
> launchd agent — no Rust toolchain needed. The Rust daemon was removed; its
> trace corpus lives on as the frozen parity-truth behind the `FrameParityChecks`
> gate. All of the original design credit (the sliding-strip model and its
> MacOS window techniques) goes to the upstream project; see
> [Inspiration](#inspiration) and [Installation](#installation).

## About

Paneru is a MacOS window manager that arranges windows on an infinite strip,
extending to the right. A core principle is that opening a new window will
**never** cause existing windows to resize, maintaining your layout stability.

Each monitor operates with its own independent window strip, ensuring that
windows remain confined to their respective displays and do not "overflow" onto
adjacent monitors.

https://github.com/user-attachments/assets/cbc2e820-635f-408b-923a-6cb47c44704c

(Video by @emreekici3 - https://github.com/emreekici3/dotfiles)

https://github.com/user-attachments/assets/793e7eaa-7909-4086-8380-1fb7861f8780


## Why Paneru?

- **Niri-like Behavior on MacOS:** Inspired by the user experience of [Niri],
  Paneru aims to bring a similar scrollable tiling workflow to MacOS.
- **Works with MacOS workspaces:** You can use existing workspaces and switch
  between them with keyboard or touchpad gestures - with a separate window strip
  on each. Drag and dropping windows between them works as well: holding the
  `mouse_drag_display_modifier` shortcut while left-clicking a window arms the
  drag (grab anywhere — paneru moves the window's whole column itself, so a
  native edge-resize cannot win and stacked mates follow), and crossing a
  display boundary moves the column to that display's strip live,
  keeping focus (lands in the nearest column with `insert_windows_mid_strip`;
  oversized windows shrink to fit on arrival).
  A filled ghost spanning the dragged column marks the landing slot
  throughout the drag, and the edge
  warp carries the cursor across when `horizontal_mouse_warp` is set.
  Without the shortcut, window drags move their column with the pointer
  and glide home on release instead of transferring anything —
  only armed drags reorder or transfer.
- **Virtual Workspaces (Experimental):** Group your windows into tasks by
  stacking multiple horizontal strips (rows) within a single space. Use native
  macOS workspaces for broad segregation (e.g., 'Work', 'Personal') and virtual
  workspaces to stay organized within each context.
- **Menu bar workspace indicator:** Shows the currently active virtual
  workspace in the macOS menu bar.
- **Copy Window Rule:** A menu bar entry that puts a ready-to-paste
  `[windows]` configuration rule for the focused window on the clipboard, so
  you never have to guess an app's bundle id.
- **Startup session restore:** Restores managed window layouts, virtual
  workspaces, and display assignments from the last saved state when Paneru
  starts.
- **Focus follows mouse on MacOS:** Very useful for people who would like to
  avoid an extra click.
- **Sliding windows with touchpad:** Using a touchpad is quite natural for
  navigation of the window pane.
- **Native macOS tabs support:** Applications like Ghostty use these, so
  Paneru manages them on the layout strip like other windows.
- **Optimal for Large Displays:** Standard tiling window managers can be
  suboptimal for large displays, often resulting in either huge maximized
  windows or numerous tiny, unusable windows. Paneru addresses this by
  providing a more flexible and practical arrangement.
- **Improved Small Display Usability:** On smaller displays (like laptops),
  traditional tiling can make windows too small to be productive, forcing users
  to constantly maximize. Paneru's sliding strip approach aims to provide a
  better experience without this compromise.

## Inspiration

The fundamental architecture and window management techniques are heavily
inspired by [Yabai], another excellent MacOS window manager. Studying its
source code has provided invaluable insights into managing windows on MacOS,
particularly regarding undocumented functions.

The innovative concept of managing windows on a sliding strip is directly
inspired by [Niri] and [PaperWM.spoon].

## Installation

### Recommended System Options

- Like all non-native window managers for MacOS, Paneru requires accessibility
  access to move windows. Once it runs you may get a dialog window asking for
  permissions. Otherwise check the setting in System Settings under "Privacy &
  Security -> Accessibility".

- Check your System Settings for "Displays have separate spaces" option. It
  should be enabled - this allows Paneru to manage the workspaces independently.

- **Multiple displays**. Paneru hides windows off-screen to the left or right.
  If you have multiple displays — for example your laptop open when docked to
  an external monitor — you may experience weird behavior: when macOS notices a
  window being moved too far off-screen it relocates it to a different display,
  which confuses Paneru. The solution is to change the spatial arrangement of
  your additional displays: instead of placing them left/right, stack them in a
  **clean vertical column** (X-aligned, one directly above/below the other).
  The off-screen windows then hide in the empty side gutters rather than on the
  neighbouring display.
  A [similar situation](https://nikitabobko.github.io/AeroSpace/guide#proper-monitor-arrangement)
  exists with Aerospace window manager.
  An option exists (`horizontal_mouse_warp`) which makes this vertical
  arrangement of displays "feel" horizontal, since your monitors are physically
  side-by-side. The edge-warp *display circle* (wrap-around at the outer edges)
  only applies to horizontally-overlapping rows and is inert in a vertical
  column, so it is optional.

- **Off-screen window slivers**. Because macOS will forcibly relocate windows
  that are moved fully off-screen, Paneru keeps a thin sliver of each
  off-screen window visible at the screen edge. The `sliver_width` and
  `sliver_height` options control the size of this sliver. This is a
  workaround for a macOS limitation, not a design choice.

### Installing (recommended): the Swift daemon

The shipped, supported daemon is **`paneru-swift`** — this fork's native
port: same tiling core, AppKit presentation, XPC command/query/subscribe
server, Lua binds and event handlers, and a launchd agent — no Rust
toolchain needed.

```shell
$ git clone https://github.com/iv-lite/paneru-swift.git
$ cd paneru-swift
$ swift-daemon/install-service.sh install
```

The script builds the release binary, installs it to `~/.local/bin`,
signs it with a persistent `Paneru Local` code-signing identity (so the
Accessibility grant survives rebuilds), renders the agent plist, and
bootstraps it with `launchctl`. Then grant Accessibility (System Settings →
Privacy & Security → Accessibility) — the daemon exits loudly without it —
and it tiles on the next login too (`RunAtLoad`).

Start, stop, and remove:

```shell
$ swift-daemon/install-service.sh start
$ swift-daemon/install-service.sh stop
$ swift-daemon/install-service.sh uninstall
```

Logs land in `/tmp/com.github.iv-lite.paneru-swift_<uid>.out.log`
(and `.err.log`). New apps open on the display under the cursor and that
display becomes active; focus-follows-mouse and mouse-follows-focus are
independent, and animation glide timing is owned by the daemon itself
(single `animations` toggle — see `CONFIGURATION.md`).

### CLI: `pq`

`pq` (built with the daemon) talks to the running daemon over its Mach
XPC service:

```shell
$ pq state | active | virtual-workspaces | on-screen     # JSON snapshots
$ pq run window focus east                                # any hotkey command
$ pq apply '[{"focus":1}]'                                # window-set ops
$ pq subscribe                                            # stream event JSON
$ pq state-get <key>   # / state-write <key> <json> [--exactly <json>] / state-remove <key>
```

Without launchd, live state is available at
`cat /tmp/paneru-swift-state.json`.

### Configuration

Paneru checks for configuration in following locations:

- `$HOME/.paneru`
- `$HOME/.paneru.toml`
- `$XDG_CONFIG_HOME/paneru/paneru.toml`

Additionally it allows overriding the location with `$PANERU_CONFIG` environment variable.
If none of these files exists, Paneru creates
`$XDG_CONFIG_HOME/paneru/paneru.toml` with the built-in defaults on first launch.

A Lua script (`$XDG_CONFIG_HOME/paneru/init.lua`, `$HOME/.paneru.lua`, or
`$PANERU_LUA`) replaces the TOML rather than layering on top of it: when one
exists, no `paneru.toml` is read, created, or watched.

You can use the following basic configuration as a starting point. For a
complete guide to all available options, keybindings, and window rules, see the
**[Configuration Guide](./CONFIGURATION.md)**.

```toml
# basic .paneru.toml
[options]
focus_follows_mouse = true
mouse_follows_focus = true

[bindings]
window_focus_west = "cmd - h"
window_focus_east = "cmd - l"
window_resize = "alt - r"
window_center = "alt - c"
quit = "ctrl + alt - q"
```

Alternatively, the embedded Lua runtime can declare the entire configuration
via `paneru.setup{...}`, making the TOML file optional — see the
**[Lua Scripting Guide](./SCRIPTING.md)**:

```lua
-- init.lua
paneru.setup {
  options = { focus_follows_mouse = true, mouse_follows_focus = true },
  bindings = {
    ["window focus west"] = "cmd - h",
    ["window focus east"] = "cmd - l",
    ["quit"] = "ctrl + alt - q",
  },
}
```

### Live reloading

Changes made to the active configuration file are automatically reloaded while
Paneru is running. This is useful for tweaking keyboard bindings and other
settings without restarting the application.

### Startup session restore

Paneru saves managed window layout state to the user state directory
(`$XDG_STATE_HOME/paneru/state.json`, usually
`~/.local/state/paneru/state.json`) and loads it when Paneru starts. During the
startup restore window, Paneru matches reopened windows to the saved session and
restores their layout placement, virtual workspace row, and display assignment
where possible.

Restore is startup-only. After the configured startup grace period expires, new
or unmatched windows follow the normal configuration and window-rule behavior.
Saved windows that are not present are ignored by default and the restored
layout is compacted around the windows that were found. The behavior is
configured with `[restore]`; see the
**[Session Restore](./CONFIGURATION.md#session-restore)** section in the
configuration guide.

### CLI: sending commands & querying state

`pq` (built with the daemon) drives a running Paneru over its Mach XPC
service. Any command that can be bound to a hotkey can be sent
programmatically with `pq run`:

```shell
$ pq run <command [args...]>
```

#### Available commands

| Command                    | Description                                      |
| -------------------------- | ------------------------------------------------ |
| `window focus <direction\|number\|managed\|unmanaged>` | Move focus by direction, column number, managed or unmanaged |
| `window swap <direction>`  | Swap the focused window with a neighbour         |
| `window center`            | Center the focused window on screen              |
| `window resize`            | Cycle through `preset_column_widths`             |
| `window grow`              | Grow to the next preset width                    |
| `window shrink`            | Shrink to the previous preset width              |
| `window vertical resize`   | Cycle a stacked window through `preset_stack_heights` |
| `window vertical grow`     | Grow a stacked window to the next preset height  |
| `window vertical shrink`   | Shrink a stacked window to the previous preset height |
| `window fullwidth`         | Toggle full-width mode for the focused window    |
| `window manage`            | Toggle managed/floating state                    |
| `window equalize`          | Distribute equal heights in the focused stack    |
| `window balance`           | Make all columns match the focused window width  |
| `window stack`             | Stack the focused window onto its left neighbour |
| `window unstack`           | Unstack the focused window into its own column   |
| `window nextdisplay`       | Move the focused window to the next display      |
| `window nextdisplaysend`   | Move the window to the next display but stay here |
| `window previousdisplay`   | Move the focused window to the previous display  |
| `window previousdisplaysend` | Move the window to the previous display but stay here |
| `window virtual <dir>`     | Switch to the previous/next virtual workspace     |
| `window virtualnum <n>`    | Switch directly to numbered virtual workspace    |
| `window virtualmove <dir>` | Move the window to a different virtual workspace  |
| `window virtualmovenum <n>` | Move the window to numbered virtual workspace and follow it |
| `window virtualsend <dir>` | Send the window to a virtual workspace but stay  |
| `window virtualsendnum <n>` | Send the window to numbered virtual workspace but stay |
| `window snap`              | Snap the focused window into the visible viewport |
| `mouse nextdisplay`        | Warp the mouse pointer to the next display       |
| `mouse previousdisplay`    | Warp the mouse pointer to the previous display   |
| `printstate`               | Print the internal daemon state to the debug log |
| `quit`                     | Quit Paneru                                      |
| `restart`                  | Restart the Paneru service                         |

Where `<direction>` is one of: `west`, `east`, `north`, `south`, `first`, `last`.
Window numbers are 1-based and count columns from left to right.

#### Examples

```shell
# Move focus one window to the right.
$ pq run window focus east

# Swap the current window to the left.
$ pq run window swap west

# Center and resize in one shot (two separate calls).
$ pq run window center && pq run window resize

# Balance all columns to the focused window's width.
$ pq run window balance

# Cycle backward through preset widths.
$ pq run window shrink

# Grow the focused window's height inside its stack.
$ pq run window vertical grow

# Jump to the left-most window.
$ pq run window focus first

# Jump to the second window from the left.
$ pq run window focus 2

# Switch directly to virtual workspace 3.
$ pq run window virtualnum 3

# Send the focused window to virtual workspace 3 without following it.
$ pq run window virtualsendnum 3
```

#### Querying and subscribing to state

Paneru exposes structured JSON state for scripts and status bars:

```shell
$ pq state | active | virtual-workspaces | on-screen   # JSON snapshot, exits
$ pq subscribe                                         # line-delimited JSON events
```

`subscribe` keeps the channel open and emits line-delimited JSON events for
changes that integrations usually care about, including focus changes,
virtual workspace changes, window-list changes, title changes, and display
changes. See [`QUERY_AND_SUBSCRIBE_FORMAT.md`](./QUERY_AND_SUBSCRIBE_FORMAT.md)
for the full payload contract.

#### Scripting ideas

Because `pq run` talks to the running daemon, you can drive Paneru from shell
scripts, `cron` jobs, or other automation tools:

- **Launch-and-arrange workflow.** Open an application and immediately position
  it: `open -a Safari && sleep 0.5 && pq run window resize`.
- **One-key layout reset.** Use `pq run window balance` to make every
  column the same width as the focused window — great for resetting layouts
  after unplugging a monitor or when windows get shuffled.
- **Integration with other tools.** Pipe focus events from tools like
  [Hammerspoon](https://www.hammerspoon.org) or
  [skhd](https://github.com/koekeishiya/skhd) into `pq run` for
  compound actions that go beyond a single hotkey.
- **Multi-display orchestration.** Move a window to the next display and
  immediately warp the mouse there:
  ```shell
  pq run window nextdisplay && pq run mouse nextdisplay
  ```
- **Status bar integration.** Use `pq state` to render the
  initial workspace labels, then keep them current with `pq subscribe`.


## Future Enhancements

- More commands for manipulating windows: finegrained size adjustments, touchpad resizing, etc.
- Deeper scriptability building on the embedded Lua runtime, which already
  supports full configuration (`paneru.setup`), event hooks (`paneru.on`),
  keybindings (`paneru.bind`), and state queries — see the **[Lua Scripting Guide](./SCRIPTING.md)**.

## Communication

There is a public Matrix room
[`#paneru:matrix.org`](https://matrix.to/#/%23paneru%3Amatrix.org). Join and
ask any questions.

## Architecture Overview

For a detailed high-level overview of Paneru's internal design, data flow, and
verification model, please refer to the **[Architecture Guide](./ARCHITECTURE.md)**.

Paneru's architecture is a **serial, pure-core Swift daemon** (`swift-daemon/`):
`DaemonCore` runs `ingest → layout → commit → paint` per 60Hz tick against
injected frame providers, with all window-manager state as value types in
pure modules (`Geometry`, `Layout`, `Focus`, `Animation`, `Session`, …) and
the macOS seams — AX reads/writes, the event tap, presenter, menu bar, and
XPC — kept in `LiveProviders`/`Presenter`/`PaneruDaemon` on the main thread.
Layout truth (the sliding-strip model) is covered by a frozen frame-parity
corpus replayed by `FrameParityChecks`.

### Repository Structure

- **`main` branch**: Contains the stable, released code.
- **`testing` branch**: Used for experimental features and architectural refactors. This branch is volatile and may be force-pushed.

## Tile Scrollably Elsewhere

Here are some other projects which implement a similar workflow:

- [Niri]: a scrollable tiling Wayland compositor.
- [PaperWM]: scrollable tiling on top of GNOME Shell.
- [karousel]: scrollable tiling on top of KDE.
- [papersway]: scrollable tiling on top of sway/i3.
- [hyprscroller] and [hyprslidr]: scrollable tiling on top of Hyprland.
- [PaperWM.spoon]: scrollable tiling for MacOS on top of HammerSpoon.
- [Nehir]: scrollable tiling for MacOS

[Yabai]: https://github.com/koekeishiya/yabai
[Niri]: https://github.com/YaLTeR/niri
[PaperWM]: https://github.com/paperwm/PaperWM
[karousel]: https://github.com/peterfajdiga/karousel
[papersway]: https://spwhitton.name/tech/code/papersway/
[hyprscroller]: https://github.com/dawsers/hyprscroller
[hyprslidr]: https://gitlab.com/magus/hyprslidr
[PaperWM.spoon]: https://github.com/mogenson/PaperWM.spoon
[Nehir]: https://github.com/Guria/Nehir
