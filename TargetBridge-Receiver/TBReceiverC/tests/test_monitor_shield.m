#import "../src/tb_gesture_bridge.m"
#include <assert.h>

static void pump(double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([end timeIntervalSinceNow] > 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:end];
    }
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 320, 240)
            styleMask:NSWindowStyleMaskTitled
            backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed = NO;
        [window orderFrontRegardless];

        tb_receiver_set_monitor_shield(1);
        uint64_t generation = g_monitor_shield_generation;
        assert(g_monitor_shield_observers.count == 5);
        assert(window.level == tb_monitor_shield_level());
        for (int i = 0; i < 20; i++) tb_receiver_set_monitor_shield(1);
        assert(generation == g_monitor_shield_generation);
        assert(g_monitor_shield_observers.count == 5);

        window.level = NSNormalWindowLevel;
        pump(0.35);
        assert(window.level == tb_monitor_shield_level());

        tb_receiver_set_monitor_shield(0);
        assert(g_monitor_shield_observers == nil);
        assert(window.level == NSNormalWindowLevel);
        pump(2.3);
        assert(window.level == NSNormalWindowLevel);

        tb_receiver_set_monitor_shield(1);
        pump(2.6);
        window.level = NSNormalWindowLevel;
        [[NSNotificationCenter defaultCenter]
            postNotificationName:NSWindowDidChangeBackingPropertiesNotification
            object:window];
        pump(0.35);
        assert(window.level == tb_monitor_shield_level());
        tb_receiver_set_monitor_shield(0);
        assert(window.level == NSNormalWindowLevel);
        assert(g_monitor_shield_observers == nil);
        [window close];
        puts("monitor shield lifecycle: passed");
    }
    return 0;
}
