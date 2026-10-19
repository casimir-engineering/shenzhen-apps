/* QOI encoder and bounds-checked decoder (szfriends_qoi.h). Follows the QOI 1.0 specification's opcodes, hash and
 * initial state exactly, so streams interoperate with the reference implementation. */

#include "service/thumbnails/szfriends_qoi.h"

#include <string.h>

enum {
    SZF_QOI_OP_INDEX = 0x00, /* 00xxxxxx */
    SZF_QOI_OP_DIFF = 0x40,  /* 01xxxxxx */
    SZF_QOI_OP_LUMA = 0x80,  /* 10xxxxxx */
    SZF_QOI_OP_RUN = 0xc0,   /* 11xxxxxx */
    SZF_QOI_OP_RGB = 0xfe,
    SZF_QOI_OP_RGBA = 0xff,
    SZF_QOI_MASK_2 = 0xc0,
    SZF_QOI_RUN_MAX = 62, /* 63 and 64 would collide with the RGB and RGBA tags */
};

static const uint8_t szf_qoi_end_marker[SZFRIENDS_QOI_END_SIZE] = {0, 0, 0, 0, 0, 0, 0, 1};

typedef struct {
    uint8_t r, g, b, a;
} szf_rgba;

static unsigned szf_qoi_hash(szf_rgba p) {
    return ((unsigned)p.r * 3u + (unsigned)p.g * 5u + (unsigned)p.b * 7u + (unsigned)p.a * 11u) % 64u;
}

