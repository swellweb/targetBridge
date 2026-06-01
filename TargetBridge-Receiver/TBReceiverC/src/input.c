/* input.c — inject forwarded sender input into the native macOS session. */

#include "input.h"

#include <ApplicationServices/ApplicationServices.h>
#include <stdlib.h>

/* Button bits in `button_mask`. */
#define TB_BTN_LEFT   0x1
#define TB_BTN_RIGHT  0x2
#define TB_BTN_CENTER 0x4

struct tb_input {
    CGEventSourceRef src;
    double x, y;            /* tracked virtual cursor position (global coords) */
    double min_x, min_y;    /* main-display bounds, refreshed per move */
    double max_x, max_y;
    int    button_mask;     /* currently-held buttons */
};

static void tb_input_refresh_bounds(struct tb_input *in) {
    CGRect b = CGDisplayBounds(CGMainDisplayID());
    in->min_x = b.origin.x;
    in->min_y = b.origin.y;
    in->max_x = b.origin.x + b.size.width  - 1.0;
    in->max_y = b.origin.y + b.size.height - 1.0;
}

static void tb_input_center(struct tb_input *in) {
    CGRect b = CGDisplayBounds(CGMainDisplayID());
    in->x = b.origin.x + b.size.width  / 2.0;
    in->y = b.origin.y + b.size.height / 2.0;
}

struct tb_input *tb_input_create(void) {
    struct tb_input *in = (struct tb_input *)calloc(1, sizeof(*in));
    if (!in) return NULL;
    /* HID-system source so flags/state compose with the real keyboard. */
    in->src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    tb_input_refresh_bounds(in);
    tb_input_center(in);
    return in;
}

void tb_input_destroy(struct tb_input *in) {
    if (!in) return;
    if (in->src) CFRelease(in->src);
    free(in);
}

int tb_input_accessibility_ok(struct tb_input *in) {
    (void)in;
    return AXIsProcessTrusted() ? 1 : 0;
}

static CGMouseButton tb_cg_button(int button) {
    switch (button) {
    case 1:  return kCGMouseButtonRight;
    case 2:  return kCGMouseButtonCenter;
    default: return kCGMouseButtonLeft;
    }
}

void tb_input_mouse_move(struct tb_input *in, int dx, int dy) {
    if (!in) return;
    tb_input_refresh_bounds(in);
    in->x += dx;
    in->y += dy;
    if (in->x < in->min_x) in->x = in->min_x;
    if (in->y < in->min_y) in->y = in->min_y;
    if (in->x > in->max_x) in->x = in->max_x;
    if (in->y > in->max_y) in->y = in->max_y;

    /* While a button is held, motion must be a drag of that button. */
    CGEventType type = kCGEventMouseMoved;
    CGMouseButton btn = kCGMouseButtonLeft;
    if (in->button_mask & TB_BTN_LEFT)        { type = kCGEventLeftMouseDragged;  btn = kCGMouseButtonLeft; }
    else if (in->button_mask & TB_BTN_RIGHT)  { type = kCGEventRightMouseDragged; btn = kCGMouseButtonRight; }
    else if (in->button_mask & TB_BTN_CENTER) { type = kCGEventOtherMouseDragged; btn = kCGMouseButtonCenter; }

    CGEventRef e = CGEventCreateMouseEvent(in->src, type, CGPointMake(in->x, in->y), btn);
    if (e) { CGEventPost(kCGHIDEventTap, e); CFRelease(e); }
}

void tb_input_mouse_button(struct tb_input *in, int button, int down) {
    if (!in) return;
    CGMouseButton btn = tb_cg_button(button);
    CGEventType type;
    int bit;
    if (button == 1)      { type = down ? kCGEventRightMouseDown : kCGEventRightMouseUp; bit = TB_BTN_RIGHT; }
    else if (button == 2) { type = down ? kCGEventOtherMouseDown : kCGEventOtherMouseUp; bit = TB_BTN_CENTER; }
    else                  { type = down ? kCGEventLeftMouseDown  : kCGEventLeftMouseUp;  bit = TB_BTN_LEFT; }

    if (down) in->button_mask |= bit;
    else      in->button_mask &= ~bit;

    CGEventRef e = CGEventCreateMouseEvent(in->src, type, CGPointMake(in->x, in->y), btn);
    if (e) {
        /* MVP: single clicks only; double-click fidelity is a v2 item. */
        CGEventSetIntegerValueField(e, kCGMouseEventClickState, 1);
        CGEventPost(kCGHIDEventTap, e);
        CFRelease(e);
    }
}

void tb_input_scroll(struct tb_input *in, int dx, int dy) {
    if (!in) return;
    /* wheel1 = vertical, wheel2 = horizontal. */
    CGEventRef e = CGEventCreateScrollWheelEvent(in->src, kCGScrollEventUnitLine, 2, dy, dx);
    if (e) { CGEventPost(kCGHIDEventTap, e); CFRelease(e); }
}

void tb_input_key(struct tb_input *in, int keycode, int down, uint64_t flags) {
    if (!in) return;
    CGEventRef e = CGEventCreateKeyboardEvent(in->src, (CGKeyCode)keycode, down ? true : false);
    if (e) {
        CGEventSetFlags(e, (CGEventFlags)flags);
        CGEventPost(kCGHIDEventTap, e);
        CFRelease(e);
    }
}

void tb_input_reset_modifiers(struct tb_input *in) {
    if (!in) return;
    /* L/R command, shift, option, control. (Caps Lock / Fn deliberately omitted.) */
    static const CGKeyCode mods[] = { 54, 55, 56, 60, 58, 61, 59, 62 };
    for (size_t i = 0; i < sizeof(mods) / sizeof(mods[0]); i++) {
        CGEventRef e = CGEventCreateKeyboardEvent(in->src, mods[i], false);
        if (e) {
            CGEventSetFlags(e, 0);
            CGEventPost(kCGHIDEventTap, e);
            CFRelease(e);
        }
    }
    in->button_mask = 0;
}
