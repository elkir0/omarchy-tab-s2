// Reproducer for the hyprgraphics CAsyncResourceGatherer::await() lost wakeup.
// It does what Hyprland 0.56.2 IHyprRenderer::renderText(STextResourceData&&) does
// (src/render/Renderer.cpp:1628): enqueue(res) then await(res) on the same thread,
// with the debug overlay's warning text (src/debug/Overlay.cpp:368).
//
// usage: repro <iterations> <delay_us> <hang_seconds> [mode]
//   delay_us > 0 : sleep between enqueue() and await(), i.e. the main thread losing
//                  the CPU right after it woke the gather thread (deterministic).
//   mode "yield" : sched_yield() between enqueue() and await() instead of a sleep.
// A watchdog prints HANG and exits 2 when no await() returns for hang_seconds
// (choose > 5 s so the gather thread's 5 s wait_for poll cannot explain it).
#include <hyprgraphics/resource/AsyncResourceGatherer.hpp>
#include <hyprgraphics/resource/resources/TextResource.hpp>
#include <hyprutils/memory/Atomic.hpp>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sched.h>
#include <thread>
#include <unistd.h>

using namespace Hyprgraphics;
using namespace Hyprutils::Memory;
using namespace Hyprutils::Math;

static std::atomic<unsigned long> g_done{0};
static std::atomic<IAsyncResource*> g_cur{nullptr};
static unsigned long g_stalls = 0; // awaits that took > 1 s and then returned (lost requestsCV wakeup, healed by the 5 s poll)
static double g_maxAwait = 0;

int main(int argc, char** argv) {
    const long  ITERS   = argc > 1 ? atol(argv[1]) : 20000;
    const long  DELAYUS = argc > 2 ? atol(argv[2]) : 0;
    const int   HANGSEC = argc > 3 ? atoi(argv[3]) : 15;
    const bool  YIELD   = argc > 4 && !strcmp(argv[4], "yield");
    const auto  T0      = std::chrono::steady_clock::now();

    std::thread([HANGSEC, T0] {
        unsigned long last  = ~0UL;
        int           still = 0;
        while (true) {
            sleep(1);
            const unsigned long NOW = g_done.load();
            if (NOW != last) {
                last  = NOW;
                still = 0;
                continue;
            }
            if (++still < HANGSEC)
                continue;
            const auto* R = g_cur.load();
            const double SECS = std::chrono::duration<double>(std::chrono::steady_clock::now() - T0).count();
            printf("HANG: await() #%lu has not returned for %d s (t=%.1fs). resource m_ready=%d, cairoSurface=%s\n", NOW + 1, HANGSEC, SECS, R ? (int)R->m_ready.load() : -1,
                   R && R->m_asset.cairoSurface ? "set" : "null");
            printf("      %lu earlier awaits stalled > 1 s (max %.2f s)\n", g_stalls, g_maxAwait);
            printf("      m_ready=1 means the gather thread finished the resource and the wakeup was lost\n");
            fflush(stdout);
            _exit(2);
        }
    }).detach();

    CAsyncResourceGatherer gatherer;

    for (long i = 0; i < ITERS; ++i) {
        auto res = makeAtomicShared<CTextResource>(CTextResource::STextResourceData{
            .text     = "[!] FPS might be below your monitor's refresh rate if there are no content updates",
            .font     = "Sans",
            .fontSize = 8,
            .color    = CColor{CColor::SSRGB{.r = 1.0, .g = 1.0, .b = 0.0}},
            .maxSize  = Vector2D{300.F + (i % 7), -1.F},
        });
        g_cur = res.get();

        const auto TA = std::chrono::steady_clock::now();
        gatherer.enqueue(res);
        if (DELAYUS > 0)
            usleep(DELAYUS);
        else if (YIELD)
            sched_yield();
        gatherer.await(res);
        const double AW = std::chrono::duration<double>(std::chrono::steady_clock::now() - TA).count();
        if (AW > 1.0)
            g_stalls++;
        if (AW > g_maxAwait)
            g_maxAwait = AW;

        if (!res->m_asset.cairoSurface) {
            printf("render produced no surface at #%ld\n", i);
            return 3;
        }
        g_done++;
    }

    const double SECS = std::chrono::duration<double>(std::chrono::steady_clock::now() - T0).count();
    printf("OK: %ld enqueue+await in %.1fs (%.0f us each), delay_us=%ld%s; %lu stalls > 1 s, max await %.3f s\n", ITERS, SECS, SECS * 1e6 / ITERS, DELAYUS, YIELD ? " yield" : "",
           g_stalls, g_maxAwait);
    fflush(stdout);
    _exit(0);
}
