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
APP_VERSION ?= 3.4.2
APP_BUILD   ?= dev

MACOSX_DEPLOYMENT_TARGET ?= 13.0
export MACOSX_DEPLOYMENT_TARGET

CFLAGS   += -O2 -g -Wall -Wextra -Wno-unused-parameter -std=c11
CFLAGS   += $(shell $(PKG) --cflags libavcodec libavutil sdl2)
CFLAGS   += -DTB_RECEIVER_VERSION=\"$(APP_VERSION)\" -DTB_RECEIVER_BUILD=\"$(APP_BUILD)\"
CFLAGS   += -DTB_LANGUAGE_SOURCE_DIR=\"$(abspath ../../TargetBridge-Shared/Languages)\"

LDFLAGS  += $(shell $(PKG) --libs libavcodec libavutil sdl2)

UNAME_S  := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
LDFLAGS  += -framework ApplicationServices -framework AppKit -framework CoreFoundation -framework CoreGraphics -framework CoreText -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework IOSurface -framework CoreServices -framework CoreAudio -framework SystemConfiguration
endif

C_SRC = src/main.c src/net.c src/decoder.c src/display.c src/tb_i18n.c src/sender_control.c src/receiver_state.c
OBJC_SRC = src/tb_gesture_bridge.m src/tb_display_tweaks.m src/tb_clipboard_bridge.m
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
	rm -f $(OBJ) $(BIN) $(TEST_BIN) $(TEST_CONTROL_BIN) $(TEST_STATE_BIN)

# Unit tests for the packet parser. net.c is pure POSIX, so this needs no
# ffmpeg/SDL/pkgconf — it runs anywhere, including CI, with no hardware.
TEST_CFLAGS = -O2 -g -Wall -Wextra -Wno-unused-parameter -std=c11
TEST_LDFLAGS =
ifeq ($(UNAME_S),Darwin)
TEST_LDFLAGS += -framework CoreFoundation -framework SystemConfiguration
endif
TEST_BIN = test_net_parser
TEST_CONTROL_BIN = test_sender_control
TEST_STATE_BIN = test_receiver_state

$(TEST_BIN): tests/test_net_parser.c src/net.c src/net.h src/proto.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_net_parser.c src/net.c $(TEST_LDFLAGS) -o $@

$(TEST_CONTROL_BIN): tests/test_sender_control.c src/sender_control.c src/sender_control.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_sender_control.c src/sender_control.c -o $@

$(TEST_STATE_BIN): tests/test_receiver_state.c src/receiver_state.c src/receiver_state.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_receiver_state.c src/receiver_state.c -o $@

test: $(TEST_BIN) $(TEST_CONTROL_BIN) $(TEST_STATE_BIN)
	./$(TEST_BIN)
	./$(TEST_CONTROL_BIN)
	./$(TEST_STATE_BIN)
	/bin/zsh tests/test_recovery_helper.zsh

.PHONY: all clean test
