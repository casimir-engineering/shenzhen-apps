#include "scroll-source-core.h"
#include <cassert>
#include <limits>
int main() {
  scroll_source::Ring ring;
  ring.add(1000, 1, true, 1, 0);
  ring.add(1008, 1, true, 0, 0); // Smooth physical wheel, not a gesture.
  assert(ring.match(1000, 1, 1020) == 1);
  assert(ring.match(1008, 1, 1020) == 0);
  assert(ring.match(1004, 1, 1020) == -1); // Never choose by ring storage order.
  ring.add(1020, 1, true, 0, 2); // Momentum remains a gesture.
  assert(ring.match(1020, 1, 1030) == 1);
  ring.add(1040, 1, false, 1, 0);
  assert(ring.match(1040, 1, 1050) == 0);
  assert(ring.match(1020, 2, 1030) == -1);
  assert(ring.match(1060, 1, 1070) == -1);
  assert(ring.match(1020, 1, 4000) == -1);
  assert(ring.match(std::numeric_limits<double>::quiet_NaN(), 1, 1030) == -1);
  for (int i = 0; i < 129; i++) ring.add(2000 + i, 1, true, 1, 0);
  assert(ring.match(1040, 1, 2200) == -1);
  scroll_source::RotationQueue rotations;
  assert(rotations.add(1000, 1, 2.5, 10, 30));
  assert(rotations.add(1001, 2, -3, 20, 40));
  assert(rotations.add(1002, 1, -1.25, 10, 30));
  int delivered = 0; double sum = 0;
  rotations.drain(1, 1010, [&](const scroll_source::Rotation& event) {
    assert(event.window == 1);
    assert(event.epochMs == (delivered == 0 ? 1000 : 1002));
    sum += event.degrees; delivered++;
  });
  assert(delivered == 2 && sum == 1.25);
  rotations.drain(1, 1010, [&](const auto&) { assert(false); }); // Consume once.
  rotations.drain(2, 1010, [&](const auto& event) { assert(event.degrees == -3); delivered++; });
  assert(delivered == 3); // Another window's drain did not consume this event.
  assert(!rotations.add(1000, 0, 2, 0, 0));
  assert(!rotations.add(1000, 1, 0, 0, 0));
  assert(!rotations.add(1000, 1, 181, 0, 0));
  assert(!rotations.add(1000, 1, std::numeric_limits<double>::quiet_NaN(), 0, 0));
  assert(!rotations.add(1000, 1, 1, std::numeric_limits<double>::infinity(), 0));
  rotations.add(1, 1, 3, 0, 0);
  rotations.add(5000, 1, 3, 0, 0);
  rotations.drain(1, 3000, [&](const auto&) { assert(false); }); // Stale/future.
  for (int i = 0; i < 200; i++) rotations.add(6000 + i, 1, 1, 0, 0);
  delivered = 0;
  rotations.drain(1, 6200, [&](const auto& event) {
    assert(event.epochMs == 6072 + delivered); delivered++;
  });
  assert(delivered == 128); // Bounded overwrite retains the newest ordered samples.
  double x, y;
  assert(scroll_source::clientCoordinates(30, 70, 10, 20, 200, 100, false, x, y));
  assert(x == 20 && y == 50);
  assert(scroll_source::clientCoordinates(30, 70, 10, 20, 200, 100, true, x, y));
  assert(x == 20 && y == 50);
  assert(scroll_source::clientCoordinates(10, 120, 10, 20, 200, 100, false, x, y));
  assert(x == 0 && y == 0); // Content top-left, independent of window origin.
  assert(!scroll_source::clientCoordinates(210, 70, 10, 20, 200, 100, false, x, y));
  assert(!scroll_source::clientCoordinates(30, 19, 10, 20, 200, 100, true, x, y));
}
