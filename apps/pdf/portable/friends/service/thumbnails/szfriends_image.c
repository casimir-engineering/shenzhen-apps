/* Downscaling and the PNG writer (szfriends_image.h). */

#include "service/thumbnails/szfriends_image.h"

#include <pthread.h>
#include <string.h>

enum { SZF_PNG_MAX_SIDE = 4096, SZF_STORED_BLOCK_MAX = 65535 };

int szfriends_rgba_downscale(const uint8_t *src, uint32_t sw, uint32_t sh, uint8_t *dst, uint32_t dw, uint32_t dh) {
    if (src == NULL || dst == NULL || dw == 0 || dh == 0 || dw > sw || dh > sh || sw > 65535u || sh > 65535u) {
        return 0;
    }
    for (uint32_t dy = 0; dy < dh; dy++) {
        /* Each destination pixel averages the source pixels whose top-left corner falls in its footprint; the
         * footprints tile the source exactly, so every source pixel counts once. */
        uint32_t y0 = (uint32_t)((uint64_t)dy * sh / dh), y1 = (uint32_t)((uint64_t)(dy + 1) * sh / dh);
        if (y1 <= y0) y1 = y0 + 1;
        for (uint32_t dx = 0; dx < dw; dx++) {
            uint32_t x0 = (uint32_t)((uint64_t)dx * sw / dw), x1 = (uint32_t)((uint64_t)(dx + 1) * sw / dw);
            if (x1 <= x0) x1 = x0 + 1;
            uint64_t r = 0, g = 0, b = 0, a = 0, count = 0;
            for (uint32_t y = y0; y < y1; y++) {
                const uint8_t *row = src + ((size_t)y * sw + x0) * 4;
                for (uint32_t x = x0; x < x1; x++, row += 4) {
                    r += (uint64_t)row[0] * row[3];
                    g += (uint64_t)row[1] * row[3];
                    b += (uint64_t)row[2] * row[3];
                    a += row[3];
                    count++;
                }
            }
            uint8_t *out = dst + ((size_t)dy * dw + dx) * 4;
            if (a == 0) {
                memset(out, 0, 4);
                continue;
            }
            out[0] = (uint8_t)((r + a / 2) / a);
            out[1] = (uint8_t)((g + a / 2) / a);
            out[2] = (uint8_t)((b + a / 2) / a);
            out[3] = (uint8_t)((a + count / 2) / count);
        }
    }
    return 1;
}

void szfriends_fit_size(uint32_t width, uint32_t height, uint32_t max_side, uint32_t *fit_width,
                        uint32_t *fit_height) {
    if (width == 0 || height == 0 || max_side == 0) {
        *fit_width = width ? 1 : 0;
        *fit_height = height ? 1 : 0;
        return;
    }
    uint32_t longer = width > height ? width : height;
    if (longer <= max_side) {
        *fit_width = width;
        *fit_height = height;
        return;
    }
    uint64_t w = ((uint64_t)width * max_side + longer / 2) / longer;
    uint64_t h = ((uint64_t)height * max_side + longer / 2) / longer;
    *fit_width = w == 0 ? 1 : (uint32_t)w;
    *fit_height = h == 0 ? 1 : (uint32_t)h;
}

static uint32_t szf_crc_table[256];
static pthread_once_t szf_crc_once = PTHREAD_ONCE_INIT;

/* Computed on first use rather than at load, so the helper pays for it only when it writes a thumbnail; once, because
 * thumbnails are written from more than one thread. */
static void szf_crc_init(void) {
    for (uint32_t n = 0; n < 256; n++) {
        uint32_t c = n;
        for (int k = 0; k < 8; k++) c = (c & 1) ? 0xedb88320u ^ (c >> 1) : c >> 1;
        szf_crc_table[n] = c;
    }
}

static uint32_t szf_crc(const uint8_t *data, size_t length) {
    uint32_t c = 0xffffffffu;
    for (size_t i = 0; i < length; i++) c = szf_crc_table[(c ^ data[i]) & 0xff] ^ (c >> 8);
    return c ^ 0xffffffffu;
}

static void szf_put_u32be(uint8_t *p, uint32_t value) {
    p[0] = (uint8_t)(value >> 24);
    p[1] = (uint8_t)(value >> 16);
    p[2] = (uint8_t)(value >> 8);
    p[3] = (uint8_t)value;
}

