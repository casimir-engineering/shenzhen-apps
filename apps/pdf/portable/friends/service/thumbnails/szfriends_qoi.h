/* QOI ("Quite OK Image", qoiformat.org, specification 1.0) for Shenzhen Friends file previews.
 *
 * C99 and libc only, so the bytes a friend's Mac sends are decoded by a few hundred lines this repository owns and
 * fuzzes (service/thumbnails/fuzz/), never by a general image library, and so a later Linux helper reuses it as is.
 * The decoder is strict where the reference decoder is lenient: a stream that ends before its last pixel, a run past
 * the last pixel, a missing or misplaced end marker, or bytes after it all fail, because an honest encoder (ours, or
 * the reference) never produces them and a thumbnail that needs leniency is not worth showing.
 *
 * Pixels are RGBA, 8 bits per channel, straight (not premultiplied) alpha, rows top to bottom.
 */
#ifndef SZFRIENDS_QOI_H
#define SZFRIENDS_QOI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SZFRIENDS_QOI_HEADER_SIZE 14
#define SZFRIENDS_QOI_END_SIZE 8
/* The smallest stream that can hold a pixel: header, one opcode, end marker. */
#define SZFRIENDS_QOI_MIN_SIZE (SZFRIENDS_QOI_HEADER_SIZE + 1 + SZFRIENDS_QOI_END_SIZE)

typedef struct szfriends_qoi_desc {
    uint32_t width;
    uint32_t height;
    uint8_t channels;   /* 3 (RGB) or 4 (RGBA); informative, the decoder always writes RGBA */
    uint8_t colorspace; /* 0: sRGB with linear alpha, 1: all channels linear */
} szfriends_qoi_desc;

/* Reads the header only, before anything is allocated: the magic, a width and height from 1 to the caps given, 3 or
 * 4 channels, colorspace 0 or 1, and a length that can hold the header and the end marker. Returns 1 and fills
 * `desc`, or 0. */
int szfriends_qoi_read_header(const uint8_t *data, size_t length, uint32_t max_width, uint32_t max_height,
                              szfriends_qoi_desc *desc);

/* Decodes a stream whose header szfriends_qoi_read_header accepted into `rgba`, which must hold exactly
 * width * height * 4 bytes (`rgba_size`). Every read is checked against `length`. Returns 1, or 0 for a malformed
 * stream (rgba then holds partial garbage the caller discards). */
int szfriends_qoi_decode(const uint8_t *data, size_t length, const szfriends_qoi_desc *desc, uint8_t *rgba,
                         size_t rgba_size);

/* Encodes width * height RGBA pixels with `channels` (3 when every pixel is opaque, else 4) in the header. Returns
 * the number of bytes written to `out`, or 0 when they would not fit in `out_size` or the arguments are invalid:
 * the caller then tries a smaller image (brief § Transfers: smaller steps until it fits). */
size_t szfriends_qoi_encode(const uint8_t *rgba, uint32_t width, uint32_t height, uint8_t channels, uint8_t *out,
                            size_t out_size);

#ifdef __cplusplus
}
#endif

#endif
