/* What happens to a thumbnail's pixels between the codec and the screen: scaling down to fit, and the PNG file the
 * views load. C99 and libc only, like szfriends_qoi.h, so nothing a friend sent reaches a system image codec and a
 * later Linux helper reuses it.
 *
 * Pixels are RGBA, 8 bits per channel, straight alpha, rows top to bottom.
 */
#ifndef SZFRIENDS_IMAGE_H
#define SZFRIENDS_IMAGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Area-average downscale of `src` (sw x sh) into `dst` (dw x dh), with 1 <= dw <= sw and 1 <= dh <= sh. Colours are
 * weighted by alpha, so transparent pixels do not darken the edges they border. Returns 1, or 0 for bad sizes. */
int szfriends_rgba_downscale(const uint8_t *src, uint32_t sw, uint32_t sh, uint8_t *dst, uint32_t dw, uint32_t dh);

/* The size within a box of `max_side` on the longer side keeping the aspect ratio, never upscaling and never below
 * one pixel. */
void szfriends_fit_size(uint32_t width, uint32_t height, uint32_t max_side, uint32_t *fit_width,
                        uint32_t *fit_height);

/* Exact size of the PNG szfriends_png_encode writes for these dimensions, or 0 when they are 0 or too large for it
 * (more than 4096 on a side: thumbnails are far smaller, and the bound keeps every size computation in range). */
size_t szfriends_png_size(uint32_t width, uint32_t height);

/* Writes an 8-bit RGBA, non-interlaced PNG: IHDR, one IDAT holding a zlib stream of stored (uncompressed) deflate
 * blocks with filter 0 on every row, and IEND. WHY uncompressed: a cache file of at most 192 x 192 pixels costs
 * about 148 KB, and the encoder stays small enough to read in one sitting. Returns the bytes written, or 0 when
 * `out_size` is smaller than szfriends_png_size. */
size_t szfriends_png_encode(const uint8_t *rgba, uint32_t width, uint32_t height, uint8_t *out, size_t out_size);

#ifdef __cplusplus
}
#endif

#endif
