#!/usr/bin/env python3
"""Execute production Receiver mode/status transitions with real translations.

Only display/decoder/network boundaries are mocked. No window, capture, network
connection or user preferences are accessed.
"""
from pathlib import Path
import os
import re
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "src/main.c").read_text()
languages = root.parent.parent / "TargetBridge-Shared/Languages"


def function(name, optional=False):
    match = re.search(r"^static (?:int|void|uint32_t) " + name + r"\([^;{]*\)\s*\{", source, re.M)
    if not match:
        if optional:
            return ""
        raise AssertionError("missing production function " + name)
    start, pos, depth = match.start(), match.end(), 1
    while depth:
        depth += (source[pos] == "{") - (source[pos] == "}")
        pos += 1
    return source[start:pos] + "\n"


state = re.search(r"struct tb_stream_mode \{.*?\n\};", source, re.S)
fixture = r'''
#include "tb_i18n.h"
#include "proto.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
'''
fixture += state.group(0) if state else "struct tb_stream_mode { int unused; };"
fixture += r'''
struct app {
    void *disp, *dec;
    int parser, client_fd, session_active, have_video_frame, close_requested;
    uint64_t frames;
    struct tb_stream_mode stream_mode;
    char status_text[128], sender_text[128], mode_text[128], ip_text[64];
    char sender_ui_language[8], language_pref[8], input_control_mode[32];
    char last_clipboard_text[64];
};
static int render_result, closed;
static void tb_receiver_refresh_permissions_text(struct app *a) {(void)a;}
static void tb_receiver_refresh_language_text(struct app *a) {(void)a;}
static void tb_video_diagnostics_decoded(struct app *a,int w,int h,int ys,int us) {(void)a;(void)w;(void)h;(void)ys;(void)us;}
static void tb_video_diagnostics_finish(struct app *a) {(void)a;}
static void tb_receiver_refresh_input_capture(struct app *a) {(void)a;}
static void tb_audio_close_for_idle(struct app *a) {(void)a;}
static void tb_disp_set_connection_state(void *d,int state) {(void)d;(void)state;}
static void tb_disp_set_cursor(void *d,int x,int y,int sw,int sh,int v,int t,int l) {(void)d;(void)x;(void)y;(void)sw;(void)sh;(void)v;(void)t;(void)l;}
static void SDL_EnableScreenSaver(void) {}
static void tb_parser_free(int *p) {*p=0;}
static void on_packet(uint8_t type,const uint8_t *payload,size_t len,void *ud) {(void)type;(void)payload;(void)len;(void)ud;}
static void tb_parser_init(int *p,void (*cb)(uint8_t,const uint8_t *,size_t,void *),void *ud) {(void)cb;(void)ud;*p=1;}
static void tb_dec_reset(void *d) {(void)d;}
static int close(int fd) {assert(fd==7);++closed;return 0;}
static int tb_disp_render_raw_rgb10(void *d,const uint8_t *p,int s,int w,int h) {(void)d;(void)p;assert(s==w*4&&h>0);return render_result;}
static void tb_disp_render_nv12(void *d,const uint8_t *y,int ys,const uint8_t *uv,int us,int w,int h) {(void)d;(void)y;(void)ys;(void)uv;(void)us;assert(w>0&&h>0);}

'''
names = ["tb_copy_i18n", "tb_format_i18n", "tb_set_receiver_mode_requested"]
names += ["tb_refresh_stream_mode", "tb_record_stream_dimensions", "tb_reset_stream_mode"]
names += ["tb_refresh_idle_localized_strings", "tb_receiver_apply_language_preference", "extract_json_string_field", "extract_json_int_field",
          "on_frame", "handle_raw_frame", "close_client"]
body = "".join(function(n, optional=n in {"tb_refresh_stream_mode", "tb_record_stream_dimensions",
                                        "tb_reset_stream_mode"}) for n in names)
# Run the actual handshake/language switch arms without linking unrelated input
# controls, clipboard, audio or the SDL event loop.
packet_start = source.index("    case TB_PKT_UI_LANGUAGE:", source.index("static void on_packet("))
packet_end = source.index("    case TB_PKT_CREATE_SESSION_ACK:", packet_start)
body += "static void packet(struct app *a,uint8_t type,const char *json) {\n"
body += "const uint8_t *payload=(const uint8_t *)json;size_t len=strlen(json);switch(type) {\n"
body += source[packet_start:packet_end] + "default: abort();}}\n"

