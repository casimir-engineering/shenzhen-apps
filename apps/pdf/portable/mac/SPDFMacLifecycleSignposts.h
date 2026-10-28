#pragma once
#include <os/signpost.h>
#import <Foundation/Foundation.h>

// Launch and quit as Instruments shows them (os_signpost, subsystem com.intuition.shenzhenpdf, category Lifecycle):
// a "Launch" interval from main() to the post-first-paint tail, a "Quit" interval from the request to exit, and
// events at the steps in between. Off unless something is recording; the cost is a check of a flag.
static inline os_log_t spdf_mac_lifecycle_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.intuition.shenzhenpdf", "Lifecycle"); });
    return log;
}
#define SPDF_LIFECYCLE_BEGIN(name) os_signpost_interval_begin(spdf_mac_lifecycle_log(), OS_SIGNPOST_ID_EXCLUSIVE, name)
#define SPDF_LIFECYCLE_END(name) os_signpost_interval_end(spdf_mac_lifecycle_log(), OS_SIGNPOST_ID_EXCLUSIVE, name)
#define SPDF_LIFECYCLE_EVENT(name) os_signpost_event_emit(spdf_mac_lifecycle_log(), OS_SIGNPOST_ID_EXCLUSIVE, name)
