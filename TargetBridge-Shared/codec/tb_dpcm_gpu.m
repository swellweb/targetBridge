/* tb_dpcm_gpu.m — TBD2 encoder on the GPU. See tb_dpcm_gpu.h for the shape of
 * the pipeline and why it is split the way it is.
 *
 * Everything the shaders and the host both need to agree on — the tile walk, the
 * residual transform, the group alignment rule — is duplicated here from
 * tb_dpcm.c because MSL cannot include C. That duplication is the main hazard in
 * this file, so it is verified rather than trusted: the encoder's output is
 * compared byte-for-byte against tb_dpcm_encode's, which is the only reason to
 * believe any of it.
 */

#import <Metal/Metal.h>

#include "tb_dpcm_gpu.h"
#include "tb_dpcm.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Mirrors EncParams in the shader. */
struct enc_params {
    uint32_t width, height;
    uint32_t tilesX, tilesY;
    uint32_t tileCount;
    uint32_t srcStridePx;
    uint32_t bits;
    uint32_t mask;
    /* Named `mid`, not `half`: `half` is a reserved type in Metal Shading
     * Language (half-precision float) and a member of that name will not parse. */
    uint32_t mid;
};

/* Where every plane of every band sits. Identical for all bands of a frame —
 * same width, same height — which is what lets one frame be a single dispatch
 * loop over fixed strides. */
struct enc_geom {
    int      tiles_x, tiles_y;
    uint32_t tile_count, group_count;
    size_t   width_plane_bytes, seed_plane_bytes;
    size_t   group_table_off, width_plane_off, seed_plane_off, payload_off;
    size_t   blob_off, band_span, meta_span, offs_span;
};

/* One frame's worth of GPU-visible state.
 *
 * The blocking path can reuse a single set of buffers because nothing else is
 * running when it returns. The non-blocking path cannot: frame N is still being
 * read by the GPU while N+1 is being submitted, so each in-flight frame needs
 * its own blob, meta and offs. That is the entire memory cost of going async.
 */
struct tb_dpcm_gpu_job {
    id<MTLBuffer> blob;  size_t blob_cap;
    id<MTLBuffer> meta;  size_t meta_cap;
    id<MTLBuffer> offs;  size_t offs_cap;
    /* One uint per band: the payload bit count, written by the GPU plan. The
     * host reads it in the completion handler, which is the only host touch of
     * this frame's data and happens after everything is done. */
    id<MTLBuffer> bits;  size_t bits_cap;
    /* Per-group rounded totals, the middle of the three-kernel plan. */
    id<MTLBuffer> gtot;  size_t gtot_cap;
    id<MTLBuffer> src;             /* retained until the GPU is done reading */

    struct enc_geom  g;
    struct enc_params P;
    int              band_count;
    int              w, band_h, ten_bit;
    size_t           header_reserve, band_bytes;
    size_t           payload_bytes[TB_DPCM_GPU_MAX_BANDS];
    tb_dpcm_gpu_band bands[TB_DPCM_GPU_MAX_BANDS];

    tb_dpcm_gpu_done done;
    void            *ctx;
};

struct tb_dpcm_gpu {
    id<MTLDevice>               dev;
    id<MTLCommandQueue>         queue;
    id<MTLComputePipelineState> analyze;
    id<MTLComputePipelineState> pack;
    /* The plan step, moved off the host — see the shader comment. */
    id<MTLComputePipelineState> scanGroups;
    id<MTLComputePipelineState> scanBases;
    id<MTLComputePipelineState> applyBases;
    id<MTLComputePipelineState> zeroPayload;

    /* Non-blocking path. `plan` is serial, which is what keeps completions in
     * submission order; `slots` is what applies backpressure when every job is
     * busy. */
    struct tb_dpcm_gpu_job jobs[TB_DPCM_GPU_JOBS];
    dispatch_queue_t       plan_q;
    dispatch_semaphore_t   slots;
    int                    next_job;


    /* Reused across frames; grown, never shrunk. */
    id<MTLBuffer> blob;        /* the whole encoded frame, shared */
    size_t        blob_cap;
    id<MTLBuffer> meta;        /* 2 uints per tile: packed widths, bit cost */
    size_t        meta_cap;
    id<MTLBuffer> offs;        /* 1 uint per tile: payload bit offset */
    size_t        offs_cap;
    id<MTLBuffer> staged;      /* only used when src cannot be read in place */
    size_t        staged_cap;

    int  last_zero_copy;
    char name[128];
};

/* ------------------------------------------------------------------- shaders */