checks = r'''
static void be32(uint8_t *p,uint32_t v) {p[0]=v>>24;p[1]=v>>16;p[2]=v>>8;p[3]=v;}
static void raw(struct app *a,int width,int height) {
    size_t n=17+(size_t)width*height*4;uint8_t *p=calloc(1,n);assert(p);
    p[0]=2;be32(p+1,width);be32(p+5,height);be32(p+9,width*4);
    handle_raw_frame(a,p,n);free(p);
}
int main(void) {
    struct app a={0};a.client_fd=-1;
    const char *languages[]={"de","en","fr","it","zh"};
    for(size_t i=0;i<sizeof(languages)/sizeof(languages[0]);++i) {
        strcpy(a.language_pref,languages[i]);tb_receiver_apply_language_preference(&a);
        assert(strcmp(tb_i18n_current_language(),languages[i])==0);
        assert(strcmp(a.mode_text,tb_i18n_get("receiver.mode.default"))==0);
        assert(!strstr(a.mode_text,"2560")&&!strstr(a.mode_text,"1440")&&!strstr(a.mode_text,"5K"));
    }
    strcpy(a.language_pref,"auto");
    tb_i18n_set_runtime_language("en");tb_refresh_idle_localized_strings(&a);
    assert(strcmp(a.mode_text,tb_i18n_get("receiver.mode.default"))==0);
    a.client_fd=7;
    const char *hello="{\"senderName\":\"Synthetic Sender\",\"uiLanguage\":\"en\",\"captureWidth\":4480,\"captureHeight\":2520,\"capturePreset\":\"4.5K\",\"captureSource\":\"Extended\",\"codec\":\"RGB RAW 10-bit\"}";
    packet(&a,TB_PKT_HELLO_RECEIVER,hello);
    assert(strstr(a.mode_text,"4480 x 2520")&&strstr(a.mode_text,"requested")&&strstr(a.mode_text,"RGB RAW 10-bit"));
    packet(&a,TB_PKT_UI_LANGUAGE,"{\"uiLanguage\":\"zh\"}");
    assert(strstr(a.mode_text,"4480 x 2520")&&strstr(a.mode_text,"请求"));
    assert(strcmp(a.sender_text,"Synthetic Sender")==0);
    strcpy(a.language_pref,"en");tb_receiver_apply_language_preference(&a);
    assert(strstr(a.mode_text,"4480 x 2520")&&strstr(a.mode_text,"requested"));
    strcpy(a.language_pref,"zh");tb_receiver_apply_language_preference(&a);
    assert(strstr(a.mode_text,"4480 x 2520")&&strstr(a.mode_text,"请求"));
    strcpy(a.language_pref,"auto");
    raw(&a,4480,2520);
    assert(a.have_video_frame&&a.frames==1&&strstr(a.mode_text,"正在接收 4480 x 2520"));
    packet(&a,TB_PKT_UI_LANGUAGE,"{\"uiLanguage\":\"en\"}");
    assert(strcmp(a.mode_text,"4480 x 2520 px receiving")==0);
    strcpy(a.language_pref,"de");tb_receiver_apply_language_preference(&a);
    assert(strcmp(a.mode_text,"4480 x 2520 px werden empfangen")==0);
    strcpy(a.language_pref,"auto");tb_receiver_apply_language_preference(&a);
    assert(strcmp(a.mode_text,"4480 x 2520 px receiving")==0);
    packet(&a,TB_PKT_HELLO_RECEIVER,"{\"captureWidth\":2560,\"captureHeight\":1440,\"codec\":\"HEVC\"}");
    assert(strcmp(a.mode_text,"4480 x 2520 px receiving")==0); /* Actual frame wins. */
    uint8_t nv12[6]={0};on_frame(nv12,1920,nv12+4,1920,1920,1080,&a);
    assert(strcmp(a.mode_text,"1920 x 1080 px receiving")==0&&a.frames==2);
    uint8_t legacy[23]={1};be32(legacy+1,2);be32(legacy+5,2);be32(legacy+9,2);be32(legacy+13,2);
    handle_raw_frame(&a,legacy,sizeof legacy);
    assert(strcmp(a.mode_text,"2 x 2 px receiving")==0&&a.frames==3);
    render_result=-1;raw(&a,1024,512);render_result=0;
    assert(strcmp(a.mode_text,"2 x 2 px receiving")==0&&a.frames==3);
    close_client(&a);
    assert(closed==1&&a.client_fd==-1&&!a.have_video_frame&&!a.session_active);
    assert(strcmp(a.mode_text,tb_i18n_get("receiver.mode.default"))==0);
    assert(!strstr(a.mode_text,"2560")&&!strstr(a.mode_text,"4480")&&!strstr(a.mode_text,"2 x 2"));
    a.client_fd=7;
    packet(&a,TB_PKT_HELLO_RECEIVER,"{\"senderName\":\"Legacy Sender\"}");
    assert(strcmp(a.mode_text,tb_i18n_get("receiver.mode.default"))==0);
    raw(&a,320,180);
    assert(strcmp(a.mode_text,"320 x 180 px receiving")==0);
    close_client(&a);
    puts("Receiver stream mode: requested/received priority, real translations, RAW/NV12/encoded, failure and reconnect passed");
}
'''
with tempfile.TemporaryDirectory(prefix="tb-stream-mode-") as directory:
    path = Path(directory) / "test.c"
    path.write_text(fixture + body + checks)
    command = [*shlex.split(os.environ.get("CC", "cc")), "-std=c11", "-Wall", "-Wextra", "-Werror",
               "-Wno-unused-function", "-I" + str(root / "src"),
               '-DTB_LANGUAGE_SOURCE_DIR="' + str(languages) + '"', str(path),
               str(root / "src/tb_i18n.c"), "-o", str(path.with_suffix(""))]
    subprocess.run(command, check=True)
    subprocess.run([str(path.with_suffix(""))], check=True)
