#include <SDL.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static double elapsed_ms(uint64_t started, uint64_t frequency) {
    return (double)(SDL_GetPerformanceCounter() - started) * 1000.0 /
           (double)frequency;
}

int main(int argc, char **argv) {
    const int width = argc > 1 ? atoi(argv[1]) : 4096;
    const int height = argc > 2 ? atoi(argv[2]) : 2304;
    const int frame_count = argc > 3 ? atoi(argv[3]) : 180;
    const int target_fps = argc > 4 ? atoi(argv[4]) : 60;
    if (width <= 0 || height <= 0 || frame_count < 120 || target_fps <= 0) {
        fprintf(stderr,
                "usage: benchmark_sdl_opengl_renderer "
                "[width height frames>=120 fps]\n");
        return 64;
    }

    SDL_SetHint(SDL_HINT_RENDER_DRIVER, "opengl");
    SDL_SetHint(SDL_HINT_RENDER_VSYNC, "0");
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER) != 0) {
        fprintf(stderr, "TB_OPENGL_BENCHMARK result=failed reason=init error=%s\n",
                SDL_GetError());
        return 70;
    }

    SDL_Window *window = SDL_CreateWindow(
        "TargetBridge OpenGL Benchmark",
        SDL_WINDOWPOS_UNDEFINED,
        SDL_WINDOWPOS_UNDEFINED,
        (width + 1) / 2,
        (height + 1) / 2,
        SDL_WINDOW_BORDERLESS | SDL_WINDOW_ALLOW_HIGHDPI);
    if (!window) {
        fprintf(stderr, "TB_OPENGL_BENCHMARK result=failed reason=window error=%s\n",
                SDL_GetError());
        SDL_Quit();
        return 70;
    }
    (void)SDL_SetWindowOpacity(window, 0.02f);

    SDL_Renderer *renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
    SDL_RendererInfo renderer_info;
    memset(&renderer_info, 0, sizeof(renderer_info));
    int output_width = 0;
    int output_height = 0;
    if (!renderer || SDL_GetRendererInfo(renderer, &renderer_info) != 0 ||
        !renderer_info.name || strcmp(renderer_info.name, "opengl") != 0) {
        fprintf(stderr,
                "TB_OPENGL_BENCHMARK result=failed reason=renderer "
                "selected=%s error=%s\n",
                renderer_info.name ? renderer_info.name : "unavailable",
                SDL_GetError());
        if (renderer) SDL_DestroyRenderer(renderer);
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 70;
    }
    if (SDL_GetRendererOutputSize(renderer, &output_width, &output_height) != 0) {
        fprintf(stderr,
                "TB_OPENGL_BENCHMARK result=failed reason=output-size error=%s\n",
                SDL_GetError());
        SDL_DestroyRenderer(renderer);
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 70;
    }

    SDL_Texture *texture = SDL_CreateTexture(
        renderer,
        SDL_PIXELFORMAT_NV12,
        SDL_TEXTUREACCESS_STREAMING,
        width,
        height);
    const size_t y_size = (size_t)width * (size_t)height;
    const size_t uv_size = y_size / 2;
    uint8_t *y_plane = malloc(y_size);
    uint8_t *uv_plane = malloc(uv_size);
    if (!texture || !y_plane || !uv_plane) {
        fprintf(stderr,
                "TB_OPENGL_BENCHMARK result=failed reason=frame-setup error=%s\n",
                SDL_GetError());
        free(y_plane);
        free(uv_plane);
        if (texture) SDL_DestroyTexture(texture);
        SDL_DestroyRenderer(renderer);
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 70;
    }
    memset(y_plane, 128, y_size);
    memset(uv_plane, 128, uv_size);

    const uint64_t frequency = SDL_GetPerformanceFrequency();
    const uint64_t started = SDL_GetPerformanceCounter();
    double frame_time_ms_total = 0.0;
    double frame_time_ms_max = 0.0;
    int completed = 0;
    for (int frame = 0; frame < frame_count; frame++) {
        const uint64_t frame_started = SDL_GetPerformanceCounter();
        const int update_result = SDL_UpdateNVTexture(
            texture,
            NULL,
            y_plane,
            width,
            uv_plane,
            width);
        const int clear_result = SDL_RenderClear(renderer);
        const int copy_result = SDL_RenderCopy(renderer, texture, NULL, NULL);
        SDL_RenderPresent(renderer);
        const double frame_time_ms = elapsed_ms(frame_started, frequency);
        frame_time_ms_total += frame_time_ms;
        if (frame_time_ms > frame_time_ms_max) frame_time_ms_max = frame_time_ms;
        if (update_result != 0 || clear_result != 0 || copy_result != 0) {
            fprintf(stderr,
                    "TB_OPENGL_BENCHMARK result=failed reason=frame frame=%d "
                    "error=%s\n",
                    frame,
                    SDL_GetError());
            break;
        }
        completed++;
        SDL_PumpEvents();

        const double target_ms =
            (double)(frame + 1) * 1000.0 / (double)target_fps;
        const double wait_ms = target_ms - elapsed_ms(started, frequency);
        if (wait_ms >= 1.0) SDL_Delay((uint32_t)wait_ms);
    }
    const double total_elapsed_ms = elapsed_ms(started, frequency);
    const double uploaded_mib =
        (double)(y_size + uv_size) * (double)completed / (1024.0 * 1024.0);
    printf(
        "TB_OPENGL_BENCHMARK result=%s driver=%s size=%dx%d output=%dx%d requested=%d "
        "targetFPS=%d elapsed=%.3fs completed=%d frameCallAvg=%.3fms "
        "frameCallMax=%.3fms cpuUpload=%.1fMiB\n",
        completed == frame_count ? "opengl" : "failed",
        renderer_info.name,
        width,
        height,
        output_width,
        output_height,
        frame_count,
        target_fps,
        total_elapsed_ms / 1000.0,
        completed,
        completed ? frame_time_ms_total / (double)completed : 0.0,
        frame_time_ms_max,
        uploaded_mib);

    free(y_plane);
    free(uv_plane);
    SDL_DestroyTexture(texture);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();
    return completed == frame_count ? 0 : 2;
}
