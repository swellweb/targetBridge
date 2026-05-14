/* proto.h — TBDisplay monitor-emulation wire protocol constants.
 *
 * Wire format on the TCP stream:
 *   [4 bytes BE uint32 length][1 byte type][payload (length-1 bytes)]
 *
 * type 0x10 = hello receiver (JSON)
 * type 0x11 = display profile (JSON)
 * type 0x12 = create session ack (JSON)
 * type 0x20 = H.264 parameter sets (SPS/PPS)
 *   payload = [1 byte count] then for each: [4 bytes BE uint32 size][size bytes]
 *
 * type 0x21 = H.264 frame
 *   payload = AVCC-formatted NAL units, 4-byte BE length prefixes (no start codes)
 *
 * type 0x30 = heartbeat (JSON)
 * type 0x31 = teardown (JSON)
 *
 * Compatible with the new TBDisplaySender Swift app.
 */

#ifndef TB_PROTO_H
#define TB_PROTO_H

#include <stdint.h>

#define TB_PORT             54321
#define TB_PKT_HELLO_RECEIVER   0x10
#define TB_PKT_DISPLAY_PROFILE  0x11
#define TB_PKT_CREATE_SESSION_ACK 0x12
#define TB_PKT_PARAM_SETS       0x20
#define TB_PKT_FRAME            0x21
#define TB_PKT_HEARTBEAT        0x30
#define TB_PKT_TEARDOWN         0x31

#define TB_HDR_BYTES        5   /* 4 length + 1 type */

#endif
