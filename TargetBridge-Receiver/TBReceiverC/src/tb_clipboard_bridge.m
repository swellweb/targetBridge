#import "tb_clipboard_bridge.h"

#import <AppKit/AppKit.h>

#include <string.h>

int64_t tb_clipboard_change_count(void) {
    @autoreleasepool {
        return (int64_t)[NSPasteboard generalPasteboard].changeCount;
    }
}

int tb_clipboard_read_text(char *dest, size_t size) {
    if (!dest || size == 0) return 0;
    dest[0] = '\0';

    @autoreleasepool {
        NSString *value = [[NSPasteboard generalPasteboard]
            stringForType:NSPasteboardTypeString];
        if (!value) return 0;

        const char *utf8 = value.UTF8String;
        if (!utf8) return 0;
        size_t length = strlen(utf8);
        if (length >= size) length = size - 1;
        memcpy(dest, utf8, length);
        dest[length] = '\0';
        return 1;
    }
}

int tb_clipboard_write_text(const char *text) {
    @autoreleasepool {
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        [pasteboard clearContents];
        NSString *value = [NSString stringWithUTF8String:text ? text : ""];
        if (!value) return 0;
        return [pasteboard setString:value forType:NSPasteboardTypeString] ? 1 : 0;
    }
}
