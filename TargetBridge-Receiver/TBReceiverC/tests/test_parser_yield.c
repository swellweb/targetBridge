#include "net.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static int count, limit;
static unsigned char seen[8];
static int yield(void *ud) { (void)ud; return count >= limit; }
static void packet(uint8_t type, const uint8_t *data, size_t len, void *ud) {
    (void)ud;
    assert(len == 1 && data[len] == '\0');
    assert(type == 0x21);
    seen[count++] = data[0];
}
static void reset(struct tb_parser *p) {
    tb_parser_free(p);
    tb_parser_init(p, packet, NULL);
    count = 0;
    limit = 1;
    memset(seen, 0, sizeof(seen));
}
int main(void) {
    struct tb_parser p;
    tb_parser_init(&p, packet, NULL);
    const uint8_t batch[] = {0,0,0,2,0x21,1, 0,0,0,2,0x21,2, 0,0,0,2,0x21,3};
    reset(&p);
    assert(tb_parser_feed_until(&p, NULL, 0, yield, NULL) == 0 && p.buf == NULL);
    assert(tb_parser_feed_until(&p, batch, sizeof(batch), yield, NULL) == 1);
    assert(count == 1 && p.len == 12 && seen[0] == 1);
    limit = 2;
    assert(tb_parser_feed_until(&p, NULL, 0, yield, NULL) == 1);
    assert(count == 2 && p.len == 6 && seen[1] == 2);
    limit = 4;
    assert(tb_parser_feed_until(&p, NULL, 0, yield, NULL) == 0);
    assert(count == 3 && p.len == 0 && seen[2] == 3);
    reset(&p);
    assert(tb_parser_feed_until(&p, batch, 3, yield, NULL) == 0);
    assert(count == 0 && p.len == 3);
    assert(tb_parser_feed_until(&p, batch + 3, 2, yield, NULL) == 0);
    assert(count == 0 && p.len == 5);
    assert(tb_parser_feed_until(&p, batch + 5, 13, yield, NULL) == 1);
    limit = 8;
    assert(tb_parser_feed_until(&p, NULL, 0, yield, NULL) == 0);
    assert(count == 3 && memcmp(seen, "\1\2\3", 3) == 0);
    reset(&p);
    assert(tb_parser_feed(&p, batch, sizeof(batch)) == 0 && count == 3 && p.len == 0);
    reset(&p);
    uint8_t invalid[] = {0,0,0,0,0};
    assert(tb_parser_feed_until(&p, invalid, sizeof(invalid), yield, NULL) == -1);
    reset(&p);
    assert(tb_parser_feed_until(&p, batch, sizeof(batch), yield, NULL) == 1);
    tb_parser_free(&p);
    assert(p.len == 0 && p.buf == NULL);
    puts("parser yield: packet order, resume, fragmentation, sentinel, legacy API and reset passed");
}
