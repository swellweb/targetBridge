/* input.h — Software-KVM input injection into the receiver Mac's native session.
 *
 * Forwarded sender keyboard/mouse events are re-synthesized here via
 * CoreGraphics CGEventPost(kCGHIDEventTap, ...). Requires the receiver process
 * to be granted Accessibility (System Settings -> Privacy & Security ->
 * Accessibility); without it, posting silently no-ops.
 */

#ifndef TB_INPUT_H
#define TB_INPUT_H

#include <stdint.h>

struct tb_input;

struct tb_input *tb_input_create(void);
void             tb_input_destroy(struct tb_input *in);

/* 1 if Accessibility is granted (posted events will reach the native session). */
int  tb_input_accessibility_ok(struct tb_input *in);

/* Relative pointer motion (OS-accelerated deltas from the sender). The receiver
 * owns the cursor: deltas are applied to a tracked position, clamped to the
 * main display, and posted as a moved/dragged event at that point. */
void tb_input_mouse_move(struct tb_input *in, int dx, int dy);

/* Mouse button transition. button: 0=left, 1=right, 2=center. */
void tb_input_mouse_button(struct tb_input *in, int button, int down);

/* Scroll-wheel delta in line units. */
void tb_input_scroll(struct tb_input *in, int dx, int dy);

/* Key transition. keycode = virtual CGKeyCode; flags = raw CGEventFlags mask. */
void tb_input_key(struct tb_input *in, int keycode, int down, uint64_t flags);

/* Release all modifier keys + clear button state. Called when KVM control is
 * toggled so a chord like the sender's ⌃⌥⌘K escape can't leave modifiers stuck. */
void tb_input_reset_modifiers(struct tb_input *in);

#endif
