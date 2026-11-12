require 'open3'
require 'tmpdir'

root = File.expand_path('..', __dir__)
source_dir = File.join(root, 'TargetBridge-Receiver/TBReceiverC/src')
source = File.read(File.join(source_dir, 'main.c'))
function = source[/(?:struct tb_drain_budget \{|static int drain_socket\()[\s\S]*?(?=\nstatic void write_be32)/]
abort 'Production drain_socket not found' unless function
fixture = <<~C
  #include "net.h"
  #include <assert.h>
  #include <errno.h>
  #include <stdint.h>
  #include <stdio.h>
  #include <string.h>
  #include <sys/types.h>
  #define TB_DRAIN_BUDGET_MS 8
  struct app { int client_fd, close_requested; struct tb_parser parser; };
  static uint64_t clock_ms;
  static int reads, packets, mode;
  static uint64_t now_ms(void) { return clock_ms; }
  static ssize_t fixture_read(int fd, void *output, size_t capacity) {
      (void)fd;
      ++reads;
      if (mode == 1 && reads == 1) { errno = EINTR; return -1; }
      if (reads > (mode == 1 ? 2 : 1)) { errno = EAGAIN; return -1; }
      unsigned char bytes[500];
      for (int i = 0; i < 100; i++) {
          const unsigned char packet[5] = {0, 0, 0, 1, (unsigned char)(0x20 + i)};
          memcpy(bytes + i * 5, packet, 5);
      }
      assert(capacity >= sizeof(bytes));
      memcpy(output, bytes, sizeof(bytes));
      return sizeof(bytes);
  }
  static void on_packet(uint8_t type, const uint8_t *payload, size_t len, void *ud) {
      (void)type; (void)payload; (void)len; (void)ud;
      assert(type == (uint8_t)(0x20 + packets) && len == 0);
      packets++;
      clock_ms += 9;
      if (mode == 2) ((struct app *)ud)->close_requested = 1;
  }
  #define read fixture_read
  #{function}
  int main(void) {
      struct app a = {0};
      tb_parser_init(&a.parser, on_packet, &a);
      assert(drain_socket(&a) == 1);
      printf("budget=8ms simulated_elapsed=%llums callbacks=%d reads=%d\\n",
          (unsigned long long)clock_ms, packets, reads);
      assert(packets == 1 && reads == 1);
      for (int i = 1; i < 100; i++) {
          assert(drain_socket(&a) == 1);
          assert(packets == i + 1 && reads == 1);
      }
      assert(a.parser.len == 0);
      puts("All 100 packets delivered in order across cooperative drain passes");
      tb_parser_free(&a.parser);
      for (mode = 1; mode <= 2; mode++) {
          reads = packets = 0;
          a.close_requested = 0;
          tb_parser_init(&a.parser, on_packet, &a);
          assert(drain_socket(&a) == 1 && packets == 1);
          assert(reads == (mode == 1 ? 2 : 1));
          if (mode == 2) {
              assert(a.close_requested && a.parser.len == 495);
              assert(drain_socket(&a) == 0 && packets == 1 && reads == 1);
          }
          tb_parser_free(&a.parser);
      }
      puts("EINTR retried; teardown stops buffered callbacks; reset discards pending data");
      return 0;
  }
C
Dir.mktmpdir('targetbridge-drain-review-') do |dir|
  path = File.join(dir, 'probe.c')
  File.write(path, fixture)
  binary = File.join(dir, 'probe')
  system('xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined', '-I', source_dir,
         path, File.join(source_dir, 'net.c'), '-framework', 'CoreFoundation',
         '-framework', 'SystemConfiguration', '-o', binary, exception: true)
  output, status = Open3.capture2e(binary)
  puts output
  exit status.exitstatus
end