static NSString *tb_enc_shader_source(void) {
    return
    @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "\n"
    "struct EncParams {\n"
    "  uint width, height, tilesX, tilesY, tileCount;\n"
    "  uint srcStridePx;\n"
    "  uint bits, mask, mid;\n"
    "};\n"
    "\n"
    "static inline uint tb_sample(uint px, uint c, constant EncParams &P) {\n"
    "  return (px >> (c * P.bits)) & P.mask;\n"
    "}\n"
    /* The modular difference, re-centred and zigzagged. Must match
     * resid_encode() in tb_dpcm.c exactly. */
    "static inline uint tb_resid(uint cur, uint pred, constant EncParams &P) {\n"
    "  int d = int((cur - pred + P.mid) & P.mask) - int(P.mid);\n"
    "  return uint((d << 1) ^ (d >> 31));\n"
    "}\n"
    "\n"
    /* ---- step 1: bit widths, seeds and costs ----
     * One threadgroup per tile, one thread per pixel. Prediction reads original
     * samples, so every thread is independent — the serial dependency that
     * shapes the DECODER does not exist on this side. */
    "kernel void tb_enc_analyze(device const uint *src   [[buffer(0)]],\n"
    "                           device       uint *meta  [[buffer(1)]],\n"
    "                           device       uint *seeds [[buffer(2)]],\n"
    "                           constant EncParams &P    [[buffer(3)]],\n"
    "                           uint tile [[threadgroup_position_in_grid]],\n"
    "                           uint lane [[thread_position_in_threadgroup]]) {\n"
    "  const uint x = lane & 7u, y = lane >> 3;\n"
    "  const uint txi = tile % P.tilesX, tyi = tile / P.tilesX;\n"
    "  const uint tx = txi * 8u, ty = tyi * 8u;\n"
    "  const uint tw = min(8u, P.width  - tx);\n"
    "  const uint th = min(8u, P.height - ty);\n"
    "  const bool live = (x < tw && y < th) && !(x == 0u && y == 0u);\n"
    "\n"
    "  uint3 z = uint3(0u);\n"
    "  if (live) {\n"
    "    const uint pxi = (x > 0u) ? (x - 1u) : 0u;\n"
    "    const uint pyi = (x > 0u) ? y : (y - 1u);\n"
    "    const uint cur  = src[(ty + y)   * P.srcStridePx + (tx + x)];\n"
    "    const uint pred = src[(ty + pyi) * P.srcStridePx + (tx + pxi)];\n"
    "    z.x = tb_resid(tb_sample(cur, 0u, P), tb_sample(pred, 0u, P), P);\n"
    "    z.y = tb_resid(tb_sample(cur, 1u, P), tb_sample(pred, 1u, P), P);\n"
    "    z.z = tb_resid(tb_sample(cur, 2u, P), tb_sample(pred, 2u, P), P);\n"
    "  }\n"
    "\n"
    "  threadgroup uint3 red[64];\n"
    "  red[lane] = z;\n"
    "  threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "  for (uint off = 32u; off > 0u; off >>= 1) {\n"
    "    if (lane < off) red[lane] = max(red[lane], red[lane + off]);\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "  }\n"
    "  if (lane != 0u) return;\n"
    "\n"
    "  const uint3 m = red[0];\n"
    "  const uint n0 = (m.x == 0u) ? 0u : (32u - clz(m.x));\n"
    "  const uint n1 = (m.y == 0u) ? 0u : (32u - clz(m.y));\n"
    "  const uint n2 = (m.z == 0u) ? 0u : (32u - clz(m.z));\n"
    "  meta[tile * 2u + 0u] = n0 | (n1 << 8) | (n2 << 16);\n"
    "  meta[tile * 2u + 1u] = (n0 + n1 + n2) * (tw * th - 1u);\n"
    /* The seed is the tile's top-left pixel with alpha stripped; the decoder
     * puts opaque alpha back. */
    "  const uint alphaMask = (P.bits == 10u) ? (3u << 30) : (0xFFu << 24);\n"
    "  seeds[tile] = src[ty * P.srcStridePx + tx] & ~alphaMask;\n"
    "}\n"
    "\n"
    /* ---- step 3: pack ----
     * One thread per (tile, channel). Each owns a contiguous run of bits, so it
     * batches into whole words and touches memory atomically only where its run
     * shares a word with a neighbour's — the first and the last.
     *
     * `payload` and `payloadAtomic` are the same buffer bound twice: interior
     * words belong to exactly one thread and can be stored plainly, which is the
     * whole point of the batching. */
    /* ---- step 2, on the GPU: the plan ----
     *
     * This ran on the host between the two GPU passes, which is why the encoder
     * had to round-trip at all. It is O(tiles): a prefix sum of per-tile bit
     * costs into each tile's bit offset, the group table, and the packed width
     * nibbles.
     *
     * It looks sequential because each group's start is rounded up to a byte:
     *
     *     if (t % 64 == 0) bitpos = (bitpos + 7) & ~7;
     *
     * But every group base is ITSELF a multiple of 8, and for a = 0 (mod 8),
     * round8(a + b) == a + round8(b). So
     *
     *     base[g] = base[g-1] + round8(groupTotal[g-1])
     *
     * is an ordinary prefix sum over ROUNDED group totals. Verified against the
     * sequential algorithm on 20000 random layouts before any of this was
     * written (scratchpad/scan_check.c).
     *
     * Three kernels: within-group scan, scan of the group bases, then add.
     */
    "kernel void tb_enc_scan_groups(device const uint *meta   [[buffer(0)]],\n"
    "                               device       uint *offs   [[buffer(1)]],\n"
    "                               device       uint *gtotal [[buffer(2)]],\n"
    "                               device atomic_uint *widths[[buffer(3)]],\n"
    "                               constant EncParams &P     [[buffer(4)]],\n"
    "                               uint grp  [[threadgroup_position_in_grid]],\n"
    "                               uint lane [[thread_position_in_threadgroup]]) {\n"
    "  const uint tile = grp * 64u + lane;\n"
    "  const uint cost = (tile < P.tileCount) ? meta[tile * 2u + 1u] : 0u;\n"
    "\n"
    /* Hillis-Steele exclusive scan over the group's 64 costs. */
    "  threadgroup uint sh[64];\n"
    "  sh[lane] = cost;\n"
    "  threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "  for (uint off = 1u; off < 64u; off <<= 1) {\n"
    "    uint v = (lane >= off) ? sh[lane - off] : 0u;\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    sh[lane] += v;\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "  }\n"
    "  const uint inclusive = sh[lane];\n"
    "  const uint exclusive = inclusive - cost;\n"
    "\n"
    "  if (tile < P.tileCount) offs[tile] = exclusive;\n"
    /* Lane 63 holds the group's inclusive total; round it here so the next pass
     * is a plain sum. */
    "  if (lane == 63u) gtotal[grp] = (sh[63] + 7u) & ~7u;\n"
    "\n"
    /* Width nibbles. Tile t owns nibbles 3t..3t+2, and neighbouring tiles share
     * a byte, so this merges atomically into 32-bit words rather than assigning
     * bytes to threads. */
    "  if (tile < P.tileCount) {\n"
    "    const uint packed = meta[tile * 2u + 0u];\n"
    "    for (uint c = 0u; c < 3u; ++c) {\n"
    "      const uint idx = tile * 3u + c;\n"
    "      const uint n   = (packed >> (8u * c)) & 0xFu;\n"
    "      const uint bit = (idx & 1u) ? 4u : 0u;\n"
    "      const uint byteIdx = idx >> 1;\n"
    "      const uint word    = byteIdx >> 2;\n"
    "      const uint shift   = ((byteIdx & 3u) * 8u) + bit;\n"
    "      atomic_fetch_or_explicit(&widths[word], n << shift, memory_order_relaxed);\n"
    "    }\n"
    "  }\n"
    "}\n"
    "\n"
    /* Exclusive prefix sum over the rounded group totals, one threadgroup.
     * groupCount is at most a few thousand, so a strided serial accumulate by a
     * single lane is simpler than a multi-pass scan and costs microseconds. */
    "kernel void tb_enc_scan_bases(device uint *gtotal      [[buffer(0)]],\n"
    "                              device uint *groupTable  [[buffer(1)]],\n"
    "                              device uint *outTotalBits[[buffer(2)]],\n"
    "                              device const uint *meta   [[buffer(3)]],\n"
    "                              constant EncParams &P     [[buffer(4)]],\n"
    "                              uint lane [[thread_position_in_threadgroup]]) {\n"
    "  if (lane != 0u) return;\n"
    "  const uint groups = (P.tileCount + 63u) / 64u;\n"
    "  uint acc = 0u;\n"
    "  for (uint g = 0u; g < groups; ++g) {\n"
    "    groupTable[g] = acc;\n"
    "    acc += gtotal[g];\n"
    "  }\n"
    /* The payload length uses the LAST group's unrounded total, not the rounded
     * one -- trailing alignment is not part of the stream. */
    "  const uint lastBase = groupTable[groups - 1u];\n"
    "  uint lastSum = 0u;\n"
    "  const uint first = (groups - 1u) * 64u;\n"
    "  for (uint t = first; t < P.tileCount; ++t) lastSum += meta[t * 2u + 1u];\n"
    "  outTotalBits[0] = lastBase + lastSum;\n"
    "}\n"
    "\n"
    /* Zero the payload before the packer merges into it.
     *
     * A blit fill cannot do this any more: the length is computed on the GPU and
     * the host no longer knows it at encode time. Dispatched over the WORST-CASE
     * word count with an early-out, which costs nothing for the threads that
     * exit -- the alternative, filling the worst case unconditionally, would be
     * ~59 MB of writes per frame. */
    "kernel void tb_enc_zero_payload(device uint *payload      [[buffer(0)]],\n"
    "                                device const uint *totalBits[[buffer(1)]],\n"
    "                                uint w [[thread_position_in_grid]]) {\n"
    "  const uint words = (totalBits[0] + 31u) / 32u + 1u;\n"
    "  if (w >= words) return;\n"
    "  payload[w] = 0u;\n"
    "}\n"
    "\n"
    /* offs[] currently holds each tile's offset within its group; add the base. */
    "kernel void tb_enc_apply_bases(device uint *offs            [[buffer(0)]],\n"
    "                               device const uint *groupTable[[buffer(1)]],\n"
    "                               constant EncParams &P        [[buffer(2)]],\n"
    "                               uint tile [[thread_position_in_grid]]) {\n"
    "  if (tile >= P.tileCount) return;\n"
    "  offs[tile] += groupTable[tile >> 6];\n"
    "}\n"
    "\n"
    "kernel void tb_enc_pack(device const uint *src           [[buffer(0)]],\n"
    "                        device const uint *meta          [[buffer(1)]],\n"
    "                        device const uint *offs          [[buffer(2)]],\n"
    "                        device       uint *payload       [[buffer(3)]],\n"
    "                        device atomic_uint *payloadAtomic[[buffer(4)]],\n"
    "                        constant EncParams &P            [[buffer(5)]],\n"
    "                        uint gid [[thread_position_in_grid]]) {\n"
    "  const uint tile = gid / 3u, c = gid % 3u;\n"
    "  if (tile >= P.tileCount) return;\n"
    "\n"
    "  const uint packed = meta[tile * 2u + 0u];\n"
    "  const uint n = (packed >> (8u * c)) & 0xFFu;\n"
    "  if (n == 0u) return;\n"
    "\n"
    "  const uint txi = tile % P.tilesX, tyi = tile / P.tilesX;\n"
    "  const uint tx = txi * 8u, ty = tyi * 8u;\n"
    "  const uint tw = min(8u, P.width  - tx);\n"
    "  const uint th = min(8u, P.height - ty);\n"
    "  const uint coded = tw * th - 1u;\n"
    "\n"
    /* Channels are laid out one after another within a tile. */
    "  uint base = offs[tile];\n"
    "  for (uint k = 0u; k < c; ++k) base += ((packed >> (8u * k)) & 0xFFu) * coded;\n"
    "\n"
    "  uint word = base >> 5;\n"
    "  uint fill = base & 31u;      /* bits of this word already spoken for */\n"
    "  uint acc  = 0u;\n"
    "  bool first = true;\n"
    "\n"
    "  for (uint i = 0u; i < coded; ++i) {\n"
    /* Same traversal as TB_TILE_WALK: raster order, skipping the seed. */
    "    const uint idx = i + 1u;\n"
    "    const uint x = idx % tw, y = idx / tw;\n"
    "    const uint pxi = (x > 0u) ? (x - 1u) : 0u;\n"
    "    const uint pyi = (x > 0u) ? y : (y - 1u);\n"
    "    const uint cur  = src[(ty + y)   * P.srcStridePx + (tx + x)];\n"
    "    const uint pred = src[(ty + pyi) * P.srcStridePx + (tx + pxi)];\n"
    "    const uint v = tb_resid(tb_sample(cur, c, P), tb_sample(pred, c, P), P);\n"
    "\n"
    "    const uint room = 32u - fill;\n"
    "    const uint lo   = min(n, room);\n"
    "    acc |= (v & ((1u << lo) - 1u)) << fill;\n"
    "    if (n > lo) {\n"
    "      if (first) { atomic_fetch_or_explicit(&payloadAtomic[word], acc, memory_order_relaxed); first = false; }\n"
    "      else       { payload[word] = acc; }\n"
    "      word += 1u;\n"
    "      acc   = v >> lo;\n"
    "      fill  = n - lo;\n"
    "    } else {\n"
    "      fill += lo;\n"
    "      if (fill == 32u) {\n"
    "        if (first) { atomic_fetch_or_explicit(&payloadAtomic[word], acc, memory_order_relaxed); first = false; }\n"
    "        else       { payload[word] = acc; }\n"
    "        word += 1u;\n"
    "        acc   = 0u;\n"
    "        fill  = 0u;\n"
    "      }\n"
    "    }\n"
    "  }\n"
    /* The tail always merges: the next thread's run starts inside this word. */
    "  if (fill != 0u || first) {\n"
    "    atomic_fetch_or_explicit(&payloadAtomic[word], acc, memory_order_relaxed);\n"
    "  }\n"
    "}\n";
}

