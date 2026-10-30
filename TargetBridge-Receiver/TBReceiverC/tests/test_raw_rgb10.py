#!/usr/bin/env python3
"""Execute RAW format routing/profile code with real framing and fake display.

Synthetic pixels only; no receiver, GPU, window, network or user files.
"""
from pathlib import Path
import os
import re
import shlex
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "src/main.c").read_text()


def function(name):
    match = re.search(r"^static (?:int|void) " + name + r"\([^;{]*\)\s*\{", source, re.M)
    start = match.start()
    pos, depth = match.end(), 1
    while depth:
        depth += (source[pos] == "{") - (source[pos] == "}")
        pos += 1
    return source[start:pos]


mode_struct = re.search(r"struct tb_stream_mode \{.*?\n\};", source, re.S).group(0)
fixture = mode_struct + r'''
#include "display.h"
#include "receiver_profile.h"
#include "net.h"
#include "proto.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
struct app { struct tb_display *disp; int client_fd, have_video_frame; uint64_t frames; struct tb_stream_mode stream_mode; char status_text[128],mode_text[128]; };
struct tb_i18n_pair { const char *key, *value; };
static int packed_calls,nv12_calls,render_rc,packed_support;
static int last_width,last_height,last_stride;
static const uint8_t *expected_pixels;
static uint8_t wire[2048];
static size_t wire_length;
static void tb_copy_i18n(char *dst,size_t n,const char *key){snprintf(dst,n,"%s",key);}
static void tb_format_i18n(char *dst,size_t n,const char *key,const struct tb_i18n_pair *p,size_t count){(void)key;assert(count==2);snprintf(dst,n,"%sx%s",p[0].value,p[1].value);}
int tb_disp_render_raw_rgb10(struct tb_display *d,const uint8_t *pixels,int stride,int w,int h){
    (void)d;++packed_calls;last_width=w;last_height=h;last_stride=stride;
    assert(stride==w*4);
    if(expected_pixels)assert(memcmp(pixels,expected_pixels,(size_t)stride*h)==0);
    return render_rc;
}
void tb_disp_render_nv12(struct tb_display *d,const uint8_t *y,int ys,const uint8_t *uv,int us,int w,int h){
    (void)d;++nv12_calls;assert(w==2&&h==2&&ys==2&&us==2);assert(y[0]==0x11&&uv[0]==0x22);
}
int tb_disp_get_info(struct tb_display *d,struct tb_display_info *info){
    (void)d;memset(info,0,sizeof(*info));info->logical_w=2240;info->logical_h=1260;info->active_w=4480;info->active_h=2520;strcpy(info->name,"synthetic panel");return 0;
}

int tb_disp_raw_rgb10_available(struct tb_display *d){(void)d;return packed_support;}
static int tb_dec_supports_hevc_hwdecode(void){return 1;}
static int tb_receiver_input_monitoring_trusted(void){return 0;}
static int tb_receiver_accessibility_trusted(void){return 0;}
static int tb_night_shift_supported(void){return 0;}
static int tb_true_tone_supported(void){return 0;}
static int send_all(int fd,const uint8_t *p,size_t n){(void)fd;assert(n<sizeof(wire));memcpy(wire,p,n);wire[n]=0;wire_length=n;return 0;}
'''
checks = r'''
static void header(uint8_t *p,uint8_t format,uint32_t w,uint32_t h,uint32_t stride,uint32_t second){
    p[0]=format;write_be32(p+1,w);write_be32(p+5,h);write_be32(p+9,stride);write_be32(p+13,second);
}
static void packet_cb(uint8_t type,const uint8_t *p,size_t n,void *context){assert(type==TB_PKT_RAW_FRAME);handle_raw_frame(context,p,n);}
static void reject(struct app *a,uint8_t *p,size_t n){int before=packed_calls+nv12_calls;uint64_t frames=a->frames;handle_raw_frame(a,p,n);assert(before==packed_calls+nv12_calls&&frames==a->frames);}
int main(void){
    struct app a={0};
    const int width=1024,height=3,stride=width*4;size_t length=17+(size_t)stride*height;
    uint8_t *p=calloc(1,length+1);assert(p);header(p,2,width,height,stride,0);
    for(int y=0;y<height;y++)for(int x=0;x<width;x++){
        uint32_t v=((uint32_t)(x+y)&3u)<<30|((uint32_t)(x+y)&1023u)|(((uint32_t)(1023-x+y)&1023u)<<10)|(((uint32_t)(x*5+y)&1023u)<<20);
        memcpy(p+17+(size_t)y*stride+x*4,&v,4);
    }
    expected_pixels=p+17;handle_raw_frame(&a,p,length);
    assert(packed_calls==1&&nv12_calls==0&&a.frames==1&&a.have_video_frame);
    assert(last_width==width&&last_height==height&&last_stride==stride);
    assert(strcmp(a.mode_text,"1024x3")==0);  /* Odd height is valid packed RGB. */
    a.have_video_frame=0;render_rc=-1;handle_raw_frame(&a,p,length);
    assert(packed_calls==2&&a.frames==1&&!a.have_video_frame&&nv12_calls==0);render_rc=0;
    for(size_t n=0;n<17;n++)reject(&a,p,n);
    reject(&a,NULL,17);
    const uint32_t invalid[][4]={{0,3,4096,0},{1024,0,4096,0},{5121,3,20484,0},{1024,2881,4096,0},{UINT32_MAX,3,UINT32_MAX,0},{1024,3,0,0},{1024,3,4092,0},{1024,3,4100,0},{1024,3,UINT32_MAX,0},{1024,3,4096,1}};
    for(size_t i=0;i<sizeof(invalid)/sizeof(invalid[0]);i++){header(p,2,invalid[i][0],invalid[i][1],invalid[i][2],invalid[i][3]);reject(&a,p,length);}
    header(p,2,width,height,stride,0);reject(&a,p,length-1);reject(&a,p,length+1);reject(&a,p,64u*1024*1024);reject(&a,p,SIZE_MAX);
    header(p,3,width,height,stride,0);reject(&a,p,length);
    header(p,2,width,height,stride,0);
    uint8_t *framed=malloc(length+5);assert(framed);write_be32(framed,(uint32_t)length+1);framed[4]=TB_PKT_RAW_FRAME;memcpy(framed+5,p,length);
    struct tb_parser parser;tb_parser_init(&parser,packet_cb,&a);
    for(size_t off=0;off<length+5;){size_t n=length+5-off;if(n>13)n=13;assert(tb_parser_feed(&parser,framed+off,n)==0);off+=n;}
    assert(a.frames==2&&nv12_calls==0);tb_parser_free(&parser);free(framed);

    /* Maximum dimensions stay below the 64 MiB framing cap. */
    size_t largest=17+(size_t)5120*2880*4;uint8_t *max_frame=calloc(1,largest);assert(max_frame);header(max_frame,2,5120,2880,5120*4,0);expected_pixels=max_frame+17;
    handle_raw_frame(&a,max_frame,largest);assert(last_width==5120&&last_height==2880&&a.frames==3);free(max_frame);expected_pixels=NULL;
    /* Legacy format 1 preserves its NV12 layout and trailing-byte tolerance. */
    uint8_t nv12[24]={0};header(nv12,1,2,2,2,2);memset(nv12+17,0x11,4);memset(nv12+21,0x22,2);
    handle_raw_frame(&a,nv12,23);handle_raw_frame(&a,nv12,24);assert(nv12_calls==2&&a.frames==5);
    header(nv12,1,3,2,3,3);reject(&a,nv12,sizeof(nv12));

    packed_support=1;send_receiver_info(&a);assert(wire_length>5&&wire[4]==TB_PKT_DISPLAY_PROFILE);
    assert(strstr((char*)wire+5,"\"supportsRawRGB10\":true"));
    packed_support=0;send_receiver_info(&a);
    assert(strstr((char*)wire+5,"\"supportsRawRGB10\":false"));
    free(p);puts("RAW RGB10: full-depth bytes, framing, strict bounds, render failure, NV12 compatibility and independent capability passed");return 0;
}
'''
with tempfile.TemporaryDirectory(prefix="tb-raw-rgb10-") as directory:
    path = Path(directory) / "test.c"
    path.write_text(fixture + function("tb_set_receiver_mode_requested") + function("tb_refresh_stream_mode") + function("tb_record_stream_dimensions") + function("handle_raw_frame") + function("write_be32") + function("send_receiver_info") + checks)
    command = [*shlex.split(os.environ.get("CC", "cc")), "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function",
               "-I" + str(root / "src"), str(path), str(root / "src/net.c"), str(root / "src/receiver_profile.c"), "-o", str(path.with_suffix(""))]
    if sys.platform == "darwin":
        command += ["-framework", "CoreFoundation", "-framework", "SystemConfiguration"]
    subprocess.run(command, check=True)
    subprocess.run([str(path.with_suffix(""))], check=True)
