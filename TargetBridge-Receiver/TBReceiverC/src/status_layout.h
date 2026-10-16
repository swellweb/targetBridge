#ifndef TB_STATUS_LAYOUT_H
#define TB_STATUS_LAYOUT_H

struct tb_status_layout {
    double scale;
    double width;
    double height;
};

/* Keep the idle dashboard's cards above the bottom-anchored help text. */
static inline struct tb_status_layout tb_status_layout_for_size(int width, int height) {
    double scale = 1.0;
    if (width > 0 && height > 0) {
        if (width < 980) scale = (double)width / 980.0;
        if ((double)height / 900.0 < scale) scale = (double)height / 900.0;
    }
    return (struct tb_status_layout){scale, width / scale, height / scale};
}

#endif
