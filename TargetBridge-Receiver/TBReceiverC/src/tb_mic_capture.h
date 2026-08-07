/* tb_mic_capture.h — capture this Mac's microphone and hand it to the sender.
 * Delivers 48 kHz stereo interleaved Int16, matching the rest of the wire
 * format so nothing converts along the way. */

#ifndef TB_MIC_CAPTURE_H
#define TB_MIC_CAPTURE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Called on a private queue, not the main thread. */
typedef void (*tb_mic_cb)(const uint8_t *pcm, size_t bytes, void *user_data);

/* 1 if this Mac has an audio input device at all. */
int  tb_mic_capture_available(void);

/* 0 on success. Returns -1 if microphone access has not been granted yet —
 * the request is kicked off, so a later retry can succeed. */
int  tb_mic_capture_start(tb_mic_cb cb, void *user_data);
void tb_mic_capture_stop(void);

#ifdef __cplusplus
}
#endif

#endif