static size_t szf_raw_size(uint32_t width, uint32_t height) {
    return (size_t)height * ((size_t)width * 4 + 1); /* one filter byte per row */
}

static size_t szf_zlib_size(size_t raw) {
    size_t blocks = raw == 0 ? 1 : (raw + SZF_STORED_BLOCK_MAX - 1) / SZF_STORED_BLOCK_MAX;
    return 2 + blocks * 5 + raw + 4; /* zlib header, block headers, data, Adler-32 */
}

size_t szfriends_png_size(uint32_t width, uint32_t height) {
    if (width == 0 || height == 0 || width > SZF_PNG_MAX_SIDE || height > SZF_PNG_MAX_SIDE) return 0;
    /* signature, IHDR chunk (12 + 13), IDAT chunk (12 + data), IEND chunk (12) */
    return 8 + 25 + 12 + szf_zlib_size(szf_raw_size(width, height)) + 12;
}

/* Writes a chunk's length and type; the caller writes the data, then szf_end_chunk adds its CRC. */
static uint8_t *szf_begin_chunk(uint8_t *p, const char *type, size_t length) {
    szf_put_u32be(p, (uint32_t)length);
    memcpy(p + 4, type, 4);
    return p + 8;
}

static uint8_t *szf_end_chunk(uint8_t *chunk_type, uint8_t *data_end) {
    szf_put_u32be(data_end, szf_crc(chunk_type, (size_t)(data_end - chunk_type)));
    return data_end + 4;
}

size_t szfriends_png_encode(const uint8_t *rgba, uint32_t width, uint32_t height, uint8_t *out, size_t out_size) {
    size_t total = szfriends_png_size(width, height);
    if (rgba == NULL || out == NULL || total == 0 || out_size < total) return 0;
    pthread_once(&szf_crc_once, szf_crc_init);
    static const uint8_t signature[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
    uint8_t *p = out;
    memcpy(p, signature, 8);
    p += 8;

    uint8_t *type = p + 4;
    p = szf_begin_chunk(p, "IHDR", 13);
    szf_put_u32be(p, width);
    szf_put_u32be(p + 4, height);
    p[8] = 8;  /* bit depth */
    p[9] = 6;  /* colour type: RGBA */
    p[10] = 0; /* deflate */
    p[11] = 0; /* adaptive filtering, filter type chosen per row */
    p[12] = 0; /* no interlace */
    p = szf_end_chunk(type, p + 13);

    size_t raw = szf_raw_size(width, height);
    type = p + 4;
    p = szf_begin_chunk(p, "IDAT", szf_zlib_size(raw));
    *p++ = 0x78; /* CMF: deflate, 32 KiB window */
    *p++ = 0x01; /* FLG: no dictionary, check bits make CMF*256+FLG a multiple of 31 */
    uint32_t adler_a = 1, adler_b = 0;
    size_t row_bytes = (size_t)width * 4 + 1, position = 0; /* position within the raw (filtered) stream */
    while (position < raw) {
        size_t block = raw - position > SZF_STORED_BLOCK_MAX ? SZF_STORED_BLOCK_MAX : raw - position;
        *p++ = position + block == raw ? 1 : 0; /* BFINAL on the last block, BTYPE 00 (stored) */
        *p++ = (uint8_t)block;
        *p++ = (uint8_t)(block >> 8);
        *p++ = (uint8_t)~block;
        *p++ = (uint8_t)(~block >> 8);
        for (size_t i = 0; i < block; i++, position++) {
            size_t column = position % row_bytes;
            uint8_t byte = column == 0 ? 0 : rgba[(position / row_bytes) * (row_bytes - 1) + column - 1];
            *p++ = byte;
            adler_a = (adler_a + byte) % 65521u;
            adler_b = (adler_b + adler_a) % 65521u;
        }
    }
    szf_put_u32be(p, (adler_b << 16) | adler_a);
    p = szf_end_chunk(type, p + 4);

    type = p + 4;
    p = szf_begin_chunk(p, "IEND", 0);
    p = szf_end_chunk(type, p);
    return (size_t)(p - out);
}
