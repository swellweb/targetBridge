#include "version_check.h"

#include <stdio.h>

static int checks = 0;
static int failures = 0;

#define CHECK(condition, message) do { \
    checks++; \
    if (!(condition)) { \
        fprintf(stderr, "FAIL: %s\n", message); \
        failures++; \
    } \
} while (0)

int main(void) {
    CHECK(tb_version_compare("4.0", "4.0") == 0, "equal versions");
    CHECK(tb_version_compare("4.0", "4.0.0") == 0, "missing parts count as 0");
    CHECK(tb_version_compare("3.7.0-rc1", "4.0") == -1, "older release candidate");
    CHECK(tb_version_compare("4.0", "3.6.0") == 1, "newer major");
    CHECK(tb_version_compare("4.1", "4.0.9") == 1, "minor beats patch");
    CHECK(tb_version_compare("4.10", "4.9") == 1, "numeric, not text");
    CHECK(tb_version_compare(NULL, "4.0") == -1, "unknown is older");
    CHECK(tb_version_compare("4.0", "") == 1, "empty is older");
    CHECK(tb_version_compare(NULL, NULL) == 0, "both unknown");
    printf("version check: %d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
