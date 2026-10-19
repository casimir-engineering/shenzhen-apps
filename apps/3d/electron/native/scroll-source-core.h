#pragma once
#include <array>
#include <cmath>
#include <cstdint>

namespace scroll_source {
struct Sample {
  double epochMs = 0;
  int64_t window = 0;
  bool gesture = false;
};
class Ring {
 public:
  void add(double epochMs, int64_t window, bool precise, uint64_t phase,
           uint64_t momentum) {
    samples_[next_++ % samples_.size()] =
        {epochMs, window, precise && (phase != 0 || momentum != 0)};
  }
  // Return -1 for unknown, 0 for wheel, 1 for an AppKit fluid scroll gesture.
  int match(double epochMs, int64_t window, double nowMs) const {
    if (!std::isfinite(epochMs) || epochMs > nowMs + 20 || nowMs - epochMs > 2000)
      return -1;
    double best = 12.0;
    int result = -1;
    bool ambiguous = false;
    for (const auto& sample : samples_) {
      const double difference = std::abs(sample.epochMs - epochMs);
      if (sample.epochMs <= 0 || sample.window != window || difference > 12.0) continue;
      const int kind = sample.gesture ? 1 : 0;
      if (difference < best - 0.000001 || result == -1) {
        best = difference;
        result = kind;
        ambiguous = false;
      } else if (std::abs(difference - best) <= 0.000001 && kind != result) {
        ambiguous = true;
      }
    }
    return ambiguous ? -1 : result;
  }
 private:
  std::array<Sample, 128> samples_{};
  uint64_t next_ = 0;
};
struct Rotation {
  double epochMs = 0;
  int64_t window = 0;
  double degrees = 0, x = 0, y = 0;
  bool active = false;
};
inline bool clientCoordinates(double pointX, double pointY, double originX,
                              double originY, double width, double height,
                              bool flipped, double& x, double& y) {
  x = pointX - originX;
  y = flipped ? pointY - originY : originY + height - pointY;
  return std::isfinite(x) && std::isfinite(y) && width > 0 && height > 0 &&
         x >= 0 && y >= 0 && x < width && y < height;
}
class RotationQueue {
 public:
  bool add(double epochMs, int64_t window, double degrees, double x, double y) {
    if (!std::isfinite(epochMs) || epochMs <= 0 || window <= 0 ||
        !std::isfinite(degrees) || degrees == 0 || std::abs(degrees) > 180 ||
        !std::isfinite(x) || !std::isfinite(y) ||
        std::abs(x) > 1000000 || std::abs(y) > 1000000) return false;
    events_[next_++ % events_.size()] = {epochMs, window, degrees, x, y, true};
    return true;
  }
  template <typename Emit>
  void drain(int64_t window, double nowMs, Emit emit) {
    if (window <= 0 || !std::isfinite(nowMs)) return;
    // Chronological, bounded, consume-once delivery; other windows stay queued.
    for (size_t i = 0; i < events_.size(); i++) {
      auto& event = events_[(next_ + i) % events_.size()];
      if (!event.active) continue;
      if (event.window != window) continue;
      if (event.epochMs > nowMs + 20 || nowMs - event.epochMs > 2000) {
        event.active = false;
        continue;
      }
      event.active = false;
      emit(event);
    }
  }
 private:
  std::array<Rotation, 128> events_{};
  uint64_t next_ = 0;
};
}  // namespace scroll_source
