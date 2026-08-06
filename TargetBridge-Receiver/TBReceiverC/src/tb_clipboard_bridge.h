#ifndef TB_CLIPBOARD_BRIDGE_H
#define TB_CLIPBOARD_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

/* AppKit pasteboard access without spawning pbcopy/pbpaste processes. */
int64_t tb_clipboard_change_count(void);
int     tb_clipboard_read_text(char *dest, size_t size);
int     tb_clipboard_write_text(const char *text);

#endif
