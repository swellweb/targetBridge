/* tb_display_tweaks.m — Night Shift and True Tone on the receiver's panel.
 *
 * Both live in the private CoreBrightness framework, so they are reached the
 * same way this app already reaches DisplayServices for brightness: dlopen the
 * framework and go through the Objective-C runtime, so a missing class or a
 * renamed selector degrades to "unsupported" instead of breaking the build or
 * crashing on a future macOS.
 *
 * Night Shift is CBBlueLightClient (setEnabled:).
 * True Tone is CBTrueToneClient, which has no setter — it is activate/deactivate.
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>

#include "tb_display_tweaks.h"

static void tb_load_core_brightness(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
               RTLD_LAZY);
    });
}

/* Call a no-argument BOOL getter, returning 0 if the selector is absent. */
static int tb_bool_getter(id obj, SEL sel) {
    if (!obj || ![obj respondsToSelector:sel]) return 0;
    IMP imp = [obj methodForSelector:sel];
    if (!imp) return 0;
    BOOL (*fn)(id, SEL) = (BOOL (*)(id, SEL))imp;
    return fn(obj, sel) ? 1 : 0;
}

/* ---- Night Shift ------------------------------------------------------- */

static id tb_blue_light_client(void) {
    static id client = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tb_load_core_brightness();
        Class cls = NSClassFromString(@"CBBlueLightClient");
        if (cls) client = [[cls alloc] init];
    });
    return client;
}

int tb_night_shift_supported(void) {
    return tb_bool_getter(tb_blue_light_client(), @selector(supported));
}

int tb_night_shift_enabled(void) {
    id c = tb_blue_light_client();
    SEL sel = @selector(getBlueLightStatus:);
    if (!c || ![c respondsToSelector:sel]) return 0;
    IMP imp = [c methodForSelector:sel];
    if (!imp) return 0;

    /* CBBlueLightClient has no `enabled` getter — only getBlueLightStatus:,
     * which fills a private struct whose first two bytes are BOOL active then
     * BOOL enabled. The layout is not API, so read defensively: a generously
     * oversized zeroed buffer means a larger struct on some macOS version
     * cannot overflow, and a changed layout misreports the state rather than
     * crashing. Worst case the menu shows a stale toggle. */
    unsigned char status[256];
    memset(status, 0, sizeof(status));
    BOOL (*fn)(id, SEL, void *) = (BOOL (*)(id, SEL, void *))imp;
    if (!fn(c, sel, status)) return 0;
    return status[1] ? 1 : 0;
}

int tb_night_shift_set(int enabled) {
    id c = tb_blue_light_client();
    SEL sel = @selector(setEnabled:);
    if (!c || ![c respondsToSelector:sel]) return -1;
    IMP imp = [c methodForSelector:sel];
    if (!imp) return -1;
    BOOL (*fn)(id, SEL, BOOL) = (BOOL (*)(id, SEL, BOOL))imp;
    fn(c, sel, enabled ? YES : NO);
    return 0;
}

/* ---- True Tone -------------------------------------------------------- */

static id tb_true_tone_client(void) {
    static id client = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tb_load_core_brightness();
        Class cls = NSClassFromString(@"CBTrueToneClient");
        if (cls) client = [[cls alloc] init];
    });
    return client;
}

int tb_true_tone_supported(void) {
    id c = tb_true_tone_client();
    if (!c) return 0;
    /* `supported` means the hardware has it; `available` means it can be used
     * right now — it goes unavailable under some display profiles. Both must
     * hold before offering the toggle. */
    return tb_bool_getter(c, @selector(supported)) && tb_bool_getter(c, @selector(available));
}

int tb_true_tone_enabled(void) {
    return tb_bool_getter(tb_true_tone_client(), @selector(enabled));
}

int tb_true_tone_set(int enabled) {
    id c = tb_true_tone_client();
    if (!c) return -1;

    /* setEnabled: is the real switch. activate/deactivate look like the obvious
     * pair and are not: measured on macOS 15, deactivate leaves `enabled`
     * reporting 1 and the panel unchanged — they activate the *client session*,
     * not the feature. Keep them only as a fallback for an OS that lacks the
     * setter, so a missing selector degrades instead of failing outright. */
    SEL set = @selector(setEnabled:);
    if ([c respondsToSelector:set]) {
        IMP imp = [c methodForSelector:set];
        if (imp) {
            BOOL (*fn)(id, SEL, BOOL) = (BOOL (*)(id, SEL, BOOL))imp;
            return fn(c, set, enabled ? YES : NO) ? 0 : -1;
        }
    }

    SEL sel = enabled ? @selector(activate) : @selector(deactivate);
    if (![c respondsToSelector:sel]) return -1;
    IMP imp = [c methodForSelector:sel];
    if (!imp) return -1;
    void (*fn)(id, SEL) = (void (*)(id, SEL))imp;
    fn(c, sel);
    return 0;
}
