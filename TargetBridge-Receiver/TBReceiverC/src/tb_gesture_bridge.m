#import "tb_gesture_bridge.h"

#import <AppKit/AppKit.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static NSWindow *tb_receiver_content_window(void) {
    NSWindow *content = nil;
    CGFloat best_area = 0.0;
    NSArray<NSWindow *> *windows = [NSApp windows];
    for (NSWindow *w in windows) {
        if (!w.isVisible) continue;
        NSSize s = w.frame.size;
        CGFloat area = s.width * s.height;
        if (area < 200.0 * 200.0) continue;
        if (area > best_area) {
            best_area = area;
            content = w;
        }
    }
    return content;
}

static BOOL g_monitor_shield_active = NO;

static void tb_apply_monitor_shield(void) {
    NSWindow *content = tb_receiver_content_window();
    if (!content) return;

    /* On the tested macOS release, Notification Center's fullscreen/banner
     * surface is below the public status-window level. That level is enough to
     * keep local banners and the menu bar behind the video without using the
     * much more invasive screen-saver/shielding levels or changing Focus. */
    NSWindowLevel desired = g_monitor_shield_active
        ? (NSWindowLevel)CGWindowLevelForKey(kCGStatusWindowLevelKey)
        : NSNormalWindowLevel;
    if (content.level != desired) {
        content.level = desired;
    }
}

void tb_receiver_set_monitor_shield(int active) {
    @autoreleasepool {
        BOOL normalized = active ? YES : NO;
        BOOL changed = normalized != g_monitor_shield_active;
        g_monitor_shield_active = normalized;
        tb_apply_monitor_shield();

        /* SDL completes part of the native fullscreen transition after
         * SDL_SetWindowFullscreen returns. Reapply once after that transition,
         * reading the latest desired state so a rapid Stop cannot re-raise the
         * window with a stale delayed block. */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            tb_apply_monitor_shield();
        });

        if (changed) {
            fprintf(stderr,
                    "[display] monitor shield=%d level=%ld\n",
                    normalized ? 1 : 0,
                    (long)(normalized
                        ? CGWindowLevelForKey(kCGStatusWindowLevelKey)
                        : NSNormalWindowLevel));
        }
    }
}

int tb_window_on_active_space(void *sdl_window) {
    /* Whether the receiver's content window is on the Space the user is
     * currently viewing. Used to gate receiverMaster forwarding so local work
     * on another (receiver-only) Space doesn't move the sender's cursor.
     *
     * We deliberately avoid SDL_GetWindowWMInfo here: it is version-gated and
     * fails when the app is compiled against newer SDL headers than the bundled
     * runtime (as happens on the Intel build), which would silently fail open.
     * Instead we find our largest visible window via NSApp and query the window
     * server directly with -[NSWindow isOnActiveSpace]. That is purely spatial,
     * so — unlike keyboard focus — it stays correct even when the receiver app
     * remains the active application on another Space. */
    (void)sdl_window;

    NSArray<NSWindow *> *windows = [NSApp windows];
    NSWindow *content = tb_receiver_content_window();
    CGFloat best_area = content ? content.frame.size.width * content.frame.size.height : 0.0;

    /* Fail open (forward) only when we genuinely can't find a content window. */
    int on_active = content ? (content.isOnActiveSpace ? 1 : 0) : 1;

    /* Log on decision flips only, to keep the input hot path quiet. */
    static int last = -1;
    if (on_active != last) {
        last = on_active;
        fprintf(stderr,
                "[input] forward-gate on_active_space=%d (window=%s area=%.0f "
                "collectionBehavior=0x%lx windows=%lu)\n",
                on_active, content ? "found" : "none", best_area,
                content ? (unsigned long)content.collectionBehavior : 0UL,
                (unsigned long)windows.count);
    }
    return on_active;
}

int tb_receiver_app_is_active(void) {
    @autoreleasepool {
        return NSApp.isActive ? 1 : 0;
    }
}

