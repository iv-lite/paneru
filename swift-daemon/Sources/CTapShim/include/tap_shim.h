// Paneru tap shim: real-time CGEventTap sidecar (Phase 1D, Risk 4).
//
// No Swift, no actors, no ARC traffic runs at tap priority. The tap
// callback translates the raw `CGEvent` into a plain `paneru_tap_event_t`
// and pushes it into a single-producer/single-consumer ring; the daemon
// drains the ring on the main thread. Full ring drops newest (bounded-queue
// discipline, matching the Rust AX workers).
//
// Tap *installation* (CGEventTapCreate + run-loop source) stays with the
// daemon for now; this target owns the buffer, the translation table, and
// the overrun accounting. Pure functions are unit-tested in
// `Tests/TapShimCTests` without macOS permissions.
#ifndef PANERU_TAP_SHIM_H
#define PANERU_TAP_SHIM_H

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Event kinds the daemon cares about. Mirrors the arms in
/// `src/platform/input.rs` (`InputHandler::handle`).
typedef enum paneru_tap_kind {
    PANERU_TAP_LEFT_DOWN = 0,
    PANERU_TAP_LEFT_UP = 1,
    PANERU_TAP_LEFT_DRAGGED = 2,
    PANERU_TAP_RIGHT_DOWN = 3,
    PANERU_TAP_RIGHT_UP = 4,
    PANERU_TAP_RIGHT_DRAGGED = 5,
    PANERU_TAP_MOVED = 6,
    PANERU_TAP_KEY_DOWN = 7,
    PANERU_TAP_SCROLL = 8,
    PANERU_TAP_OTHER = 9,
    PANERU_TAP_KIND_COUNT = 10
} paneru_tap_kind_t;

/// Plain-data tap event. No pointers, no CoreFoundation objects: safe to
/// pass across the tap-thread boundary and into Swift.
typedef struct paneru_tap_event {
    uint8_t kind;      // paneru_tap_kind_t
    uint8_t _pad[3];
    uint32_t modifiers; // CGEventFlags bits (verbatim)
    double x;           // CGEvent location (pointer events)
    double y;
    int64_t keycode;    // key-down only, else 0
    double scroll_dy;   // scroll-wheel only, else 0
    uint64_t t_nanos;   // CGEventTimestamp
} paneru_tap_event_t;

/// Power-of-two capacity (must be > 0). 1024 matches the AX writer bound.
#define PANERU_TAP_RING_CAPACITY 1024

/// SPSC ring. `head` is tap-thread owned, `tail` is drain-thread owned.
/// `_Atomic` indices make the handoff defined without locks.
typedef struct paneru_tap_ring {
    _Atomic uint32_t head;
    _Atomic uint32_t tail;
    _Atomic uint64_t dropped;
    paneru_tap_event_t slots[PANERU_TAP_RING_CAPACITY];
} paneru_tap_ring_t;

/// Zero-initialise (static storage is already zeroed; call for stack rings).
void paneru_tap_ring_init(paneru_tap_ring_t *ring);

/// Push from the tap thread. Returns false (and counts a drop) when full —
/// newest event is discarded, oldest preserved.
bool paneru_tap_ring_push(paneru_tap_ring_t *ring, const paneru_tap_event_t *event);

/// Pop from the drain thread. Returns false when empty.
bool paneru_tap_ring_pop(paneru_tap_ring_t *ring, paneru_tap_event_t *out);

/// Total dropped events since init (overrun accounting for diagnostics).
uint64_t paneru_tap_ring_dropped(const paneru_tap_ring_t *ring);

/// Translate one raw tap callback invocation into a plain event.
/// Pure: no tap, no permissions needed. `keycode`/`scroll_dy` are read by
/// the caller only for key/scroll types and passed through otherwise.
void paneru_tap_translate(
    CGEventType type,
    CGPoint location,
    uint64_t flags,
    int64_t keycode,
    double scroll_dy,
    uint64_t timestamp,
    paneru_tap_event_t *out);

/// The live tap callback: translate + push. Installs with
/// `CGEventTapCreate` on the daemon side; kept here so the real-time path
/// stays C end to end. `refcon` must be a `paneru_tap_ring_t *`.
CGEventRef paneru_tap_callback(
    CGEventTapProxy proxy,
    CGEventType type,
    CGEventRef event,
    void *refcon);

#ifdef __cplusplus
}
#endif

#endif // PANERU_TAP_SHIM_H
