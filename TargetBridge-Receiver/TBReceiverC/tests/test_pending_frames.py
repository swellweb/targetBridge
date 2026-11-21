#!/usr/bin/env python3
"""Check the production newest-frame queue with real CoreVideo lifetimes.

Synthetic NV12 bytes only; no window, screen capture, network or preferences.
"""
from pathlib import Path
import os
import re
import shlex
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / "src/main.c").read_text()

def function(name):
    match = re.search(r"^static void " + name + r"\([^;{]*\)\s*\{", source, re.M)
    assert match, name
    start, end, depth = match.start(), match.end(), 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end] + "\n"

fixture = r'''
#include <CoreVideo/CoreVideo.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
struct app {
    CVPixelBufferRef pending_pixbuf;
    uint64_t decoded_frames, skipped_frames;
};
static int presented, released, last_value;
static void on_frame(const uint8_t *y,int ys,const uint8_t *uv,int us,int w,int h,void *ud) {
    (void)ud; assert(w==16 && h==8 && ys==16 && us==16);
    assert(y && uv && uv[0]==128);
    last_value=y[0]; ++presented;
}
static void release_bytes(void *context,const void *bytes,size_t size,size_t count,
                          const void *planes[]) {
    (void)bytes;(void)size;(void)count;(void)planes;
    free(context); ++released;
}
static CVPixelBufferRef frame(uint8_t value) {
    uint8_t *data=malloc(192);assert(data);
    memset(data,value,128);memset(data+128,128,64);
    void *planes[]={data,data+128};
    size_t widths[]={16,8},heights[]={8,4},strides[]={16,16};
    CVPixelBufferRef pb=NULL;
    assert(CVPixelBufferCreateWithPlanarBytes(NULL,16,8,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,NULL,192,2,
        planes,widths,heights,strides,release_bytes,data,NULL,&pb)==kCVReturnSuccess);
    return pb;
}
'''
checks = r'''
int main(void) {
    struct app a={0};
    CVPixelBufferRef first=frame(32),second=frame(64);
    on_pixbuf(first,&a);CVPixelBufferRelease(first);
    assert(a.pending_pixbuf && released==0 && presented==0);
    on_pixbuf(second,&a);CVPixelBufferRelease(second);
    assert(a.decoded_frames==2 && a.skipped_frames==1 && released==1);
    present_pending_frame(&a);
    assert(presented==1 && last_value==64 && !a.pending_pixbuf && released==2);
    present_pending_frame(&a);assert(presented==1);
    CVPixelBufferRef old=frame(96);on_pixbuf(old,&a);CVPixelBufferRelease(old);
    drop_pending_frame(&a);
    assert(!a.pending_pixbuf && released==3);
    drop_pending_frame(&a);present_pending_frame(&a);
    assert(released==3 && presented==1);
    CVPixelBufferRef fresh=frame(112);on_pixbuf(fresh,&a);CVPixelBufferRelease(fresh);
    present_pending_frame(&a);
    assert(released==4 && presented==2 && last_value==112);
    on_pixbuf(NULL,&a);assert(a.decoded_frames==4 && !a.pending_pixbuf);
    puts("pending frames: only newest presented, source lifetime retained, stale/reset buffers released, reconnect recovered");
}
'''
with tempfile.TemporaryDirectory(prefix="tb-pending-frames-") as d:
    path = Path(d) / "pending.c"
    path.write_text(fixture + "".join(function(name) for name in
        ["on_pixbuf", "drop_pending_frame", "present_pending_frame"]) + checks)
    binary = path.with_suffix("")
    command = shlex.split(os.environ.get("CC", "cc")) + [
        "-std=c11", "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined",
        str(path), "-framework", "CoreVideo", "-framework", "CoreFoundation", "-o", str(binary)]
    subprocess.run(command, check=True)
    subprocess.run([str(binary)], check=True)
