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
LDFLAGS  += -framework ApplicationServices -framework AppKit -framework CoreFoundation -framework CoreGraphics -framework CoreText -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework IOSurface -framework CoreServices -framework CoreAudio -framework SystemConfiguration -framework Metal -framework QuartzCore -lc++
endif

C_SRC = src/main.c src/net.c src/decoder.c src/display.c src/input_queue.c src/receiver_profile.c src/renderer_policy.c src/tb_i18n.c
OBJC_SRC = src/tb_gesture_bridge.m src/tb_display_tweaks.m
OBJCXX_SRC =
ifeq ($(UNAME_S),Darwin)
OBJCXX_SRC += src/tb_native_metal_renderer.m
endif
OBJ = $(C_SRC:.c=.o) $(OBJC_SRC:.m=.o) $(OBJCXX_SRC:.m=.o)
BIN = tbreceiver

all: $(BIN)

$(BIN): $(OBJ)
	$(CC) -o $@ $(OBJ) $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

%.o: %.m
	$(CC) $(CFLAGS) -fobjc-arc -c -o $@ $<

src/tb_native_metal_renderer.o: src/tb_native_metal_renderer.m src/tb_native_metal_renderer.h
	$(CC) $(filter-out -std=c11,$(CFLAGS)) -std=c++17 -x objective-c++ -fobjc-arc -c -o $@ $<

clean:
	rm -f $(OBJ) $(BIN) $(TEST_BIN) $(TEST_INPUT_QUEUE_BIN) $(TEST_RECEIVER_PROFILE_BIN) $(TEST_RENDERER_POLICY_BIN) $(TEST_NATIVE_METAL_BIN) $(BENCH_NATIVE_METAL_BIN) $(BENCH_OPENGL_BIN)

# Unit tests for the packet parser. net.c is pure POSIX, so this needs no
# ffmpeg/SDL/pkgconf — it runs anywhere, including CI, with no hardware.
TEST_CFLAGS = -O2 -g -Wall -Wextra -Wno-unused-parameter -std=c11
TEST_LDFLAGS =
ifeq ($(UNAME_S),Darwin)
TEST_LDFLAGS += -framework CoreFoundation -framework SystemConfiguration
endif
TEST_BIN = test_net_parser
TEST_INPUT_QUEUE_BIN = test_input_queue
TEST_RECEIVER_PROFILE_BIN = test_receiver_profile
TEST_RENDERER_POLICY_BIN = test_renderer_policy
TEST_NATIVE_METAL_BIN = test_native_metal_renderer
BENCH_NATIVE_METAL_BIN = benchmark_native_metal_renderer
BENCH_OPENGL_BIN = benchmark_sdl_opengl_renderer
TEST_PLATFORM_BINS =
ifeq ($(UNAME_S),Darwin)
TEST_PLATFORM_BINS += $(TEST_NATIVE_METAL_BIN)
endif

test_net_parser: tests/test_net_parser.c src/net.c src/net.h src/proto.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_net_parser.c src/net.c $(TEST_LDFLAGS) -o $@

$(TEST_INPUT_QUEUE_BIN): tests/test_input_queue.c src/input_queue.c src/input_queue.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_input_queue.c src/input_queue.c -o $@

$(TEST_RECEIVER_PROFILE_BIN): tests/test_receiver_profile.c src/receiver_profile.c src/receiver_profile.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_receiver_profile.c src/receiver_profile.c -o $@

$(TEST_RENDERER_POLICY_BIN): tests/test_renderer_policy.c src/renderer_policy.c src/renderer_policy.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_renderer_policy.c src/renderer_policy.c -lm -o $@

$(TEST_NATIVE_METAL_BIN): tests/test_native_metal_renderer.m src/tb_native_metal_renderer.m src/tb_native_metal_renderer.h
	$(CC) -O2 -g -Wall -Wextra -Isrc -std=c++17 -x objective-c++ -fobjc-arc \
		tests/test_native_metal_renderer.m src/tb_native_metal_renderer.m \
		-framework AppKit -framework CoreVideo -framework IOSurface -framework Metal -framework QuartzCore -lc++ -o $@

$(BENCH_NATIVE_METAL_BIN): benchmarks/benchmark_native_metal_renderer.m src/tb_native_metal_renderer.m src/tb_native_metal_renderer.h src/renderer_policy.c src/renderer_policy.h
	$(CC) -O2 -g -Wall -Wextra -Isrc -std=c++17 -x objective-c++ -fobjc-arc \
		benchmarks/benchmark_native_metal_renderer.m src/tb_native_metal_renderer.m src/renderer_policy.c \
		-framework AppKit -framework CoreVideo -framework IOSurface -framework Metal -framework QuartzCore -lc++ -o $@

benchmark-metal: $(BENCH_NATIVE_METAL_BIN)
	./$(BENCH_NATIVE_METAL_BIN)

$(BENCH_OPENGL_BIN): benchmarks/benchmark_sdl_opengl_renderer.c
	$(CC) -O2 -g -Wall -Wextra $(shell $(PKG) --cflags sdl2) \
		benchmarks/benchmark_sdl_opengl_renderer.c $(shell $(PKG) --libs sdl2) -o $@

benchmark-opengl: $(BENCH_OPENGL_BIN)
	./$(BENCH_OPENGL_BIN)

test: $(TEST_BIN) $(TEST_INPUT_QUEUE_BIN) $(TEST_RECEIVER_PROFILE_BIN) $(TEST_RENDERER_POLICY_BIN) $(TEST_PLATFORM_BINS)
	./$(TEST_BIN)
	./$(TEST_INPUT_QUEUE_BIN)
	./$(TEST_RECEIVER_PROFILE_BIN)
	./$(TEST_RENDERER_POLICY_BIN)
ifeq ($(UNAME_S),Darwin)
	./$(TEST_NATIVE_METAL_BIN)
endif

.PHONY: all clean test benchmark-metal benchmark-opengl
