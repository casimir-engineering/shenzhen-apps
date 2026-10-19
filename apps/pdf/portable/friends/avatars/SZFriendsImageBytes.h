/* Byte-level checks on image files for the picture pipeline: private to avatars/.
 *
 * WHY our own checks in front of ImageIO:
 * - A picture received from a friend (or, while visible, from a stranger nearby, ADR 0004) is hostile until
 *   proven otherwise. Reading its frame header from the markers first lets the helper refuse anything but a small
 *   baseline JPEG before ImageIO parses a byte of it, and the same walk strips the metadata segments ImageIO's
 *   encoder adds to our own output.
 * - ImageIO decodes a truncated JPEG, PNG or HEIC without complaint, filling the missing part with gray, and
 *   reports it complete. A half-downloaded photo would become someone's picture; checking that the file reaches
 *   its format's end marker catches it.
 * Plain C99 so a later Linux helper can reuse it. Nothing here reads past `length`.
 */

#ifndef SZFRIENDS_IMAGE_BYTES_H
#define SZFRIENDS_IMAGE_BYTES_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    int sof_marker;          /* second byte of the frame header marker: 0xC0 baseline, 0xC2 progressive... */
    int frame_count;         /* frame headers before the first scan; a valid image has exactly one */
    unsigned precision;      /* bits per sample */
    unsigned width, height;  /* as declared in the frame header */
    unsigned components;     /* 1 gray, 3 YCbCr, 4 CMYK */
} szfriends_jpeg_info;

/* Walks marker segments from SOI to the first SOS (start of scan), filling `info`. Returns 0 when the structure
 * up to the scan is well formed and holds a frame header, -1 otherwise. */
int szfriends_jpeg_read_header(const uint8_t *bytes, size_t length, szfriends_jpeg_info *info);

/* Copies the JPEG into `out` (capacity at least `length`) without APP1-APP15 and COM segments, keeping APP0
 * (JFIF), the tables, the frame header and everything from the first scan on. Returns the new length, or 0 when
 * the structure is malformed. */
size_t szfriends_jpeg_strip_metadata(const uint8_t *bytes, size_t length, uint8_t *out);

/* 1 when the file is well formed up to its first scan and an EOI marker follows that scan (bytes after EOI are
 * allowed: some cameras append data). An embedded EXIF thumbnail's EOI sits before the scan and does not count. */
int szfriends_jpeg_is_complete(const uint8_t *bytes, size_t length);

/* 1 when the PNG holds its IEND chunk. */
int szfriends_png_is_complete(const uint8_t *bytes, size_t length);

/* 1 when the top-level ISO base media boxes (HEIC, HEIF) tile the file exactly, or the last extends to its end. */
int szfriends_bmff_is_complete(const uint8_t *bytes, size_t length);

/* 1 when the WebP file holds the whole RIFF chunk its header declares. */
int szfriends_webp_is_complete(const uint8_t *bytes, size_t length);

#endif
