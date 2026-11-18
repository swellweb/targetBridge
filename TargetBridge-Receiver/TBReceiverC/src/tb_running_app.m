/* tb_running_app.m — see tb_running_app.h. */

#include "tb_running_app.h"

#import <AppKit/AppKit.h>

#include <unistd.h>

int tb_running_app_activate(const char *bundle_id) {
    if (!bundle_id || !*bundle_id) return 0;
    @autoreleasepool {
        NSString *identifier = [NSString stringWithUTF8String:bundle_id];
        if (!identifier) return 0;
        const pid_t self = getpid();
        for (NSRunningApplication *app in
             [NSRunningApplication runningApplicationsWithBundleIdentifier:identifier]) {
            if (app.processIdentifier == self || app.terminated) continue;
            [app activateWithOptions:NSApplicationActivateAllWindows];
            return 1;
        }
    }
    return 0;
}