/* ---------------------------------------------------------------------- setup */

tb_dpcm_gpu *tb_dpcm_gpu_create(void) {
    tb_dpcm_gpu *e = calloc(1, sizeof(*e));
    if (!e) return NULL;

    @autoreleasepool {
        e->dev = MTLCreateSystemDefaultDevice();
        if (!e->dev) { free(e); return NULL; }

        NSError *err = nil;
        id<MTLLibrary> lib = [e->dev newLibraryWithSource:tb_enc_shader_source()
                                                 options:nil error:&err];
        if (!lib) {
            fprintf(stderr, "[dpcm-gpu] shader failed: %s\n",
                    err.localizedDescription.UTF8String ?: "?");
            free(e);
            return NULL;
        }
        e->analyze = [e->dev newComputePipelineStateWithFunction:
                          [lib newFunctionWithName:@"tb_enc_analyze"] error:&err];
        e->pack    = [e->dev newComputePipelineStateWithFunction:
                          [lib newFunctionWithName:@"tb_enc_pack"] error:&err];
        e->scanGroups = [e->dev newComputePipelineStateWithFunction:
                          [lib newFunctionWithName:@"tb_enc_scan_groups"] error:&err];
        e->scanBases  = [e->dev newComputePipelineStateWithFunction:
                          [lib newFunctionWithName:@"tb_enc_scan_bases"] error:&err];
        e->applyBases = [e->dev newComputePipelineStateWithFunction:
                          [lib newFunctionWithName:@"tb_enc_apply_bases"] error:&err];
        e->zeroPayload = [e->dev newComputePipelineStateWithFunction:
                          [lib newFunctionWithName:@"tb_enc_zero_payload"] error:&err];
        if (!e->analyze || !e->pack || !e->scanGroups || !e->scanBases ||
            !e->applyBases || !e->zeroPayload) {
            fprintf(stderr, "[dpcm-gpu] pipeline failed: %s\n",
                    err.localizedDescription.UTF8String ?: "?");
            free(e);
            return NULL;
        }
        e->queue = [e->dev newCommandQueue];
        e->plan_q = dispatch_queue_create("com.targetbridge.dpcm.plan",
                                          DISPATCH_QUEUE_SERIAL);
        e->slots  = dispatch_semaphore_create(TB_DPCM_GPU_JOBS);
        snprintf(e->name, sizeof(e->name), "%s", [[e->dev name] UTF8String]);
    }
    return e;
}

