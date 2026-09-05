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
APP_VERSION ?= 3.5.1
APP_BUILD   ?= dev

MACOSX_DEPLOYMENT_TARGET ?= 11.0
export MACOSX_DEPLOYMENT_TARGET

CFLAGS   += -O2 -g -Wall -Wextra -Wno-unused-parameter -std=c11
CFLAGS   += $(shell $(PKG) --cflags libavcodec libavutil libswscale sdl2)
CFLAGS   += -DTB_RECEIVER_VERSION=\"$(APP_VERSION)\" -DTB_RECEIVER_BUILD=\"$(APP_BUILD)\"
CFLAGS   += -DTB_LANGUAGE_SOURCE_DIR=\"$(abspath ../../TargetBridge-Shared/Languages)\"

LDFLAGS  += $(shell $(PKG) --libs libavcodec libavutil libswscale sdl2)

UNAME_S  := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
LDFLAGS  += -framework ApplicationServices -framework AppKit -framework CoreFoundation -framework CoreGraphics -framework CoreText -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework IOSurface -framework CoreServices -framework CoreAudio -framework SystemConfiguration
endif

C_SRC = src/main.c src/net.c src/decoder.c src/display.c src/input_queue.c src/idle_watchdog.c src/receiver_profile.c src/tb_i18n.c
OBJC_SRC = src/tb_gesture_bridge.m src/tb_display_tweaks.m
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
	rm -f $(OBJ) $(BIN) $(TEST_BIN) $(TEST_INPUT_QUEUE_BIN) $(TEST_IDLE_WATCHDOG_BIN) $(TEST_RECEIVER_PROFILE_BIN) test_monitor_shield

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

test_net_parser: tests/test_net_parser.c src/net.c src/net.h src/proto.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_net_parser.c src/net.c $(TEST_LDFLAGS) -o $@

$(TEST_INPUT_QUEUE_BIN): tests/test_input_queue.c src/input_queue.c src/input_queue.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_input_queue.c src/input_queue.c -o $@

$(TEST_IDLE_WATCHDOG_BIN): tests/test_idle_watchdog.c src/idle_watchdog.c src/idle_watchdog.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_idle_watchdog.c src/idle_watchdog.c -o $@

$(TEST_RECEIVER_PROFILE_BIN): tests/test_receiver_profile.c src/receiver_profile.c src/receiver_profile.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_receiver_profile.c src/receiver_profile.c -o $@

test: $(TEST_BIN) $(TEST_INPUT_QUEUE_BIN) $(TEST_IDLE_WATCHDOG_BIN) $(TEST_RECEIVER_PROFILE_BIN)
	./$(TEST_BIN)
	./$(TEST_INPUT_QUEUE_BIN)
	./$(TEST_IDLE_WATCHDOG_BIN)
	./$(TEST_RECEIVER_PROFILE_BIN)

# AppKit lifecycle coverage requires a logged-in macOS GUI session.
test_monitor_shield: tests/test_monitor_shield.m src/tb_gesture_bridge.m src/tb_gesture_bridge.h
	$(CC) -fobjc-arc -framework AppKit -framework CoreGraphics tests/test_monitor_shield.m -o $@

test-monitor-shield: test_monitor_shield
	./test_monitor_shield

.PHONY: all clean test test-monitor-shield
