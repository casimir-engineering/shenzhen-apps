/* JPEG marker walking for the picture pipeline. See SZFriendsImageBytes.h for why it exists. */

#include "avatars/SZFriendsImageBytes.h"

#include <string.h>

/* Frame header markers: C0-C3, C5-C7, C9-CB, CD-CF. C4 (DHT), C8 (reserved) and CC (DAC) are not frames. */
static int is_frame_marker(uint8_t marker) {
    return marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
}

/* Calls `visit` for every segment between SOI and the first SOS, then reports where the scan starts. `visit`
 * gets the marker byte and the whole segment: any fill bytes, the marker, the length field and the payload.
 * Returns the offset of the SOS segment, or 0 on malformed input. */
typedef int (*segment_visitor)(void *context, uint8_t marker, const uint8_t *segment, size_t segment_length);

static size_t walk_segments(const uint8_t *bytes, size_t length, segment_visitor visit, void *context) {
    if (!bytes || length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return 0;
    size_t i = 2;
    for (;;) {
        if (i >= length || bytes[i] != 0xFF) return 0;
        size_t start = i;
        /* Any number of 0xFF fill bytes may precede a marker (ITU T.81 B.1.1.2). */
        while (i < length && bytes[i] == 0xFF) i++;
        if (i >= length) return 0;
        uint8_t marker = bytes[i++];
        if (marker == 0x00 || marker == 0xD8 || marker == 0xD9 || (marker >= 0xD0 && marker <= 0xD7)) {
            /* Stuffed zero, a second SOI, EOI or a restart marker before any scan: not an image. */
            return 0;
        }
        if (marker == 0x01) continue; /* TEM stands alone, without a length. */
        if (length - i < 2) return 0;
        size_t field = ((size_t)bytes[i] << 8) | bytes[i + 1];
        if (field < 2 || field > length - i) return 0;
        size_t total = (i - start) + field;
        if (marker == 0xDA) return start;
        if (visit && !visit(context, marker, bytes + start, total)) return 0;
        i += field;
    }
}

static int read_frame(void *context, uint8_t marker, const uint8_t *segment, size_t segment_length) {
    szfriends_jpeg_info *info = context;
    if (!is_frame_marker(marker)) return 1;
    /* The 0xFF fill bytes, if any, sit before the marker: locate the payload from the end of the marker. */
    size_t prefix = 0;
    while (prefix < segment_length && segment[prefix] == 0xFF) prefix++;
    const uint8_t *p = segment + prefix + 1 + 2; /* past the marker byte and the length field */
    size_t payload = segment_length - prefix - 1 - 2;
    if (payload < 6) return 0;
    unsigned components = p[5];
    if (payload != 6 + 3 * (size_t)components) return 0;
    info->frame_count++;
    info->sof_marker = marker;
    info->precision = p[0];
    info->height = ((unsigned)p[1] << 8) | p[2];
    info->width = ((unsigned)p[3] << 8) | p[4];
    info->components = components;
    return 1;
}

int szfriends_jpeg_read_header(const uint8_t *bytes, size_t length, szfriends_jpeg_info *info) {
    if (!info) return -1;
    memset(info, 0, sizeof *info);
    if (!walk_segments(bytes, length, read_frame, info)) return -1;
    return info->frame_count > 0 ? 0 : -1;
}

typedef struct {
    uint8_t *out;
    size_t used;
} strip_state;

static int copy_kept_segment(void *context, uint8_t marker, const uint8_t *segment, size_t segment_length) {
    strip_state *state = context;
    /* APP1-APP15 carry EXIF, XMP, ICC, IPTC and maker notes; COM carries free text. APP0 is the JFIF header. */
    if ((marker >= 0xE1 && marker <= 0xEF) || marker == 0xFE) return 1;
    memcpy(state->out + state->used, segment, segment_length);
    state->used += segment_length;
    return 1;
}

size_t szfriends_jpeg_strip_metadata(const uint8_t *bytes, size_t length, uint8_t *out) {
    if (!out) return 0;
    strip_state state = {out, 2};
    /* Validate first so a malformed input never leaves a partial copy that looks usable. */
    szfriends_jpeg_info info;
    if (szfriends_jpeg_read_header(bytes, length, &info) != 0) return 0;
    out[0] = 0xFF;
    out[1] = 0xD8;
    size_t scan = walk_segments(bytes, length, copy_kept_segment, &state);
    if (!scan) return 0;
    memcpy(out + state.used, bytes + scan, length - scan);
    return state.used + (length - scan);
}

int szfriends_jpeg_is_complete(const uint8_t *bytes, size_t length) {
    size_t scan = walk_segments(bytes, length, NULL, NULL);
    if (!scan) return 0;
    /* Inside entropy-coded data a 0xFF is always followed by a stuffed 0x00 or a restart marker, so the first
     * FF D9 after the scan starts is the real end of image. */
    for (size_t i = scan; i + 1 < length; i++) {
        if (bytes[i] == 0xFF && bytes[i + 1] == 0xD9) return 1;
    }
    return 0;
}