void tb_dpcm_gpu_destroy(tb_dpcm_gpu *e) {
    if (!e) return;
    /* In-flight frames are reading buffers we are about to release, and their
     * completion handlers capture `e`. */
    tb_dpcm_gpu_drain(e);
    for (int i = 0; i < TB_DPCM_GPU_JOBS; ++i) {
        e->jobs[i].blob = nil; e->jobs[i].meta = nil;
        e->jobs[i].offs = nil; e->jobs[i].src  = nil;
        e->jobs[i].bits = nil; e->jobs[i].gtot = nil;
    }
    e->plan_q = nil;
    e->slots = nil;
    e->blob = nil; e->meta = nil; e->offs = nil; e->staged = nil;
    e->analyze = nil; e->pack = nil;
    e->scanGroups = nil; e->scanBases = nil; e->applyBases = nil; e->zeroPayload = nil;
    e->queue = nil; e->dev = nil;
    free(e);
}

const char *tb_dpcm_gpu_device_name(const tb_dpcm_gpu *e) {
    return (e && e->name[0]) ? e->name : "?";
}

int tb_dpcm_gpu_last_was_zero_copy(const tb_dpcm_gpu *e) {
    return e ? e->last_zero_copy : 0;
}

/* --------------------------------------------------------------------- helpers */

/* `__strong` is required: an out-parameter of object type defaults to
 * __autoreleasing under ARC, which cannot bind to a strong struct field. */
static int ensure_buffer(tb_dpcm_gpu *e, id<MTLBuffer> __strong *buf,
                         size_t *cap, size_t need) {
    if (*cap >= need && *buf) return 0;
    *buf = [e->dev newBufferWithLength:need options:MTLResourceStorageModeShared];
    *cap = *buf ? need : 0;
    return *buf ? 0 : -1;
}

static inline size_t round4(size_t n) { return (n + 3u) & ~(size_t)3u; }
static inline void put_u32(uint8_t *p, uint32_t v) {
    p[0]=(uint8_t)v; p[1]=(uint8_t)(v>>8); p[2]=(uint8_t)(v>>16); p[3]=(uint8_t)(v>>24);
}

static int enc_geom_of(int w, int band_h, size_t header_reserve, struct enc_geom *g) {
    g->tiles_x = (w + TB_DPCM_TILE - 1) / TB_DPCM_TILE;
    g->tiles_y = (band_h + TB_DPCM_TILE - 1) / TB_DPCM_TILE;
    g->tile_count  = (uint32_t)g->tiles_x * (uint32_t)g->tiles_y;
    g->group_count = (g->tile_count + TB_DPCM_GROUP - 1) / TB_DPCM_GROUP;

    g->width_plane_bytes = round4(((size_t)g->tile_count * 3 + 1) / 2);
    g->seed_plane_bytes  = (size_t)g->tile_count * 4;
    g->group_table_off   = TB_DPCM_HEADER;
    g->width_plane_off   = g->group_table_off + (size_t)g->group_count * 4;
    g->seed_plane_off    = g->width_plane_off + g->width_plane_bytes;
    g->payload_off       = g->seed_plane_off + g->seed_plane_bytes;

    /* Metal requires 4-byte-aligned buffer offsets and every plane is bound at
     * an offset, so the blob starts padded and the caller's header sits at the
     * END of the reserved run, immediately before it. */
    g->blob_off = round4(header_reserve);
    const size_t band_max = tb_dpcm_max_size(w, band_h);
    if (band_max == 0) return -1;
    g->band_span = round4(g->blob_off + band_max);
    g->meta_span = (size_t)g->tile_count * 8;
    g->offs_span = (size_t)g->tile_count * 4;
    return 0;
}

/* Step 2, the host side: prefix-sum the per-tile costs into bit offsets, write
 * the group table, pack the width nibbles, and fill in each band's header.
 *
 * O(tiles), so 1/64th of the per-pixel work, and the host has to write the
 * header and learn the final length regardless. Group starts round up to a
 * byte, which is what lets step 3 write groups concurrently.
 *
 * Shared by the blocking and non-blocking paths so the two can never disagree
 * about the container. */
static void plan_band(uint8_t *blob_base, const uint8_t *meta_base, uint8_t *offs_base,
                      const struct enc_geom *g, int b,
                      int w, int band_h, int ten_bit, size_t header_reserve,
                      size_t *payload_bytes, tb_dpcm_gpu_band *out) {
    {
        uint8_t *blob = blob_base + g->band_span * (size_t)b + g->blob_off;
        const uint32_t *meta = (const uint32_t *)(meta_base + g->meta_span * (size_t)b);
        uint32_t *offs = (uint32_t *)(offs_base + g->offs_span * (size_t)b);

        /* Up to the SEED plane only. The analyze kernel has already written the
         * seeds into the blob, and clearing as far as payload_off would erase
         * them — which it did, and showed up as every byte from seed_plane_off
         * onwards differing from the reference. The width plane does need
         * clearing because nibbles are OR-ed into it; the header and group
         * table are written whole. */
        memset(blob, 0, g->seed_plane_off);

        size_t bitpos = 0;
        uint8_t *wp = blob + g->width_plane_off;
        for (uint32_t t = 0; t < g->tile_count; ++t) {
            if (t % TB_DPCM_GROUP == 0) {
                bitpos = (bitpos + 7u) & ~(size_t)7u;
                put_u32(blob + g->group_table_off + (size_t)(t / TB_DPCM_GROUP) * 4,
                        (uint32_t)bitpos);
            }
            offs[t] = (uint32_t)bitpos;

            const uint32_t packed = meta[t * 2 + 0];
            for (int c = 0; c < 3; ++c) {
                const uint32_t idx = t * 3u + (uint32_t)c;
                const int n = (int)((packed >> (8 * c)) & 0xFFu);
                if (idx & 1u) wp[idx >> 1] |= (uint8_t)((n & 0xF) << 4);
                else          wp[idx >> 1] |= (uint8_t)( n & 0xF);
            }
            bitpos += meta[t * 2 + 1];
        }
        payload_bytes[b] = (bitpos + 7) / 8;
        const size_t total = g->payload_off + payload_bytes[b];

        put_u32(blob +  0, TB_DPCM_MAGIC);
        put_u32(blob +  4, (uint32_t)w);
        put_u32(blob +  8, (uint32_t)band_h);
        blob[12] = 3;
        blob[13] = TB_DPCM_CHANNELS;
        blob[14] = (uint8_t)(TB_DPCM_FLAG_ALPHA_OMITTED |
                             (ten_bit ? TB_DPCM_FLAG_TEN_BIT : 0u));
        blob[15] = 0;
        put_u32(blob + 16, g->group_count);
        put_u32(blob + 20, (uint32_t)g->width_plane_bytes);
        put_u32(blob + 24, (uint32_t)g->seed_plane_bytes);
        put_u32(blob + 28, (uint32_t)payload_bytes[b]);

        /* The reserved run ends where the blob begins, so the caller's header
         * and the payload are one contiguous buffer. */
        out[b].blob = blob - header_reserve;
        out[b].len  = header_reserve + total;
    }
}

