#include "session_metrics.h"

#include <stdio.h>
#include <string.h>

static int checks;
static int failures;

#define CHECK(condition) do {                                                    \
    checks++;                                                                    \
    if (!(condition)) {                                                          \
        failures++;                                                              \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition);    \
    }                                                                            \
} while (0)

int main(void) {
    char json[512];
    int len = tb_session_metrics_json(
        json, sizeof(json), 59, 123456, 2, "metal", "VideoToolbox", "HEVC");
    const char *expected =
        "{\"receiverFPS\":59,\"renderedFrames\":123456,\"decodeErrors\":2,"
        "\"renderer\":\"metal\",\"decoder\":\"VideoToolbox\",\"codec\":\"HEVC\"}";

    CHECK(len == (int)strlen(expected));
    CHECK(strcmp(json, expected) == 0);
    CHECK(json[len] == '\0');

    char small[8];
    CHECK(tb_session_metrics_json(
              small, sizeof(small), 60, 1, 0, "opengl", "software", "H.264") == -1);
    CHECK(tb_session_metrics_json(NULL, 0, 0, 0, 0, NULL, NULL, NULL) == -1);

    len = tb_session_metrics_json(json, sizeof(json), 0, 0, 0, NULL, NULL, NULL);
    CHECK(len > 0);
    CHECK(strstr(json, "\"renderer\":\"unknown\"") != NULL);

    if (failures == 0) {
        printf("session metrics: %d checks passed\n", checks);
        return 0;
    }
    fprintf(stderr, "session metrics: %d/%d checks failed\n", failures, checks);
    return 1;
}
