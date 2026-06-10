#pragma once
// Log.h — minimal stderr logger, xylosome style: dry, timestamped, greppable.
#include <cstdio>
#include <ctime>

namespace xlog {
inline void stamp(const char *lvl) {
    timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
    tm tmv; localtime_r(&ts.tv_sec, &tmv);
    std::fprintf(stderr, "%02d:%02d:%02d.%03ld [%s] ",
                 tmv.tm_hour, tmv.tm_min, tmv.tm_sec, ts.tv_nsec / 1000000, lvl);
}
} // namespace xlog

#define LOGI(...) do { xlog::stamp("info"); std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); } while (0)
#define LOGW(...) do { xlog::stamp("warn"); std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); } while (0)
#define LOGE(...) do { xlog::stamp("err "); std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); } while (0)