/* --------------------------------------------------------------------- encode */

size_t tb_dpcm_gpu_encode_bands(tb_dpcm_gpu *e,
                                const uint8_t *src, int stride, int w, int band_h,
                                int band_count, int ten_bit, size_t header_reserve,
                                tb_dpcm_gpu_band *out) {
    if (!e || !src || !out || w <= 0 || band_h <= 0 || stride < w * 4) return 0;
    if (band_count < 1 || band_count > TB_DPCM_GPU_MAX_BANDS) return 0;
    /* Same pixel cap as the C codec, for the same reason: every bit offset the
     * kernels compute is a uint. tb_dpcm_max_size() enforces it too (returning
     * 0 makes ensure_buffer fail), but checking here keeps the failure mode a
     * clean refusal instead of a zero-sized allocation. Both the band and the
     * whole frame have to fit — the band because its offsets are what the
     * kernels compute, the frame because it is what gets wrapped. */
    if ((uint64_t)w * (uint64_t)band_h > ((uint64_t)1 << 27)) return 0;
    if ((uint64_t)w * (uint64_t)band_h * (uint64_t)band_count > ((uint64_t)1 << 27)) return 0;
    /* The shaders index the source as 32-bit words, so a row must be a whole
     * number of them. Every CVPixelBuffer stride is, but an arbitrary caller's
     * might not be. */
    if (stride % 4 != 0) return 0;

    /* Every band has the same width and the same height, so one geometry serves
     * all of them and each band's region of each buffer is a fixed stride away
     * from the last. That is the whole reason this can be one dispatch loop. */
    const int tiles_x = (w + TB_DPCM_TILE - 1) / TB_DPCM_TILE;
    const int tiles_y = (band_h + TB_DPCM_TILE - 1) / TB_DPCM_TILE;
    const uint32_t tile_count  = (uint32_t)tiles_x * (uint32_t)tiles_y;
    const uint32_t group_count = (tile_count + TB_DPCM_GROUP - 1) / TB_DPCM_GROUP;

    const size_t width_plane_bytes = round4(((size_t)tile_count * 3 + 1) / 2);
    const size_t seed_plane_bytes  = (size_t)tile_count * 4;
    const size_t group_table_off   = TB_DPCM_HEADER;
    const size_t width_plane_off   = group_table_off + (size_t)group_count * 4;
    const size_t seed_plane_off    = width_plane_off + width_plane_bytes;
    const size_t payload_off       = seed_plane_off + seed_plane_bytes;

    /* Metal requires 4-byte-aligned buffer offsets, and every plane below is
     * bound at an offset into this buffer — so the blob starts at a padded
     * boundary and the caller's header sits at the END of the reserved run,
     * immediately before it. That keeps the header contiguous with the payload
     * without misaligning anything the GPU touches. Bands are spaced by a
     * rounded span for the same reason. */
    const size_t blob_off = round4(header_reserve);
    const size_t band_max = tb_dpcm_max_size(w, band_h);
    if (band_max == 0) return 0;
    const size_t band_span = round4(blob_off + band_max);
    const size_t meta_span = (size_t)tile_count * 8;
    const size_t offs_span = (size_t)tile_count * 4;

    if (ensure_buffer(e, &e->blob, &e->blob_cap, band_span * (size_t)band_count) != 0) return 0;
    if (ensure_buffer(e, &e->meta, &e->meta_cap, meta_span * (size_t)band_count) != 0) return 0;
    if (ensure_buffer(e, &e->offs, &e->offs_cap, offs_span * (size_t)band_count) != 0) return 0;

    size_t payload_bytes[TB_DPCM_GPU_MAX_BANDS];
    size_t total_all = 0;

    @autoreleasepool {
        /* Wrap the caller's pixels without copying when the allocation is page
         * aligned, which IOSurface-backed capture buffers are. The whole frame
         * is wrapped once and each band reads from its own offset — wrapping a
         * band's advanced pointer instead only avoided the copy when that band's
         * byte offset happened to land on a page boundary. The fallback exists
         * so an odd caller degrades instead of failing. */
        const size_t page = (size_t)getpagesize();
        const size_t band_bytes = (size_t)stride * (size_t)band_h;
        const size_t src_bytes  = band_bytes * (size_t)band_count;
        id<MTLBuffer> srcBuf = nil;
        if (((uintptr_t)src % page) == 0) {
            srcBuf = [e->dev newBufferWithBytesNoCopy:(void *)src
                                               length:(src_bytes + page - 1) / page * page
                                              options:MTLResourceStorageModeShared
                                          deallocator:nil];
        }
        if (srcBuf) {
            e->last_zero_copy = 1;
        } else {
            e->last_zero_copy = 0;
            if (ensure_buffer(e, &e->staged, &e->staged_cap, src_bytes) != 0) return 0;
            memcpy(e->staged.contents, src, src_bytes);
            srcBuf = e->staged;
        }

        struct enc_params P = {
            (uint32_t)w, (uint32_t)band_h,
            (uint32_t)tiles_x, (uint32_t)tiles_y,
            tile_count,
            (uint32_t)(stride / 4),
            ten_bit ? 10u : 8u,
            ten_bit ? 0x3FFu : 0xFFu,
            ten_bit ? 0x200u : 0x80u
        };

        /* ---- step 1: analyze, every band in one submission ----
         * The default (serial) dispatch type is kept deliberately. A single
         * band already fills the device — 57600 threadgroups at 5K/4 — so
         * letting bands overlap would buy almost nothing, and the win here is
         * the round trip, not intra-GPU concurrency. */
        id<MTLCommandBuffer> cb = [e->queue commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:e->analyze];
        [ce setBytes:&P length:sizeof(P) atIndex:3];
        for (int b = 0; b < band_count; ++b) {
            [ce setBuffer:srcBuf  offset:band_bytes * (size_t)b atIndex:0];
            [ce setBuffer:e->meta offset:meta_span  * (size_t)b atIndex:1];
            [ce setBuffer:e->blob offset:band_span  * (size_t)b + blob_off + seed_plane_off atIndex:2];
            [ce dispatchThreadgroups:MTLSizeMake(tile_count, 1, 1)
               threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        }
        [ce endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.error) {
            fprintf(stderr, "[dpcm-gpu] analyze: %s\n", cb.error.localizedDescription.UTF8String);
            return 0;
        }

        /* ---- step 2: plan, on the host ----
         * O(tiles), so 1/64th of the per-pixel work, and the host has to write
         * the header and learn the final length regardless. Group starts are
         * rounded up to a byte, which is what lets step 3 write groups
         * concurrently.
         *
         * This is the remaining sync point: it sits between two GPU passes, so
         * the encoder has to stop here. Moving it onto the device would make the
         * frame a single submission. */
        for (int b = 0; b < band_count; ++b) {
            uint8_t *blob = (uint8_t *)e->blob.contents + band_span * (size_t)b + blob_off;
            const uint32_t *meta = (const uint32_t *)((uint8_t *)e->meta.contents + meta_span * (size_t)b);
            uint32_t *offs = (uint32_t *)((uint8_t *)e->offs.contents + offs_span * (size_t)b);

            /* Up to the SEED plane only. The analyze kernel has already written
             * the seeds into the blob, and clearing as far as payload_off would
             * erase them — which it did, and showed up as every byte from
             * seed_plane_off onwards differing from the reference. The width
             * plane does need clearing because nibbles are OR-ed into it; the
             * header and group table are written whole. */
            memset(blob, 0, seed_plane_off);

            size_t bitpos = 0;
            uint8_t *wp = blob + width_plane_off;
            for (uint32_t t = 0; t < tile_count; ++t) {
                if (t % TB_DPCM_GROUP == 0) {
                    bitpos = (bitpos + 7u) & ~(size_t)7u;
                    put_u32(blob + group_table_off + (size_t)(t / TB_DPCM_GROUP) * 4,
                            (uint32_t)bitpos);
                }
                offs[t] = (uint32_t)bitpos;

                const uint32_t packed = meta[t * 2 + 0];
                for (int c = 0; c < 3; ++c) {
                    const uint32_t idx = t * 3u + (uint32_t)c;
                    const int n = (int)((packed >> (8 * c)) & 0xFFu);
                    if (idx & 1u) wp[idx >> 1] |= (uint8_t)((n & 0xF) << 4);
                    else          wp[idx >> 1] |= (uint8_t)( n & 0xF);
                }
                bitpos += meta[t * 2 + 1];
            }
            payload_bytes[b] = (bitpos + 7) / 8;
            const size_t total = payload_off + payload_bytes[b];

            put_u32(blob +  0, TB_DPCM_MAGIC);
            put_u32(blob +  4, (uint32_t)w);
            put_u32(blob +  8, (uint32_t)band_h);
            blob[12] = 3;
            blob[13] = TB_DPCM_CHANNELS;
            blob[14] = (uint8_t)(TB_DPCM_FLAG_ALPHA_OMITTED |
                                 (ten_bit ? TB_DPCM_FLAG_TEN_BIT : 0u));
            blob[15] = 0;
            put_u32(blob + 16, group_count);
            put_u32(blob + 20, (uint32_t)width_plane_bytes);
            put_u32(blob + 24, (uint32_t)seed_plane_bytes);
            put_u32(blob + 28, (uint32_t)payload_bytes[b]);

            /* The reserved run ends where the blob begins, so the caller's
             * header and the payload are one contiguous buffer. */
            out[b].blob = blob - header_reserve;
            out[b].len  = header_reserve + total;
            total_all  += header_reserve + total;
        }

        /* ---- step 3: pack, every band in one submission ----
         * The payload is zeroed on the GPU because the packer merges into it, and
         * a 32 MB memset on the host would cost more than the whole encode. All
         * the fills go in one blit encoder ahead of the packs: separate encoders
         * in a command buffer run in order, which is the dependency we need. */
        cb = [e->queue commandBuffer];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        for (int b = 0; b < band_count; ++b) {
            [be fillBuffer:e->blob
                     range:NSMakeRange(band_span * (size_t)b + blob_off + payload_off,
                                       round4(payload_bytes[b]) + 4)
                     value:0];
        }
        [be endEncoding];

        ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:e->pack];
        [ce setBytes:&P length:sizeof(P) atIndex:5];
        const NSUInteger threads = (NSUInteger)tile_count * 3;
        const NSUInteger tg = 256;
        for (int b = 0; b < band_count; ++b) {
            const size_t pay = band_span * (size_t)b + blob_off + payload_off;
            [ce setBuffer:srcBuf  offset:band_bytes * (size_t)b atIndex:0];
            [ce setBuffer:e->meta offset:meta_span  * (size_t)b atIndex:1];
            [ce setBuffer:e->offs offset:offs_span  * (size_t)b atIndex:2];
            [ce setBuffer:e->blob offset:pay atIndex:3];
            [ce setBuffer:e->blob offset:pay atIndex:4];
            [ce dispatchThreadgroups:MTLSizeMake((threads + tg - 1) / tg, 1, 1)
               threadsPerThreadgroup:MTLSizeMake(tg, 1, 1)];
        }
        [ce endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.error) {
            fprintf(stderr, "[dpcm-gpu] pack: %s\n", cb.error.localizedDescription.UTF8String);
            return 0;
        }
    }
    return total_all;
}

