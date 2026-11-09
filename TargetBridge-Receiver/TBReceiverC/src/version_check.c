/* version_check.c — see version_check.h. */

#include "version_check.h"

#include <ctype.h>

/* Reads the next numeric part and moves *p past it and its dot. Stops at the
 * first character that is neither a digit nor a dot (e.g. "-rc1"). */
static long tb_version_next(const char **p) {
    long value = 0;
    if (!*p || !isdigit((unsigned char)**p)) return 0;
    while (isdigit((unsigned char)**p)) {
        if (value < 1000000) value = value * 10 + (**p - '0');
        (*p)++;
    }
    if (**p == '.') (*p)++;
    return value;
}

static int tb_version_has_more(const char *p) {
    return p && isdigit((unsigned char)*p);
}

int tb_version_compare(const char *a, const char *b) {
    const int a_empty = !a || !*a;
    const int b_empty = !b || !*b;
    if (a_empty || b_empty) return a_empty == b_empty ? 0 : (a_empty ? -1 : 1);
    while (tb_version_has_more(a) || tb_version_has_more(b)) {
        const long x = tb_version_next(&a);
        const long y = tb_version_next(&b);
        if (x != y) return x < y ? -1 : 1;
    }
    return 0;
}
