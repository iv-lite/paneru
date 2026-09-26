// Unit tests for the tap shim ring + translator. No tap is installed, no
// permissions needed: everything under test is pure C. Built and run with:
//   cc -std=c11 -Wall -Wextra -Werror -framework CoreGraphics \
//     -I swift-daemon/Sources/CTapShim/include \
//     swift-daemon/Sources/CTapShim/tap_shim.c \
//     swift-daemon/Tests/TapShimCTests/main.c -o /tmp/tap_shim_tests && /tmp/tap_shim_tests
#include <assert.h>
#include <stdio.h>

#include "tap_shim.h"

static int failures = 0;

#define CHECK(cond, msg)                                   \
    do {                                                   \
        if (!(cond)) {                                     \
            ++failures;                                    \
            printf("FAIL: %s\n", msg);                     \
        }                                                  \
    } while (0)

static paneru_tap_event_t make_event(uint8_t kind, double x) {
    paneru_tap_event_t event;
    event.kind = kind;
    event._pad[0] = event._pad[1] = event._pad[2] = 0;
    event.modifiers = 0;
    event.x = x;
    event.y = 0.0;
    event.keycode = 0;
    event.scroll_dy = 0.0;
    event.t_nanos = 0;
    return event;
}

static void test_ring_fifo(void) {
    paneru_tap_ring_t ring;
    paneru_tap_ring_init(&ring);
    paneru_tap_event_t out;
    CHECK(!paneru_tap_ring_pop(&ring, &out), "empty ring pops false");
    for (int i = 0; i < 10; ++i) {
        paneru_tap_event_t event = make_event(PANERU_TAP_MOVED, (double)i);
        CHECK(paneru_tap_ring_push(&ring, &event), "push succeeds");
    }
    for (int i = 0; i < 10; ++i) {
        CHECK(paneru_tap_ring_pop(&ring, &out), "pop succeeds");
        CHECK(out.kind == PANERU_TAP_MOVED && out.x == (double)i, "fifo order");
    }
    CHECK(!paneru_tap_ring_pop(&ring, &out), "drained ring pops false");
    CHECK(paneru_tap_ring_dropped(&ring) == 0, "no drops");
}

static void test_ring_wraps_and_drops_newest(void) {
    paneru_tap_ring_t ring;
    paneru_tap_ring_init(&ring);
    // Fill past capacity: oldest PANERU_TAP_RING_CAPACITY survive, rest drop.
    const int total = PANERU_TAP_RING_CAPACITY + 64;
    for (int i = 0; i < total; ++i) {
        paneru_tap_event_t event = make_event(PANERU_TAP_LEFT_DRAGGED, (double)i);
        paneru_tap_ring_push(&ring, &event);
    }
    CHECK(paneru_tap_ring_dropped(&ring) == 64, "drop count");
    paneru_tap_event_t out;
    CHECK(paneru_tap_ring_pop(&ring, &out), "pop after wrap");
    CHECK(out.x == 0.0, "oldest preserved");
    int count = 1;
    while (paneru_tap_ring_pop(&ring, &out)) {
        ++count;
    }
    CHECK(count == PANERU_TAP_RING_CAPACITY, "capacity preserved");
}

static void test_translate_buttons(void) {
    paneru_tap_event_t out;
    CGPoint loc = CGPointMake(100.0, 200.0);
    paneru_tap_translate(kCGEventLeftMouseDown, loc, 0x100000, 0, 0.0, 42, &out);
    CHECK(out.kind == PANERU_TAP_LEFT_DOWN, "left down kind");
    CHECK(out.x == 100.0 && out.y == 200.0, "left down location");
    CHECK(out.modifiers == 0x100000, "flags verbatim");
    CHECK(out.t_nanos == 42, "timestamp");
    paneru_tap_translate(kCGEventLeftMouseUp, loc, 0, 0, 0.0, 0, &out);
    CHECK(out.kind == PANERU_TAP_LEFT_UP, "left up kind");
    paneru_tap_translate(kCGEventLeftMouseDragged, loc, 0, 0, 0.0, 0, &out);
    CHECK(out.kind == PANERU_TAP_LEFT_DRAGGED, "left dragged kind");
    paneru_tap_translate(kCGEventRightMouseDown, loc, 0, 0, 0.0, 0, &out);
    CHECK(out.kind == PANERU_TAP_RIGHT_DOWN, "right down kind");
    paneru_tap_translate(kCGEventRightMouseUp, loc, 0, 0, 0.0, 0, &out);
    CHECK(out.kind == PANERU_TAP_RIGHT_UP, "right up kind");
    paneru_tap_translate(kCGEventRightMouseDragged, loc, 0, 0, 0.0, 0, &out);
    CHECK(out.kind == PANERU_TAP_RIGHT_DRAGGED, "right dragged kind");
    paneru_tap_translate(kCGEventMouseMoved, loc, 0, 0, 0.0, 0, &out);
    CHECK(out.kind == PANERU_TAP_MOVED, "moved kind");
}

static void test_translate_key_scroll_other(void) {
    paneru_tap_event_t out;
    CGPoint loc = CGPointMake(0.0, 0.0);
    paneru_tap_translate(kCGEventKeyDown, loc, 0, 53, 0.0, 0, &out);
    CHECK(out.kind == PANERU_TAP_KEY_DOWN, "key kind");
    CHECK(out.keycode == 53, "keycode");
    CHECK(out.scroll_dy == 0.0, "no scroll on key");
    paneru_tap_translate(kCGEventScrollWheel, loc, 0, 0, -3.5, 0, &out);
    CHECK(out.kind == PANERU_TAP_SCROLL, "scroll kind");
    CHECK(out.scroll_dy == -3.5, "scroll delta");
    CHECK(out.keycode == 0, "no keycode on scroll");
    paneru_tap_translate(kCGEventTapDisabledByTimeout, loc, 0, 0, 0.0, 0, &out);
    CHECK(out.kind == PANERU_TAP_OTHER, "control event maps to other");
    paneru_tap_translate(kCGEventNull, loc, 0, 0, 0.0, 0, &out);
    CHECK(out.kind == PANERU_TAP_OTHER, "null maps to other");
}

int main(void) {
    test_ring_fifo();
    test_ring_wraps_and_drops_newest();
    test_translate_buttons();
    test_translate_key_scroll_other();
    if (failures == 0) {
        printf("TapShimCTests: all checks passed\n");
        return 0;
    }
    printf("TapShimCTests: %d failure(s)\n", failures);
    return 1;
}
