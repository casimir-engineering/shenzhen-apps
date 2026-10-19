// Launch profiling: SPDF_LAUNCH_PROFILE=1 prints per-stage timestamps
// (microseconds since process start) so launch-budget regressions are
// visible in one line per stage. Same env var as the Mac frontend.
#include "spdf_internal.h"

#include <stdio.h>

static gint64 launch_epoch;
static int launch_enabled = -1;

gboolean spdf_launch_profile_enabled(void) {
    if (launch_enabled < 0) {
        const char *v = g_getenv("SPDF_LAUNCH_PROFILE");
        launch_enabled = (v != NULL && *v != '\0' && *v != '0') ? 1 : 0;
        launch_epoch = g_get_monotonic_time();
    }
    return launch_enabled == 1;
}

void spdf_launch_mark(const char *stage) {
    if (!spdf_launch_profile_enabled()) {
        return;
    }
    gint64 now = g_get_monotonic_time();
    fprintf(stderr, "SPDF-LAUNCH %8.1fms %s\n",
            (double)(now - launch_epoch) / 1000.0, stage);
}
