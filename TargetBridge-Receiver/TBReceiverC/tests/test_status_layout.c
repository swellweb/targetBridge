#include "status_layout.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

int main(void) {
    const int sizes[][2] = {
        {640, 480}, {980, 620}, {1280, 720}, {1920, 1080},
        {2560, 1440}, {3072, 1920}, {5120, 2880}
    };
    for (size_t i = 0; i < sizeof(sizes) / sizeof(sizes[0]); ++i) {
        struct tb_status_layout layout = tb_status_layout_for_size(sizes[i][0], sizes[i][1]);
        assert(layout.scale > 0 && layout.scale <= 1);
        assert(layout.width >= 980);
        assert(layout.height >= 900);
        assert(674 < layout.height - 138); /* Last card precedes the help text. */
        assert(fabs(layout.width * layout.scale - sizes[i][0]) < 0.000001);
        assert(fabs(layout.height * layout.scale - sizes[i][1]) < 0.000001);
    }
    assert(tb_status_layout_for_size(1920, 1080).scale == 1);
    puts("status layout tests: 43 checks passed");
    return 0;
}
