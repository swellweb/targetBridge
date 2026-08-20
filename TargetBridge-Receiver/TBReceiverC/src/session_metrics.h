#ifndef TB_SESSION_METRICS_H
#define TB_SESSION_METRICS_H

#include <stddef.h>
#include <stdint.h>

/* Build the compact JSON payload carried by TB_PKT_SESSION_METRICS.
 * Returns the byte length (excluding the trailing NUL), or -1 when the
 * destination is too small. String values must be stable backend names; the
 * receiver only supplies its own fixed labels, never user-provided text. */
int tb_session_metrics_json(char *dst,
                            size_t dst_size,
                            uint64_t receiver_fps,
                            uint64_t rendered_frames,
                            uint64_t decode_errors,
                            const char *renderer,
                            const char *decoder,
                            const char *codec);

#endif /* TB_SESSION_METRICS_H */