size_t tb_dpcm_gpu_encode(tb_dpcm_gpu *e,
                          const uint8_t *src, int stride, int w, int h,
                          int ten_bit, size_t header_reserve,
                          const uint8_t **out_blob) {
    if (!out_blob) return 0;
    tb_dpcm_gpu_band band = { NULL, 0 };
    const size_t n = tb_dpcm_gpu_encode_bands(e, src, stride, w, h, 1,
                                              ten_bit, header_reserve, &band);
    if (n == 0 || !band.blob) return 0;
    *out_blob = band.blob;
    return band.len;
}

/* ------------------------------------------------------------- non-blocking */

/* Grow a job's buffers to fit this frame. Same rule as the shared ones: grown,
 * never shrunk, so the steady state allocates nothing. */
static int job_ensure(tb_dpcm_gpu *e, struct tb_dpcm_gpu_job *j,
                      const struct enc_geom *g, int band_count) {
    if (ensure_buffer(e, &j->blob, &j->blob_cap, g->band_span * (size_t)band_count) != 0) return -1;
    if (ensure_buffer(e, &j->meta, &j->meta_cap, g->meta_span * (size_t)band_count) != 0) return -1;
    if (ensure_buffer(e, &j->offs, &j->offs_cap, g->offs_span * (size_t)band_count) != 0) return -1;
    const size_t groups = (g->tile_count + 63) / 64;
    if (ensure_buffer(e, &j->gtot, &j->gtot_cap, groups * 4 * (size_t)band_count) != 0) return -1;
    if (ensure_buffer(e, &j->bits, &j->bits_cap, 4 * (size_t)band_count) != 0) return -1;
    return 0;
}

