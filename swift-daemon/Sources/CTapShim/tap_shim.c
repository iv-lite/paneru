#include "tap_shim.h"

#include <stdatomic.h>

#define PANERU_TAP_RING_MASK (PANERU_TAP_RING_CAPACITY - 1)

_Static_assert(
    (PANERU_TAP_RING_CAPACITY & (PANERU_TAP_RING_CAPACITY - 1)) == 0,
    "ring capacity must be a power of two");
_Static_assert(PANERU_TAP_RING_CAPACITY > 0, "ring capacity must be nonzero");

void paneru_tap_ring_init(paneru_tap_ring_t *ring) {
    atomic_init(&ring->head, 0);
    atomic_init(&ring->tail, 0);
    atomic_init(&ring->dropped, 0);
}

bool paneru_tap_ring_push(paneru_tap_ring_t *ring, const paneru_tap_event_t *event) {
    uint32_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
    if (head - tail >= PANERU_TAP_RING_CAPACITY) {
        atomic_fetch_add_explicit(&ring->dropped, 1, memory_order_relaxed);
        return false;
    }
    ring->slots[head & PANERU_TAP_RING_MASK] = *event;
    atomic_store_explicit(&ring->head, head + 1, memory_order_release);
    return true;
}

bool paneru_tap_ring_pop(paneru_tap_ring_t *ring, paneru_tap_event_t *out) {
    uint32_t tail = atomic_load_explicit(&ring->tail, memory_order_relaxed);
    uint32_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
    if (tail == head) {
        return false;
    }
    *out = ring->slots[tail & PANERU_TAP_RING_MASK];
    atomic_store_explicit(&ring->tail, tail + 1, memory_order_release);
    return true;
}

uint64_t paneru_tap_ring_dropped(const paneru_tap_ring_t *ring) {
    return atomic_load_explicit(
        (const _Atomic uint64_t *)&ring->dropped, memory_order_relaxed);
}

void paneru_tap_translate(
    CGEventType type,
    CGPoint location,
    uint64_t flags,
    int64_t keycode,
    double scroll_dy,
    uint64_t timestamp,
    paneru_tap_event_t *out) {
    out->modifiers = (uint32_t)flags;
    out->x = location.x;
    out->y = location.y;
    out->keycode = 0;
    out->scroll_dy = 0.0;
    out->t_nanos = timestamp;
    switch (type) {
    case kCGEventLeftMouseDown:
        out->kind = PANERU_TAP_LEFT_DOWN;
        break;
    case kCGEventLeftMouseUp:
        out->kind = PANERU_TAP_LEFT_UP;
        break;
    case kCGEventLeftMouseDragged:
        out->kind = PANERU_TAP_LEFT_DRAGGED;
        break;
    case kCGEventRightMouseDown:
        out->kind = PANERU_TAP_RIGHT_DOWN;
        break;
    case kCGEventRightMouseUp:
        out->kind = PANERU_TAP_RIGHT_UP;
        break;
    case kCGEventRightMouseDragged:
        out->kind = PANERU_TAP_RIGHT_DRAGGED;
        break;
    case kCGEventMouseMoved:
        out->kind = PANERU_TAP_MOVED;
        break;
    case kCGEventKeyDown:
        out->kind = PANERU_TAP_KEY_DOWN;
        out->keycode = keycode;
        break;
    case kCGEventScrollWheel:
        out->kind = PANERU_TAP_SCROLL;
        out->scroll_dy = scroll_dy;
        break;
    default:
        out->kind = PANERU_TAP_OTHER;
        break;
    }
}

CGEventRef paneru_tap_callback(
    CGEventTapProxy proxy,
    CGEventType type,
    CGEventRef event,
    void *refcon) {
    (void)proxy;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        // Re-enable path stays with the daemon (it owns the mach port);
        // never swallow control events here.
        return event;
    }
    paneru_tap_ring_t *ring = (paneru_tap_ring_t *)refcon;
    if (ring == NULL) {
        return event;
    }
    CGPoint location = CGEventGetLocation(event);
    uint64_t flags = (uint64_t)CGEventGetFlags(event);
    int64_t keycode = 0;
    double scroll_dy = 0.0;
    if (type == kCGEventKeyDown) {
        keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    } else if (type == kCGEventScrollWheel) {
        scroll_dy = CGEventGetDoubleValueField(event, kCGScrollWheelEventDeltaAxis1);
    }
    paneru_tap_event_t translated;
    paneru_tap_translate(
        type, location, flags, keycode, scroll_dy, CGEventGetTimestamp(event), &translated);
    paneru_tap_ring_push(ring, &translated);
    // Pass-through: the daemon decides interception when draining.
    return event;
}
