#import "tb_native_metal_renderer.h"

#import <Metal/Metal.h>

#include <stdio.h>

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            printf("native Metal renderer test: skipped (no Metal device)\n");
            return 0;
        }

        void *renderer = tb_native_metal_create();
        if (!renderer) {
            fprintf(stderr,
                    "native Metal renderer test: device exists but renderer/shader creation failed\n");
            return 1;
        }
        tb_native_metal_destroy(renderer);
        printf("native Metal renderer test: device=%s shader/pipeline passed\n",
               device.name.UTF8String ?: "unknown");
        return 0;
    }
}
