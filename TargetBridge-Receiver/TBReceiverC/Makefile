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
APP_VERSION ?= 3.6.0
APP_BUILD   ?= dev

MACOSX_DEPLOYMENT_TARGET ?= 11.0
export MACOSX_DEPLOYMENT_TARGET

CFLAGS   += -O2 -g -Wall -Wextra -Wno-unused-parameter -std=c11
CFLAGS   += $(shell $(PKG) --cflags libavcodec libavutil libswscale sdl2)
CFLAGS   += -I../../TargetBridge-Shared/codec
CFLAGS   += -DTB_RECEIVER_VERSION=\"$(APP_VERSION)\" -DTB_RECEIVER_BUILD=\"$(APP_BUILD)\"
CFLAGS   += -DTB_LANGUAGE_SOURCE_DIR=\"$(abspath ../../TargetBridge-Shared/Languages)\"

LDFLAGS  += $(shell $(PKG) --libs libavcodec libavutil libswscale sdl2)

UNAME_S  := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
LDFLAGS  += -framework ApplicationServices -framework AppKit -framework CoreFoundation -framework CoreGraphics -framework CoreText -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework IOSurface -framework CoreServices -framework CoreAudio -framework SystemConfiguration -framework Metal -framework QuartzCore -framework IOKit
endif

C_SRC = src/main.c src/net.c src/decoder.c src/display.c src/input_queue.c src/idle_watchdog.c src/receiver_profile.c src/tb_i18n.c ../../TargetBridge-Shared/codec/tb_dpcm.c
OBJC_SRC = src/tb_gesture_bridge.m src/tb_display_tweaks.m src/tb_metal_plane.m src/tb_health.m
OBJ = $(C_SRC:.c=.o) $(OBJC_SRC:.m=.o)
BIN = tbreceiver

all: $(BIN)

$(BIN): $(OBJ)
	$(CC) -o $@ $(OBJ) $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

%.o: %.m
	$(CC) $(CFLAGS) -fobjc-arc -c -o $@ $<

clean:
	rm -f $(OBJ) $(BIN) $(TEST_BIN) $(TEST_INPUT_QUEUE_BIN) $(TEST_IDLE_WATCHDOG_BIN) $(TEST_RECEIVER_PROFILE_BIN) $(TEST_DPCM_BIN) test_dpcm_gpu test_dpcm_metal test_hevc_startup test_monitor_shield

# Unit tests for the packet parser. net.c is pure POSIX, so this needs no
# ffmpeg/SDL/pkgconf — it runs anywhere, including CI, with no hardware.
TEST_CFLAGS = -O2 -g -Wall -Wextra -Wno-unused-parameter -std=c11
TEST_LDFLAGS =
ifeq ($(UNAME_S),Darwin)
TEST_LDFLAGS += -framework CoreFoundation -framework SystemConfiguration
endif
TEST_BIN = test_net_parser
TEST_INPUT_QUEUE_BIN = test_input_queue
TEST_IDLE_WATCHDOG_BIN = test_idle_watchdog
TEST_RECEIVER_PROFILE_BIN = test_receiver_profile
TEST_DPCM_BIN = test_dpcm

test_net_parser: tests/test_net_parser.c src/net.c src/net.h src/proto.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_net_parser.c src/net.c $(TEST_LDFLAGS) -o $@

$(TEST_INPUT_QUEUE_BIN): tests/test_input_queue.c src/input_queue.c src/input_queue.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_input_queue.c src/input_queue.c -o $@

$(TEST_IDLE_WATCHDOG_BIN): tests/test_idle_watchdog.c src/idle_watchdog.c src/idle_watchdog.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_idle_watchdog.c src/idle_watchdog.c -o $@

$(TEST_RECEIVER_PROFILE_BIN): tests/test_receiver_profile.c src/receiver_profile.c src/receiver_profile.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_receiver_profile.c src/receiver_profile.c -o $@

$(TEST_DPCM_BIN): tests/test_dpcm.c ../../TargetBridge-Shared/codec/tb_dpcm.c ../../TargetBridge-Shared/codec/tb_dpcm.h
	$(CC) $(TEST_CFLAGS) -I../../TargetBridge-Shared/codec tests/test_dpcm.c ../../TargetBridge-Shared/codec/tb_dpcm.c -o $@

test: $(TEST_BIN) $(TEST_INPUT_QUEUE_BIN) $(TEST_IDLE_WATCHDOG_BIN) $(TEST_RECEIVER_PROFILE_BIN) $(TEST_DPCM_BIN)
	./$(TEST_BIN)
	./$(TEST_INPUT_QUEUE_BIN)
	./$(TEST_IDLE_WATCHDOG_BIN)
	./$(TEST_RECEIVER_PROFILE_BIN)
	./$(TEST_DPCM_BIN)

# Optional: a Metal device is required, but all input pixels are synthetic.
test_dpcm_gpu: tests/test_dpcm_gpu.m ../../TargetBridge-Shared/codec/tb_dpcm.c ../../TargetBridge-Shared/codec/tb_dpcm.h ../../TargetBridge-Shared/codec/tb_dpcm_gpu.m ../../TargetBridge-Shared/codec/tb_dpcm_gpu.h
	$(CC) $(TEST_CFLAGS) -fobjc-arc -I../../TargetBridge-Shared/codec tests/test_dpcm_gpu.m ../../TargetBridge-Shared/codec/tb_dpcm.c -framework Foundation -framework Metal -o $@

test-dpcm-gpu: test_dpcm_gpu
	./test_dpcm_gpu

# Optional: a small SDL window, synthetic pixels, and GPU decode readback.
test_dpcm_metal: tests/test_dpcm_metal.m src/tb_metal_plane.m src/tb_metal_plane.h src/tb_health.m src/tb_health.h ../../TargetBridge-Shared/codec/tb_dpcm.c ../../TargetBridge-Shared/codec/tb_dpcm.h
	$(CC) $(CFLAGS) -fobjc-arc tests/test_dpcm_metal.m src/tb_health.m ../../TargetBridge-Shared/codec/tb_dpcm.c $(LDFLAGS) -o $@

test-dpcm-metal: test_dpcm_metal
	./test_dpcm_metal

# Optional: hardware HEVC startup from synthetic NV12/BGRA, no capture/window.
test_hevc_startup: tests/test_hevc_startup.m src/decoder.c src/decoder.h
	$(CC) $(CFLAGS) -Isrc -fobjc-arc tests/test_hevc_startup.m src/decoder.c $(shell $(PKG) --libs libavcodec libavutil libswscale) -framework Foundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo -o $@

test-hevc-startup: test_hevc_startup
	./test_hevc_startup

# AppKit lifecycle coverage requires a logged-in macOS GUI session.
test_monitor_shield: tests/test_monitor_shield.m src/tb_gesture_bridge.m src/tb_gesture_bridge.h
	$(CC) -fobjc-arc -framework AppKit -framework CoreGraphics tests/test_monitor_shield.m -o $@

test-monitor-shield: test_monitor_shield
	./test_monitor_shield

.PHONY: all clean test test-dpcm-gpu test-dpcm-metal test-hevc-startup test-monitor-shield
