/* tb_signin_mode.m — see tb_signin_mode.h. */

#import "tb_signin_mode.h"

#import <AppKit/AppKit.h>
#import <SystemConfiguration/SystemConfiguration.h>

#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int g_signin_active = 0;

void tb_signin_set_active(int active) {
    g_signin_active = active ? 1 : 0;
}

int tb_signin_active(void) {
    return g_signin_active;
}

void tb_signin_prepare_windows(void) {
    if (!g_signin_active) return;
    for (NSWindow *window in NSApp.windows) {
        /* Without this, AppKit keeps the window hidden while no user is
         * logged in. */
        window.canBecomeVisibleWithoutLogin = YES;
        window.collectionBehavior |= NSWindowCollectionBehaviorCanJoinAllSpaces |
                                     NSWindowCollectionBehaviorFullScreenAuxiliary;
    }
    /* Take the keyboard from the sign-in window while the picture is shown,
     * so Esc reaches the Receiver. */
    [NSApp activateIgnoringOtherApps:YES];
}

int tb_signin_console_user_logged_in(void) {
    uid_t uid = 0;
    CFStringRef user = SCDynamicStoreCopyConsoleUser(NULL, &uid, NULL);
    if (!user) return 0;
    const int logged_in = CFStringCompare(user, CFSTR("loginwindow"), 0) != kCFCompareEqualTo;
    CFRelease(user);
    return logged_in;
}

int tb_signin_installed(void) {
    return access(TB_SIGNIN_LAUNCH_AGENT_PATH, F_OK) == 0;
}

static void tb_signin_set_error(char *error, size_t error_size, NSString *message) {
    if (error && error_size > 0) {
        snprintf(error, error_size, "%s", message.UTF8String ? message.UTF8String : "unknown error");
    }
}

/* Runs `command` as root after the standard administrator prompt. */
static int tb_signin_run_as_admin(NSString *command, char *error, size_t error_size) {
    NSString *escaped = [[command stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
        stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSString *source = [NSString stringWithFormat:
        @"do shell script \"%@\" with administrator privileges", escaped];
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
    NSDictionary *info = nil;
    [script executeAndReturnError:&info];
    if (!info) return 0;
    NSNumber *code = info[NSAppleScriptErrorNumber];
    if (code.integerValue == -128) return 1; /* cancelled */
    tb_signin_set_error(error, error_size, info[NSAppleScriptErrorMessage] ?: @"unknown error");
    return -1;
}

static NSString *tb_signin_shell_quote(NSString *value) {
    return [NSString stringWithFormat:@"'%@'",
            [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

int tb_signin_install(char *error, size_t error_size) {
    @autoreleasepool {
        NSString *executable = NSBundle.mainBundle.executablePath;
        if (executable.length == 0) {
            tb_signin_set_error(error, error_size, @"Receiver executable not found");
            return -1;
        }
        NSDictionary *plist = @{
            @"Label": @TB_SIGNIN_LAUNCH_AGENT_LABEL,
            @"ProgramArguments": @[ executable, @"--login-window" ],
            /* Only in the sign-in window's session, never in a user's. */
            @"LimitLoadToSessionType": @"LoginWindow",
            @"RunAtLoad": @YES,
            /* Restart after a crash, but not after a normal exit (someone
             * logged in). */
            @"KeepAlive": @{ @"SuccessfulExit": @NO },
            @"ProcessType": @"Interactive",
            @"StandardOutPath": @TB_SIGNIN_LOG_PATH,
            @"StandardErrorPath": @TB_SIGNIN_LOG_PATH,
        };
        NSError *serializeError = nil;
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                                                                  format:NSPropertyListXMLFormat_v1_0
                                                                 options:0
                                                                   error:&serializeError];
        NSString *temp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          @TB_SIGNIN_LAUNCH_AGENT_LABEL ".plist"];
        if (!data || ![data writeToFile:temp atomically:YES]) {
            tb_signin_set_error(error, error_size,
                                serializeError.localizedDescription ?: @"could not write the LaunchAgent");
            return -1;
        }
        NSString *target = @TB_SIGNIN_LAUNCH_AGENT_PATH;
        NSString *command = [NSString stringWithFormat:
            @"/bin/mkdir -p /Library/LaunchAgents && "
             "/bin/cp %@ %@ && /usr/sbin/chown root:wheel %@ && /bin/chmod 644 %@",
            tb_signin_shell_quote(temp), tb_signin_shell_quote(target),
            tb_signin_shell_quote(target), tb_signin_shell_quote(target)];
        const int result = tb_signin_run_as_admin(command, error, error_size);
        [NSFileManager.defaultManager removeItemAtPath:temp error:nil];
        if (result == 0) fprintf(stderr, "[signin] installed %s\n", TB_SIGNIN_LAUNCH_AGENT_PATH);
        return result;
    }
}

int tb_signin_uninstall(char *error, size_t error_size) {
    @autoreleasepool {
        /* Stop a running sign-in screen instance (normally none while a user
         * is logged in), then remove the plist. */
        NSString *command = [NSString stringWithFormat:
            @"/usr/bin/pkill -f -- '--login-window' ; /bin/rm -f %@",
            tb_signin_shell_quote(@TB_SIGNIN_LAUNCH_AGENT_PATH)];
        const int result = tb_signin_run_as_admin(command, error, error_size);
        if (result == 0) fprintf(stderr, "[signin] uninstalled %s\n", TB_SIGNIN_LAUNCH_AGENT_PATH);
        return result;
    }
}
