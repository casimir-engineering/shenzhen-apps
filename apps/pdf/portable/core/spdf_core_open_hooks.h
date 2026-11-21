#pragma once

/* The open hooks of spdf_core_document.h (documents read while they download, camera frames), moved out of
 * shenzhen_pdf_core.c (whose line cap is frozen) and included there, where they are compiled. */

static spdf_core_progressive_hooks progressive_hooks; /* zero unless a frontend downloads documents */
void spdf_core_set_progressive_hooks(const spdf_core_progressive_hooks* hooks) { progressive_hooks = *hooks; }

static spdf_core_open_hook sensor_open_hook; /* NULL unless the frontend installed spdf_sensor_raw.c */
void spdf_core_set_sensor_open_hook(spdf_core_open_hook hook) { sensor_open_hook = hook; }
