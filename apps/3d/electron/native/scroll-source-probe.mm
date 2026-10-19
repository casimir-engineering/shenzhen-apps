// Test-only event/clock inspection. Never staged or packaged in the app.
#import <AppKit/AppKit.h>
#include <mach/mach_time.h>
#include <node_api.h>

napi_value inspect(napi_env env, napi_callback_info) {
  mach_timebase_info_data_t timebase;
  mach_timebase_info(&timebase);
  const uint64_t nanoseconds = (uint64_t)((long double)mach_absolute_time() *
                                         timebase.numer / timebase.denom);
  CGEventRef cg = CGEventCreateScrollWheelEvent(nullptr, kCGScrollEventUnitPixel, 1, 10);
  CGEventSetTimestamp(cg, nanoseconds);
  NSEvent* event = [NSEvent eventWithCGEvent:cg];
  const double uptime = NSProcessInfo.processInfo.systemUptime;
  const double now = NSDate.date.timeIntervalSince1970 * 1000;
  napi_value result, value;
  napi_create_object(env, &result);
  napi_create_double(env, event.timestamp, &value);
  napi_set_named_property(env, result, "eventTimestampSeconds", value);
  napi_create_double(env, uptime, &value);
  napi_set_named_property(env, result, "systemUptimeSeconds", value);
  napi_create_double(env, now - uptime * 1000 + event.timestamp * 1000, &value);
  napi_set_named_property(env, result, "eventEpochMs", value);
  napi_create_double(env, now, &value);
  napi_set_named_property(env, result, "nowEpochMs", value);
  CFRelease(cg);
  return result;
}
napi_value init(napi_env env, napi_value exports) {
  napi_property_descriptor property = {"inspect", nullptr, inspect, nullptr, nullptr, nullptr, napi_default, nullptr};
  napi_define_properties(env, exports, 1, &property);
  return exports;
}
NAPI_MODULE(NODE_GYP_MODULE_NAME, init)