/* Step 3 for ONE band, delivered the moment it lands.
 *
 * One command buffer per band rather than one per frame. Four bands used to pack
 * together and then burst onto the wire as four packets; now each leaves as it
 * is ready, spread across the frame. The receiver's presentation cadence is
 * sensitive to that spacing in a way the sender's own numbers are not — with the
 * burst, `send(wall)` read a clean 100% while the receiver bunched frames into
 * pairs. */
static void job_submit_pack_band(tb_dpcm_gpu *e, struct tb_dpcm_gpu_job *j, int b) {
    @autoreleasepool {
        const struct enc_geom *g = &j->g;
        const int last = (b + 1 == j->band_count);
        id<MTLCommandBuffer> cb = [e->queue commandBuffer];

        /* The payload is zeroed on the GPU because the packer merges into it,
         * and a 32 MB memset on the host would cost more than the whole encode.
         * Separate encoders in one command buffer run in order, which is the
         * dependency the fills need. */
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be fillBuffer:j->blob
                 range:NSMakeRange(g->band_span * (size_t)b + g->blob_off + g->payload_off,
                                   round4(j->payload_bytes[b]) + 4)
                 value:0];
        [be endEncoding];

        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:e->pack];
        [ce setBytes:&j->P length:sizeof(j->P) atIndex:5];
        const NSUInteger threads = (NSUInteger)g->tile_count * 3;
        const NSUInteger tg = 256;
        const size_t pay = g->band_span * (size_t)b + g->blob_off + g->payload_off;
        [ce setBuffer:j->src  offset:j->band_bytes * (size_t)b atIndex:0];
        [ce setBuffer:j->meta offset:g->meta_span  * (size_t)b atIndex:1];
        [ce setBuffer:j->offs offset:g->offs_span  * (size_t)b atIndex:2];
        [ce setBuffer:j->blob offset:pay atIndex:3];
        [ce setBuffer:j->blob offset:pay atIndex:4];
        [ce dispatchThreadgroups:MTLSizeMake((threads + tg - 1) / tg, 1, 1)
           threadsPerThreadgroup:MTLSizeMake(tg, 1, 1)];
        [ce endEncoding];

        [cb addCompletedHandler:^(id<MTLCommandBuffer> done_cb) {
            const int ok = (done_cb.error == nil);
            if (!ok) {
                fprintf(stderr, "[dpcm-gpu] pack band %d: %s\n", b,
                        done_cb.error.localizedDescription.UTF8String);
            }
            /* Hand the band over BEFORE releasing the slot, so the callee can
             * read the blob while it is still guaranteed not to be reused. */
            if (j->done) j->done(j->ctx, ok, &j->bands[b], b, last);
            if (last) {
                j->src  = nil;
                j->done = NULL;
                j->ctx  = NULL;
                dispatch_semaphore_signal(e->slots);
            }
        }];
        [cb commit];
    }
}