int tb_local_ui_above_receiver_at_point(void *sdl_window,
                                        double x,
                                        double y,
                                        char *owner_name,
                                        size_t owner_name_size) {
    (void)sdl_window;
    if (owner_name && owner_name_size > 0) owner_name[0] = '\0';

    @autoreleasepool {
        NSWindow *content = tb_receiver_content_window();
        if (!content) return 0;

        CGWindowID receiver_window = (CGWindowID)content.windowNumber;
        CFArrayRef copied = CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenAboveWindow |
                kCGWindowListExcludeDesktopElements,
            receiver_window);
        if (!copied) return 0;
        NSArray<NSDictionary *> *windows = CFBridgingRelease(copied);
        CGPoint point = CGPointMake(x, y);
        pid_t own_pid = getpid();

        for (NSDictionary *info in windows) {
            NSNumber *pid_value = info[(id)kCGWindowOwnerPID];
            if (!pid_value || pid_value.intValue <= 0 || pid_value.intValue == own_pid) continue;

            NSNumber *alpha_value = info[(id)kCGWindowAlpha];
            if (alpha_value && alpha_value.doubleValue <= 0.01) continue;

            NSDictionary *bounds_value = info[(id)kCGWindowBounds];
            CGRect bounds = CGRectZero;
            if (!bounds_value ||
                !CGRectMakeWithDictionaryRepresentation(
                    (__bridge CFDictionaryRef)bounds_value,
                    &bounds)) {
                continue;
            }
            if (bounds.size.width < 2.0 || bounds.size.height < 2.0) continue;
            if (!CGRectContainsPoint(bounds, point)) continue;

            NSString *owner = info[(id)kCGWindowOwnerName];
            const char *utf8 = owner.UTF8String;
            if (owner_name && owner_name_size > 0 && utf8) {
                snprintf(owner_name, owner_name_size, "%s", utf8);
            }
            return 1;
        }
    }
    return 0;
}

static tb_gesture_space_switch_callback g_callback = NULL;
static void *g_context = NULL;
static id g_swipe_monitor = nil;
static id g_scroll_monitor = nil;
static id g_key_down_monitor = nil;
static id g_key_up_monitor = nil;
static id g_flags_monitor = nil;
static id g_system_defined_monitor = nil;
static BOOL g_active = NO;
static NSTimeInterval g_last_horizontal_gesture_at = 0.0;
static CGFloat g_horizontal_accumulator = 0.0;
static NSTimeInterval g_last_switch_at = 0.0;

static BOOL tb_should_handle_horizontal_scroll(NSEvent *event) {
    if (!event || !g_active) return NO;
    CGFloat dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX;
    CGFloat dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY;
    if (fabs(dx) <= fabs(dy) * 1.5) return NO;
    NSEventPhase phase = event.phase;
    NSEventPhase momentum = event.momentumPhase;
    return event.hasPreciseScrollingDeltas || phase != NSEventPhaseNone || momentum != NSEventPhaseNone;
}

void tb_gesture_bridge_install(tb_gesture_space_switch_callback callback, void *context) {
    g_callback = callback;
    g_context = context;

    if (g_swipe_monitor || g_scroll_monitor || g_key_down_monitor || g_key_up_monitor || g_flags_monitor || g_system_defined_monitor) {
        return;
    }

    g_swipe_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskSwipe
                                                            handler:^NSEvent * _Nullable(NSEvent * _Nonnull event) {
        if (!g_active || !g_callback) return event;
        CGFloat dx = event.deltaX;
        if (fabs(dx) < 0.01) return event;
        g_callback(dx > 0 ? 1 : -1, g_context);
        g_last_switch_at = event.timestamp;
        return nil;
    }];

    g_scroll_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel
                                                             handler:^NSEvent * _Nullable(NSEvent * _Nonnull event) {
        if (!tb_should_handle_horizontal_scroll(event)) return event;

        NSTimeInterval now = event.timestamp;
        if (now - g_last_horizontal_gesture_at > 0.25) {
            g_horizontal_accumulator = 0.0;
        }
        g_last_horizontal_gesture_at = now;

        CGFloat dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX;
        g_horizontal_accumulator += dx;

        if (fabs(g_horizontal_accumulator) >= 30.0 && now - g_last_switch_at > 0.45 && g_callback) {
            g_callback(g_horizontal_accumulator > 0 ? 1 : -1, g_context);
            g_last_switch_at = now;
            g_horizontal_accumulator = 0.0;
        }
        return nil;
    }];

    g_key_down_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                               handler:^NSEvent * _Nullable(NSEvent * _Nonnull event) {
        if (!g_active) return event;
        return nil;
    }];

    g_key_up_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyUp
                                                             handler:^NSEvent * _Nullable(NSEvent * _Nonnull event) {
        if (!g_active) return event;
        return nil;
    }];

    g_flags_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged
                                                            handler:^NSEvent * _Nullable(NSEvent * _Nonnull event) {
        if (!g_active) return event;
        return nil;
    }];

    g_system_defined_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskSystemDefined
                                                                     handler:^NSEvent * _Nullable(NSEvent * _Nonnull event) {
        if (!g_active) return event;
        return nil;
    }];
}

void tb_gesture_bridge_set_active(int active) {
    g_active = active ? YES : NO;
    if (!g_active) {
        g_horizontal_accumulator = 0.0;
        g_last_horizontal_gesture_at = 0.0;
    }
}
