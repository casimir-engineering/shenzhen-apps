#pragma once

/* The open hooks of spdf_core_document.h (documents read while they download, camera frames and RAW photos), moved
 * out of shenzhen_pdf_core.c (whose line cap is frozen) and included there, where they are compiled. */

static spdf_core_progressive_hooks progressive_hooks; /* zero unless a frontend downloads documents */
void spdf_core_set_progressive_hooks(const spdf_core_progressive_hooks* hooks) { progressive_hooks = *hooks; }

/* Empty unless the frontend installed spdf_sensor_raw.c or spdf_camera_raw.c. Added before any document opens. */
#define SPDF_CORE_OPEN_HOOK_SLOTS 4
static spdf_core_open_hook open_hooks[SPDF_CORE_OPEN_HOOK_SLOTS];

void spdf_core_add_open_hook(spdf_core_open_hook hook) {
    int i;
    for (i = 0; i < SPDF_CORE_OPEN_HOOK_SLOTS; ++i) {
        if (open_hooks[i] == hook) return;
        if (!open_hooks[i]) {
            open_hooks[i] = hook;
            return;
        }
    }
}

/* The document the first hook claiming the path makes, or NULL when none claims it. */
static fz_document* open_with_hooks(fz_context* ctx, const char* path) {
    fz_document* doc = NULL;
    int i;
    for (i = 0; i < SPDF_CORE_OPEN_HOOK_SLOTS && open_hooks[i] && !doc; ++i) doc = open_hooks[i](ctx, path);
    return doc;
}