int tb_dpcm_gpu_encode_bands_async(tb_dpcm_gpu *e,
                                   const uint8_t *src, int stride, int w, int band_h,
                                   int band_count, int ten_bit, size_t header_reserve,
                                   tb_dpcm_gpu_done done, void *ctx) {
    if (!e || !src || !done || w <= 0 || band_h <= 0 || stride < w * 4) return -1;
    if (band_count < 1 || band_count > TB_DPCM_GPU_MAX_BANDS) return -1;
    if ((uint64_t)w * (uint64_t)band_h > ((uint64_t)1 << 27)) return -1;
    if ((uint64_t)w * (uint64_t)band_h * (uint64_t)band_count > ((uint64_t)1 << 27)) return -1;
    if (stride % 4 != 0) return -1;

    /* Backpressure rather than a queue: if every job is busy the caller should
     * drop this frame, exactly as it would drop one the socket had no room for.
     * Waiting here would put the block back on the capture thread, which is the
     * whole thing this call exists to avoid. */
    if (dispatch_semaphore_wait(e->slots, DISPATCH_TIME_NOW) != 0) return -1;

    struct tb_dpcm_gpu_job *j = &e->jobs[e->next_job];
    e->next_job = (e->next_job + 1) % TB_DPCM_GPU_JOBS;

    if (enc_geom_of(w, band_h, header_reserve, &j->g) != 0 ||
        job_ensure(e, j, &j->g, band_count) != 0) {
        dispatch_semaphore_signal(e->slots);
        return -1;
    }

    j->band_count     = band_count;
    j->w              = w;
    j->band_h         = band_h;
    j->ten_bit        = ten_bit;
    j->header_reserve = header_reserve;
    j->band_bytes     = (size_t)stride * (size_t)band_h;
    j->done           = done;
    j->ctx            = ctx;
    j->P = (struct enc_params){
        (uint32_t)w, (uint32_t)band_h,
        (uint32_t)j->g.tiles_x, (uint32_t)j->g.tiles_y,
        j->g.tile_count,
        (uint32_t)(stride / 4),
        ten_bit ? 10u : 8u,
        ten_bit ? 0x3FFu : 0xFFu,
        ten_bit ? 0x200u : 0x80u
    };

    @autoreleasepool {
        /* Wrap the caller's pixels without copying. Unlike the blocking path
         * there is no staging fallback: a copy here would cost the caller the
         * very milliseconds this call exists to give back, and every real
         * caller is handing us an IOSurface, which is page aligned. */
        const size_t page = (size_t)getpagesize();
        const size_t src_bytes = j->band_bytes * (size_t)band_count;
        if (((uintptr_t)src % page) != 0) {
            dispatch_semaphore_signal(e->slots);
            return -1;
        }
        /* A fresh wrapper per frame, deliberately.
         *
         * These were cached by base address, on the reasoning that
         * ScreenCaptureKit recycles IOSurfaces so the same few addresses repeat.
         * That reasoning is sound and the cache was still wrong: with three
         * frames in flight, two jobs handed the same address get the SAME
         * MTLBuffer, so one job's pack pass can read pixels the next frame has
         * already overwritten. It showed up as a stale frame alternating with
         * live ones -- a flicker -- and none of the delivery counters could see
         * it, because every band arrived intact and in order. The bytes were
         * simply the wrong bytes.
         *
         * It was worth ~0.7 ms of a 2.4 ms average, inside measurement noise,
         * and it was never the spike it was added to fix (that was the depth
         * probe). Not worth a correctness risk. */
        const size_t mapped_len = (src_bytes + page - 1) / page * page;
        j->src = [e->dev newBufferWithBytesNoCopy:(void *)src
                                           length:mapped_len
                                          options:MTLResourceStorageModeShared
                                      deallocator:nil];
        if (!j->src) {
            dispatch_semaphore_signal(e->slots);
            return -1;
        }
        e->last_zero_copy = 1;

        /* ONE command buffer per band: analyze, plan, pack.
         *
         * The plan step used to run on the host between two GPU passes, which is
         * the only reason the encoder round-tripped at all. It is now three
         * kernels (see the shader), so a band is a single submission with a
         * single completion and no host involvement until the bytes are ready.
         *
         * Dispatches inside one compute encoder run in order with implicit
         * barriers, which is exactly the dependency chain this needs.
         */
        for (int b = 0; b < band_count; ++b) {
            const struct enc_geom *g = &j->g;
            const size_t bandBase = g->band_span * (size_t)b + g->blob_off;
            id<MTLCommandBuffer> cb = [e->queue commandBuffer];

            /* Header, group table and width plane must start zeroed: the width
             * nibbles are merged in atomically. The seed plane must NOT be
             * cleared -- analyze writes it, and clearing that far erased it once
             * already. */
            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
            [be fillBuffer:j->blob range:NSMakeRange(bandBase, g->seed_plane_off) value:0];
            [be endEncoding];

            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];

            [ce setComputePipelineState:e->analyze];
            [ce setBuffer:j->src  offset:j->band_bytes  * (size_t)b atIndex:0];
            [ce setBuffer:j->meta offset:g->meta_span   * (size_t)b atIndex:1];
            [ce setBuffer:j->blob offset:bandBase + g->seed_plane_off atIndex:2];
            [ce setBytes:&j->P length:sizeof(j->P) atIndex:3];
            [ce dispatchThreadgroups:MTLSizeMake(g->tile_count, 1, 1)
               threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];

            const NSUInteger groups = (g->tile_count + 63) / 64;
            [ce setComputePipelineState:e->scanGroups];
            [ce setBuffer:j->meta  offset:g->meta_span * (size_t)b atIndex:0];
            [ce setBuffer:j->offs  offset:g->offs_span * (size_t)b atIndex:1];
            [ce setBuffer:j->gtot  offset:groups * 4 * (size_t)b atIndex:2];
            [ce setBuffer:j->blob  offset:bandBase + g->width_plane_off atIndex:3];
            [ce setBytes:&j->P length:sizeof(j->P) atIndex:4];
            [ce dispatchThreadgroups:MTLSizeMake(groups, 1, 1)
               threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];

            [ce setComputePipelineState:e->scanBases];
            [ce setBuffer:j->gtot offset:groups * 4 * (size_t)b atIndex:0];
            [ce setBuffer:j->blob offset:bandBase + g->group_table_off atIndex:1];
            [ce setBuffer:j->bits offset:4 * (size_t)b atIndex:2];
            [ce setBuffer:j->meta offset:g->meta_span * (size_t)b atIndex:3];
            [ce setBytes:&j->P length:sizeof(j->P) atIndex:4];
            [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1)
               threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];

            [ce setComputePipelineState:e->applyBases];
            [ce setBuffer:j->offs offset:g->offs_span * (size_t)b atIndex:0];
            [ce setBuffer:j->blob offset:bandBase + g->group_table_off atIndex:1];
            [ce setBytes:&j->P length:sizeof(j->P) atIndex:2];
            [ce dispatchThreadgroups:MTLSizeMake((g->tile_count + 255) / 256, 1, 1)
               threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];

            const size_t pay = bandBase + g->payload_off;
            const NSUInteger maxWords = (tb_dpcm_max_size(j->w, j->band_h) / 4) + 2;
            [ce setComputePipelineState:e->zeroPayload];
            [ce setBuffer:j->blob offset:pay atIndex:0];
            [ce setBuffer:j->bits offset:4 * (size_t)b atIndex:1];
            [ce dispatchThreadgroups:MTLSizeMake((maxWords + 255) / 256, 1, 1)
               threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];

            [ce setComputePipelineState:e->pack];
            [ce setBuffer:j->src  offset:j->band_bytes * (size_t)b atIndex:0];
            [ce setBuffer:j->meta offset:g->meta_span  * (size_t)b atIndex:1];
            [ce setBuffer:j->offs offset:g->offs_span  * (size_t)b atIndex:2];
            [ce setBuffer:j->blob offset:pay atIndex:3];
            [ce setBuffer:j->blob offset:pay atIndex:4];
            [ce setBytes:&j->P length:sizeof(j->P) atIndex:5];
            const NSUInteger threads = (NSUInteger)g->tile_count * 3;
            [ce dispatchThreadgroups:MTLSizeMake((threads + 255) / 256, 1, 1)
               threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];

            [ce endEncoding];

            const int last = (b + 1 == band_count);
            [cb addCompletedHandler:^(id<MTLCommandBuffer> done_cb) {
                const int ok = (done_cb.error == nil);
                if (!ok) {
                    fprintf(stderr, "[dpcm-gpu] band %d: %s\n", b,
                            done_cb.error.localizedDescription.UTF8String);
                } else {
                    /* The only host work left: read the length the GPU computed
                     * and write the 32-byte header in front of it. */
                    const uint32_t totalBits =
                        ((const uint32_t *)j->bits.contents)[b];
                    const size_t payload_bytes = (totalBits + 7u) / 8u;
                    uint8_t *blob = (uint8_t *)j->blob.contents + bandBase;
                    put_u32(blob +  0, TB_DPCM_MAGIC);
                    put_u32(blob +  4, (uint32_t)j->w);
                    put_u32(blob +  8, (uint32_t)j->band_h);
                    blob[12] = 3;
                    blob[13] = TB_DPCM_CHANNELS;
                    blob[14] = (uint8_t)(TB_DPCM_FLAG_ALPHA_OMITTED |
                                         (j->ten_bit ? TB_DPCM_FLAG_TEN_BIT : 0u));
                    blob[15] = 0;
                    put_u32(blob + 16, j->g.group_count);
                    put_u32(blob + 20, (uint32_t)j->g.width_plane_bytes);
                    put_u32(blob + 24, (uint32_t)j->g.seed_plane_bytes);
                    put_u32(blob + 28, (uint32_t)payload_bytes);
                    j->bands[b].blob = blob - j->header_reserve;
                    j->bands[b].len  = j->header_reserve + j->g.payload_off + payload_bytes;
                }
                if (j->done) j->done(j->ctx, ok, ok ? &j->bands[b] : NULL, b, last);
                if (last) {
                    j->src = nil; j->done = NULL; j->ctx = NULL;
                    dispatch_semaphore_signal(e->slots);
                }
            }];
            [cb commit];
        }
    }
    return 0;
}

void tb_dpcm_gpu_drain(tb_dpcm_gpu *e) {
    if (!e || !e->slots) return;
    /* Claim every slot, which is only possible once nothing is in flight, then
     * hand them all back. */
    for (int i = 0; i < TB_DPCM_GPU_JOBS; ++i) dispatch_semaphore_wait(e->slots, DISPATCH_TIME_FOREVER);
    for (int i = 0; i < TB_DPCM_GPU_JOBS; ++i) dispatch_semaphore_signal(e->slots);
}
