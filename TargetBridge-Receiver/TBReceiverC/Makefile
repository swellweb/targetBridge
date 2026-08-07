# TBReceiver pure-C build (macOS target).
#
# Prerequisites on the iMac (Intel) running OCLP macOS 14:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
#   brew install ffmpeg sdl2 pkgconf
#
# Build:
#   make
#
# Run:
#   ./tbreceiver              # fullscreen
#   ./tbreceiver --windowed   # debug windowed
#
# Linux target (later): identical sources, swap LDFLAGS to pkgconf on
#   libavcodec libavutil sdl2 ; drop -framework lines.

CC       ?= clang
PKG      ?= pkgconf
APP_VERSION ?= 3.2.0
APP_BUILD   ?= dev

MACOSX_DEPLOYMENT_TARGET ?= 11.0
export MACOSX_DEPLOYMENT_TARGET

CFLAGS   += -O2 -g -Wall -Wextra -Wno-unused-parameter -std=c11
CFLAGS   += $(shell $(PKG) --cflags libavcodec libavutil sdl2)
CFLAGS   += -DTB_RECEIVER_VERSION=\"$(APP_VERSION)\" -DTB_RECEIVER_BUILD=\"$(APP_BUILD)\"
# The wire codec is shared with the sender, which compiles the same source. Its
# object is built into this tree rather than beside the source, so nothing drops
# build artefacts into the shared directory.
CODEC     = ../../TargetBridge-Shared/codec
CODEC_OBJ = src/tb_dpcm.o
CFLAGS   += -I$(CODEC)
CFLAGS   += -DTB_LANGUAGE_SOURCE_DIR=\"$(abspath ../../TargetBridge-Shared/Languages)\"

LDFLAGS  += $(shell $(PKG) --libs libavcodec libavutil sdl2)

UNAME_S  := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
LDFLAGS  += -framework ApplicationServices -framework AppKit -framework CoreFoundation -framework CoreGraphics -framework CoreText -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework IOSurface -framework CoreServices -framework CoreAudio -framework AVFoundation -framework Metal -framework QuartzCore -framework IOKit
endif

C_SRC = src/main.c src/net.c src/decoder.c src/display.c src/tb_i18n.c src/tb_logship.c
OBJC_SRC = src/tb_gesture_bridge.m src/tb_display_tweaks.m src/tb_mic_capture.m src/tb_metal_plane.m src/tb_health.m
OBJ = $(C_SRC:.c=.o) $(OBJC_SRC:.m=.o) $(CODEC_OBJ)
BIN = tbreceiver

all: $(BIN)

$(BIN): $(OBJ)
	$(CC) -o $@ $(OBJ) $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

%.o: %.m
	$(CC) $(CFLAGS) -fobjc-arc -c -o $@ $<

$(CODEC_OBJ): $(CODEC)/tb_dpcm.c $(CODEC)/tb_dpcm.h
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJ) $(BIN) $(TEST_BIN) $(TEST_DPCM_BIN)

# Unit tests. net.c and tb_dpcm.c are pure POSIX/libc, so these need no
# ffmpeg/SDL/pkgconf — they run anywhere, including CI, with no hardware.
TEST_CFLAGS = -O2 -g -Wall -Wextra -Wno-unused-parameter -std=c11
TEST_BIN = test_net_parser
TEST_DPCM_BIN = test_dpcm

$(TEST_BIN): tests/test_net_parser.c src/net.c src/net.h src/proto.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_net_parser.c src/net.c -o $@

$(TEST_DPCM_BIN): tests/test_dpcm.c $(CODEC)/tb_dpcm.c $(CODEC)/tb_dpcm.h
	$(CC) $(TEST_CFLAGS) -I$(CODEC) tests/test_dpcm.c $(CODEC)/tb_dpcm.c -o $@

test: $(TEST_BIN) $(TEST_DPCM_BIN)
	./$(TEST_BIN)
	./$(TEST_DPCM_BIN)

.PHONY: all clean test
