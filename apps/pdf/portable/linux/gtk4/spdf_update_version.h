#pragma once

#include <glib.h>

G_BEGIN_DECLS

// Split on [.-], compare numeric fields, and zero-pad the shorter side.
// Malformed input returns 0 so it can never authorize an update.
int spdf_updater_compare_versions(const char* a, const char* b);

// Date-only compatibility check retained for non-health-check call sites.
gboolean spdf_updater_versions_match_primary(const char* a, const char* b);

// Relaunch health requires the complete YY.M.DD-BUILD identity on both sides.
gboolean spdf_update_versions_match_release_target(const char* target, const char* running);

G_END_DECLS