static uint32_t szf_read_u32be(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static void szf_write_u32be(uint8_t *p, uint32_t value) {
    p[0] = (uint8_t)(value >> 24);
    p[1] = (uint8_t)(value >> 16);
    p[2] = (uint8_t)(value >> 8);
    p[3] = (uint8_t)value;
}

int szfriends_qoi_read_header(const uint8_t *data, size_t length, uint32_t max_width, uint32_t max_height,
                              szfriends_qoi_desc *desc) {
    if (data == NULL || desc == NULL || length < SZFRIENDS_QOI_MIN_SIZE) return 0;
    if (memcmp(data, "qoif", 4) != 0) return 0;
    uint32_t width = szf_read_u32be(data + 4);
    uint32_t height = szf_read_u32be(data + 8);
    uint8_t channels = data[12];
    uint8_t colorspace = data[13];
    if (width == 0 || height == 0 || width > max_width || height > max_height) return 0;
    if ((channels != 3 && channels != 4) || colorspace > 1) return 0;
    desc->width = width;
    desc->height = height;
    desc->channels = channels;
    desc->colorspace = colorspace;
    return 1;
}

int szfriends_qoi_decode(const uint8_t *data, size_t length, const szfriends_qoi_desc *desc, uint8_t *rgba,
                         size_t rgba_size) {
    if (data == NULL || desc == NULL || rgba == NULL || length < SZFRIENDS_QOI_MIN_SIZE) return 0;
    /* The caps came from the header check; this guards the multiplication for any caller that skipped it. */
    if (desc->width == 0 || desc->height == 0 || desc->width > 65535u || desc->height > 65535u) return 0;
    size_t pixel_count = (size_t)desc->width * (size_t)desc->height;
    if (pixel_count > SIZE_MAX / 4 || rgba_size != pixel_count * 4) return 0;

    szf_rgba index[64];
    memset(index, 0, sizeof index);
    szf_rgba px = {0, 0, 0, 255};
    size_t chunks_end = length - SZFRIENDS_QOI_END_SIZE; /* opcodes never reach into the end marker */
    size_t p = SZFRIENDS_QOI_HEADER_SIZE;
    size_t written = 0;
    while (written < pixel_count) {
        if (p >= chunks_end) return 0; /* the stream ended before its last pixel */
        uint8_t b1 = data[p++];
        size_t run = 1;
        if (b1 == SZF_QOI_OP_RGB) {
            if (chunks_end - p < 3) return 0;
            px.r = data[p];
            px.g = data[p + 1];
            px.b = data[p + 2];
            p += 3;
        } else if (b1 == SZF_QOI_OP_RGBA) {
            if (chunks_end - p < 4) return 0;
            px.r = data[p];
            px.g = data[p + 1];
            px.b = data[p + 2];
            px.a = data[p + 3];
            p += 4;
        } else if ((b1 & SZF_QOI_MASK_2) == SZF_QOI_OP_INDEX) {
            px = index[b1];
        } else if ((b1 & SZF_QOI_MASK_2) == SZF_QOI_OP_DIFF) {
            px.r = (uint8_t)(px.r + ((b1 >> 4) & 0x03) - 2);
            px.g = (uint8_t)(px.g + ((b1 >> 2) & 0x03) - 2);
            px.b = (uint8_t)(px.b + (b1 & 0x03) - 2);
        } else if ((b1 & SZF_QOI_MASK_2) == SZF_QOI_OP_LUMA) {
            if (chunks_end - p < 1) return 0;
            uint8_t b2 = data[p++];
            int vg = (b1 & 0x3f) - 32;
            px.r = (uint8_t)(px.r + vg - 8 + ((b2 >> 4) & 0x0f));
            px.g = (uint8_t)(px.g + vg);
            px.b = (uint8_t)(px.b + vg - 8 + (b2 & 0x0f));
        } else { /* SZF_QOI_OP_RUN */
            run = (size_t)(b1 & 0x3f) + 1;
            if (run > pixel_count - written) return 0; /* a run past the last pixel */
        }
        index[szf_qoi_hash(px)] = px;
        for (size_t i = 0; i < run; i++) {
            uint8_t *out = rgba + written * 4;
            out[0] = px.r;
            out[1] = px.g;
            out[2] = px.b;
            out[3] = px.a;
            written++;
        }
    }
    /* Exactly the end marker follows the last opcode: no padding, no trailing bytes. */
    if (p != chunks_end) return 0;
    return memcmp(data + chunks_end, szf_qoi_end_marker, SZFRIENDS_QOI_END_SIZE) == 0;
}

size_t szfriends_qoi_encode(const uint8_t *rgba, uint32_t width, uint32_t height, uint8_t channels, uint8_t *out,
                            size_t out_size) {
    if (rgba == NULL || out == NULL || width == 0 || height == 0 || width > 65535u || height > 65535u) return 0;
    if (channels != 3 && channels != 4) return 0;
    if (out_size < SZFRIENDS_QOI_MIN_SIZE) return 0;
    size_t pixel_count = (size_t)width * (size_t)height;
    /* Room for the end marker is kept back from the start, so every opcode check below is against `limit`. */
    size_t limit = out_size - SZFRIENDS_QOI_END_SIZE;
    memcpy(out, "qoif", 4);
    szf_write_u32be(out + 4, width);
    szf_write_u32be(out + 8, height);
    out[12] = channels;
    out[13] = 0;
    size_t p = SZFRIENDS_QOI_HEADER_SIZE;

    szf_rgba index[64];
    memset(index, 0, sizeof index);
    szf_rgba previous = {0, 0, 0, 255};
    unsigned run = 0;
    for (size_t i = 0; i < pixel_count; i++) {
        const uint8_t *in = rgba + i * 4;
        szf_rgba px = {in[0], in[1], in[2], channels == 4 ? in[3] : 255};
        int last = i + 1 == pixel_count;
        if (px.r == previous.r && px.g == previous.g && px.b == previous.b && px.a == previous.a) {
            run++;
            if (run == SZF_QOI_RUN_MAX || last) {
                if (p + 1 > limit) return 0;
                out[p++] = (uint8_t)(SZF_QOI_OP_RUN | (run - 1));
                run = 0;
            }
            continue;
        }
        if (run > 0) {
            if (p + 1 > limit) return 0;
            out[p++] = (uint8_t)(SZF_QOI_OP_RUN | (run - 1));
            run = 0;
        }
        unsigned slot = szf_qoi_hash(px);
        if (index[slot].r == px.r && index[slot].g == px.g && index[slot].b == px.b && index[slot].a == px.a) {
            if (p + 1 > limit) return 0;
            out[p++] = (uint8_t)(SZF_QOI_OP_INDEX | slot);
        } else {
            index[slot] = px;
            if (px.a == previous.a) {
                int vr = (int)px.r - (int)previous.r, vg = (int)px.g - (int)previous.g;
                int vb = (int)px.b - (int)previous.b;
                /* Differences wrap around like the decoder's uint8_t arithmetic. */
                vr = (int)(int8_t)(uint8_t)vr;
                vg = (int)(int8_t)(uint8_t)vg;
                vb = (int)(int8_t)(uint8_t)vb;
                int vg_r = vr - vg, vg_b = vb - vg;
                if (vr > -3 && vr < 2 && vg > -3 && vg < 2 && vb > -3 && vb < 2) {
                    if (p + 1 > limit) return 0;
                    out[p++] = (uint8_t)(SZF_QOI_OP_DIFF | ((vr + 2) << 4) | ((vg + 2) << 2) | (vb + 2));
                } else if (vg_r > -9 && vg_r < 8 && vg > -33 && vg < 32 && vg_b > -9 && vg_b < 8) {
                    if (p + 2 > limit) return 0;
                    out[p++] = (uint8_t)(SZF_QOI_OP_LUMA | (vg + 32));
                    out[p++] = (uint8_t)(((vg_r + 8) << 4) | (vg_b + 8));
                } else {
                    if (p + 4 > limit) return 0;
                    out[p++] = SZF_QOI_OP_RGB;
                    out[p++] = px.r;
                    out[p++] = px.g;
                    out[p++] = px.b;
                }
            } else {
                if (p + 5 > limit) return 0;
                out[p++] = SZF_QOI_OP_RGBA;
                out[p++] = px.r;
                out[p++] = px.g;
                out[p++] = px.b;
                out[p++] = px.a;
            }
        }
        previous = px;
    }
    memcpy(out + p, szf_qoi_end_marker, SZFRIENDS_QOI_END_SIZE);
    return p + SZFRIENDS_QOI_END_SIZE;
}
