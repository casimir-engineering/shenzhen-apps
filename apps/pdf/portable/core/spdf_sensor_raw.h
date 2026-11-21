#ifndef SPDF_SENSOR_RAW_H
#define SPDF_SENSOR_RAW_H

/* Raw camera sensor frames (.raw, .raw10): headerless Bayer data straight off an image sensor, shown as a picture.
 *
 * The layout comes from the file size (spdf_sensor_raw.c lists the known ones): packed 10-bit (MIPI RAW10, four
 * samples in five bytes) or 16-bit little-endian samples, 4096x3072, 4000x3000, 8000x6000 or 8192x6144. A name
 * ending in .4cell.raw10 (the Dothinkey app's unremosaiced full frame) holds 2x2 same-colour cells.
 *
 * Rendering: black level, the sensor's phase-detection pixels filled from their neighbours when the frame shows
 * them, one RGB pixel per 2x2 Bayer cell (half resolution), grey-world white balance, an exposure stretch that puts
 * the brightest 0.5% at white, and the sRGB curve. Everything is automatic per frame except the Bayer order, which
 * is guessed from the data (the two green sites of a cell match each other) unless the reader picked one. */

#include "mupdf/fitz.h"

#ifdef __cplusplus
extern "C" {
#endif

enum {
    SPDF_SENSOR_ORDER_AUTO = -1,
    SPDF_SENSOR_ORDER_BGGR = 0,
    SPDF_SENSOR_ORDER_RGGB,
    SPDF_SENSOR_ORDER_GBRG,
    SPDF_SENSOR_ORDER_GRBG,
    SPDF_SENSOR_ORDER_COUNT
};

/* Opens every .raw/.raw10 path through spdf_open from now on. A frontend that never calls it never links this file. */
void spdf_sensor_raw_install(void);

/* 1 when the path names a sensor frame by its extension. */
int spdf_sensor_raw_path(const char* path);

/* "BGGR", "RGGB", "GBRG" or "GRBG"; NULL outside 0..3. */
const char* spdf_sensor_raw_order_name(int order);

/* The order the reader picked for a path, or SPDF_SENSOR_ORDER_AUTO. Called on whichever thread opens the file. */
typedef int (*spdf_sensor_raw_order_lookup)(const char* path);
void spdf_sensor_raw_set_order_lookup(spdf_sensor_raw_order_lookup lookup);

/* The order the last open of this path used (picked or guessed), or SPDF_SENSOR_ORDER_AUTO before any open. */
int spdf_sensor_raw_shown_order(const char* path);

/* The frame as a one-page picture document. Throws FZ_ERROR_FORMAT with a reader-facing message when the size
 * matches no known layout. order is SPDF_SENSOR_ORDER_AUTO or a fixed order. */
fz_document* spdf_sensor_raw_open_document(fz_context* ctx, const char* path, int order);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_SENSOR_RAW_H */
