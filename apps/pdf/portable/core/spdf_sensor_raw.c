/* Raw camera sensor frames shown as pictures: see spdf_sensor_raw.h. */
#include "spdf_sensor_raw.h"
#include "spdf_core_document.h"

#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Known layouts, matched on the exact file size: each as packed RAW10 and as 16-bit little-endian samples. 4096x3072
 * is the OV50X50's binned output, 8192x6144 its full frame, 8000x6000 the Dothinkey app's full-resolution mode. */
static const struct {
    int width, height;
} known_sizes[] = {{4096, 3072}, {8192, 6144}, {8000, 6000}, {4000, 3000}};

#define NBSP "\xc2\xa0" /* keeps "4096 × 3072" on one line of the alert */

static const char* const order_names[SPDF_SENSOR_ORDER_COUNT] = {"BGGR", "RGGB", "GBRG", "GRBG"};

static spdf_sensor_raw_order_lookup order_lookup;

/* The order each recently opened path was shown with, for the menu's check mark. */
#define SHOWN_SLOTS 64
static struct {
    char* path;
    int order;
} shown[SHOWN_SLOTS];
static int shown_next;
static pthread_mutex_t shown_lock = PTHREAD_MUTEX_INITIALIZER;

const char* spdf_sensor_raw_order_name(int order) {
    return order >= 0 && order < SPDF_SENSOR_ORDER_COUNT ? order_names[order] : NULL;
}

void spdf_sensor_raw_set_order_lookup(spdf_sensor_raw_order_lookup lookup) { order_lookup = lookup; }

static void remember_shown(const char* path, int order) {
    int i;
    pthread_mutex_lock(&shown_lock);
    for (i = 0; i < SHOWN_SLOTS; ++i) {
        if (shown[i].path && strcmp(shown[i].path, path) == 0) {
            shown[i].order = order;
            pthread_mutex_unlock(&shown_lock);
            return;
        }
    }
    free(shown[shown_next].path);
    shown[shown_next].path = strdup(path);
    shown[shown_next].order = order;
    shown_next = (shown_next + 1) % SHOWN_SLOTS;
    pthread_mutex_unlock(&shown_lock);
}

int spdf_sensor_raw_shown_order(const char* path) {
    int i, order = SPDF_SENSOR_ORDER_AUTO;
    if (!path) return order;
    pthread_mutex_lock(&shown_lock);
    for (i = 0; i < SHOWN_SLOTS; ++i)
        if (shown[i].path && strcmp(shown[i].path, path) == 0) order = shown[i].order;
    pthread_mutex_unlock(&shown_lock);
    return order;
}

static int ends_with_nocase(const char* s, const char* suffix) {
    size_t n = strlen(s), m = strlen(suffix), i;
    if (m > n) return 0;
    for (i = 0; i < m; ++i) {
        char a = s[n - m + i];
        if (a >= 'A' && a <= 'Z') a = (char)(a + 32);
        if (a != suffix[i]) return 0;
    }
    return 1;
}

int spdf_sensor_raw_path(const char* path) {
    const char* slash;
    if (!path) return 0;
    slash = strrchr(path, '/');
    if (slash) path = slash + 1;
    return ends_with_nocase(path, ".raw") || ends_with_nocase(path, ".raw10");
}

#include "spdf_sensor_raw_stats.h"

static fz_buffer* render_frame(fz_context* ctx, frame* f, int order, int* shown_order) {
    const int cw = f->width / 2, ch = f->height / 2;
    const int (*site)[2];
    int bw = cw / 32, bh = ch / 32, nb, i, x, y, c;
    float *bmean = NULL, *tmp = NULL;
    float floor_level[3], gains[3] = {1.0f, 1.0f, 1.0f}, white;
    unsigned char lut[4097];
    fz_buffer* out = NULL;
    char header[64];
    size_t header_len;

    fz_var(out);
    fz_var(bmean);
    fz_var(tmp);
    fill_focus_pixels(f);
    if (order < 0 || order >= SPDF_SENSOR_ORDER_COUNT) order = guess_order(f);
    *shown_order = order;
    site = site_of[order];
    if (bw < 1) bw = 1;
    if (bh < 1) bh = 1;
    nb = bw * bh;

#define SAMPLE(cx, cy, s) ((float)f->px[(size_t)(2 * (cy) + site[s][0]) * (size_t)f->width + (size_t)(2 * (cx) + site[s][1])] - f->black)
#define CELL_RGB(cx, cy, rgb)                                                    \
    do {                                                                         \
        (rgb)[0] = SAMPLE(cx, cy, 0);                                            \
        (rgb)[1] = 0.5f * (SAMPLE(cx, cy, 1) + SAMPLE(cx, cy, 2));               \
        (rgb)[2] = SAMPLE(cx, cy, 3);                                            \
    } while (0)

    fz_try(ctx) {
        float range = f->sat - f->black;
        int ok_count = 0;
        bmean = (float*)fz_calloc(ctx, (size_t)nb * 3, sizeof(float));
        tmp = (float*)fz_calloc(ctx, (size_t)nb, sizeof(float));

        /* 64x64-pixel block means per colour: big enough that noise averages out of the choices below. */
        for (y = 0; y < bh * 32 && y < ch; ++y)
            for (x = 0; x < bw * 32 && x < cw; ++x) {
                float rgb[3];
                int b = (y / 32) * bw + x / 32;
                CELL_RGB(x, y, rgb);
                for (c = 0; c < 3; ++c) bmean[b * 3 + c] += rgb[c];
            }
        {
            int bx_cells = cw < 32 ? cw : 32, by_cells = ch < 32 ? ch : 32;
            float per = (float)(bx_cells * by_cells);
            for (i = 0; i < nb * 3; ++i) bmean[i] /= per;
        }

        /* Per-colour floor: the darkest blocks, so a black level a fraction off does not tint the shadows. */
        for (c = 0; c < 3; ++c) {
            for (i = 0; i < nb; ++i) tmp[i] = bmean[i * 3 + c];
            floor_level[c] = percentile(tmp, nb, 5.0f);
            if (floor_level[c] > 2.0f * f->unit) floor_level[c] = 2.0f * f->unit;
            if (floor_level[c] < -2.0f * f->unit) floor_level[c] = -2.0f * f->unit;
        }

        /* Grey world over the brighter half of the unclipped blocks. */
        for (i = 0; i < nb; ++i) {
            float* m = bmean + i * 3;
            if (m[0] >= 0.75f * range || m[1] >= 0.75f * range || m[2] >= 0.75f * range) continue;
            tmp[ok_count++] = (m[0] - floor_level[0] + m[1] - floor_level[1] + m[2] - floor_level[2]) / 3.0f;
        }
        if (ok_count > 0) {
            float lo, hi;
            double sum[3] = {0.0, 0.0, 0.0};
            int used = 0;
            float* sorted = (float*)fz_malloc(ctx, (size_t)ok_count * sizeof(float));
            memcpy(sorted, tmp, (size_t)ok_count * sizeof(float));
            lo = percentile(sorted, ok_count, 50.0f);
            memcpy(sorted, tmp, (size_t)ok_count * sizeof(float));
            hi = percentile(sorted, ok_count, 99.0f);
            fz_free(ctx, sorted);
            for (i = 0; i < nb; ++i) {
                float* m = bmean + i * 3;
                float lum;
                if (m[0] >= 0.75f * range || m[1] >= 0.75f * range || m[2] >= 0.75f * range) continue;
                lum = (m[0] - floor_level[0] + m[1] - floor_level[1] + m[2] - floor_level[2]) / 3.0f;
                if (lum < lo || lum > hi) continue;
                for (c = 0; c < 3; ++c) sum[c] += m[c] - floor_level[c];
                used++;
            }
            if (used && sum[0] > 0.0 && sum[1] > 0.0 && sum[2] > 0.0)
                for (c = 0; c < 3; ++c) {
                    gains[c] = (float)(sum[1] / sum[c]);
                    if (gains[c] < 0.25f) gains[c] = 0.25f;
                    if (gains[c] > 8.0f) gains[c] = 8.0f;
                }
        }

        /* Exposure: the brightest 0.5% of pixels at white. */
        {
            enum { BINS = 65536 };
            float top = 0.0f;
            size_t total = (size_t)cw * (size_t)ch, target, seen = 0;
            uint32_t* counts;
            for (y = 0; y < ch; ++y)
                for (x = 0; x < cw; ++x) {
                    float rgb[3], lum;
                    CELL_RGB(x, y, rgb);
                    lum = ((rgb[0] - floor_level[0]) * gains[0] + (rgb[1] - floor_level[1]) * gains[1] +
                           (rgb[2] - floor_level[2]) * gains[2]) / 3.0f;
                    if (lum > top) top = lum;
                }
            white = f->unit / 64.0f;
            if (top > 0.0f) {
                counts = (uint32_t*)fz_calloc(ctx, BINS, sizeof(uint32_t));
                for (y = 0; y < ch; ++y)
                    for (x = 0; x < cw; ++x) {
                        float rgb[3], lum;
                        int bin;
                        CELL_RGB(x, y, rgb);
                        lum = ((rgb[0] - floor_level[0]) * gains[0] + (rgb[1] - floor_level[1]) * gains[1] +
                               (rgb[2] - floor_level[2]) * gains[2]) / 3.0f;
                        bin = lum <= 0.0f ? 0 : (int)(lum / top * (BINS - 1));
                        counts[bin]++;
                    }
                target = total - total / 200;
                for (i = 0; i < BINS; ++i) {
                    seen += counts[i];
                    if (seen >= target) break;
                }
                fz_free(ctx, counts);
                if ((float)i / (BINS - 1) * top > white) white = (float)i / (BINS - 1) * top;
            }
        }

        for (i = 0; i <= 4096; ++i) {
            double v = (double)i / 4096.0;
            v = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055;
            lut[i] = (unsigned char)(v * 255.0 + 0.5);
        }

        header_len = (size_t)snprintf(header, sizeof(header), "P6\n%d %d\n255\n", cw, ch);
        out = fz_new_buffer(ctx, header_len + (size_t)cw * (size_t)ch * 3);
        fz_append_data(ctx, out, header, header_len);
        {
            unsigned char* row = (unsigned char*)fz_malloc(ctx, (size_t)cw * 3);
            float clip = f->sat - 8.0f * f->unit;
            fz_try(ctx) {
                for (y = 0; y < ch; ++y) {
                    for (x = 0; x < cw; ++x) {
                        const uint16_t* top_row = f->px + (size_t)(2 * y) * (size_t)f->width + (size_t)(2 * x);
                        const uint16_t* bottom_row = top_row + f->width;
                        int clipped = top_row[0] >= clip || top_row[1] >= clip || bottom_row[0] >= clip ||
                                      bottom_row[1] >= clip;
                        float rgb[3];
                        CELL_RGB(x, y, rgb);
                        for (c = 0; c < 3; ++c) {
                            float v = clipped ? 1.0f : (rgb[c] - floor_level[c]) * gains[c] / white;
                            if (v < 0.0f) v = 0.0f;
                            if (v > 1.0f) v = 1.0f;
                            row[x * 3 + c] = lut[(int)(v * 4096.0f + 0.5f)];
                        }
                    }
                    fz_append_data(ctx, out, row, (size_t)cw * 3);
                }
            }
            fz_always(ctx) fz_free(ctx, row);
            fz_catch(ctx) fz_rethrow(ctx);
        }
    }
    fz_always(ctx) {
        fz_free(ctx, bmean);
        fz_free(ctx, tmp);
    }
    fz_catch(ctx) {
        fz_drop_buffer(ctx, out);
        fz_rethrow(ctx);
    }
#undef CELL_RGB
#undef SAMPLE
    return out;
}

static void format_size(char* out, size_t len, int64_t bytes) {
    /* 15728640 -> "15,728,640" */
    char digits[32];
    int n = snprintf(digits, sizeof(digits), "%lld", (long long)bytes), i, o = 0;
    for (i = 0; i < n && (size_t)o + 2 < len; ++i) {
        if (i && (n - i) % 3 == 0) out[o++] = ',';
        out[o++] = digits[i];
    }
    out[o] = 0;
}

fz_document* spdf_sensor_raw_open_document(fz_context* ctx, const char* path, int order) {
    fz_stream* stm = NULL;
    fz_buffer* data = NULL;
    fz_buffer* picture = NULL;
    fz_document* doc = NULL;
    frame f;
    int quad = ends_with_nocase(path, ".4cell.raw10"), shown_order = SPDF_SENSOR_ORDER_BGGR;
    int64_t size;
    int width = 0, height = 0, wide = 0;
    size_t k;

    memset(&f, 0, sizeof(f));
    fz_var(stm);
    fz_var(data);
    fz_var(picture);
    fz_var(doc);
    fz_var(f.px);

    fz_try(ctx) {
        stm = fz_open_file(ctx, path);
        fz_seek(ctx, stm, 0, SEEK_END);
        size = fz_tell(ctx, stm);
        for (k = 0; k < sizeof(known_sizes) / sizeof(known_sizes[0]); ++k) {
            int64_t pixels = (int64_t)known_sizes[k].width * known_sizes[k].height;
            if (size == pixels * 5 / 4) width = known_sizes[k].width, height = known_sizes[k].height, wide = 0;
            if (size == pixels * 2) width = known_sizes[k].width, height = known_sizes[k].height, wide = 1;
        }
        if (!width) {
            char shown_size[40];
            format_size(shown_size, sizeof(shown_size), size);
            fz_throw(ctx, FZ_ERROR_FORMAT,
                     "This camera frame is %s bytes, which fits none of the frames ShenzhenPDF reads: "
                     "4096" NBSP "×" NBSP "3072, 4000" NBSP "×" NBSP "3000, 8000" NBSP "×" NBSP "6000 or "
                     "8192" NBSP "×" NBSP "6144 pixels, in packed 10-bit (RAW10) or 16-bit samples.",
                     shown_size);
        }
        fz_seek(ctx, stm, 0, SEEK_SET);
        data = fz_read_all(ctx, stm, (size_t)size);
        if ((int64_t)data->len != size) fz_throw(ctx, FZ_ERROR_FORMAT, "The camera frame could not be read in full.");

        f.width = width;
        f.height = height;
        f.px = (uint16_t*)fz_malloc(ctx, (size_t)width * (size_t)height * sizeof(uint16_t));
        {
            unsigned max_sample = 0, any_bits = 0, shift = 0, bits = 10;
            int x, y;
            if (!wide) {
                size_t stride = (size_t)width * 5 / 4;
                for (y = 0; y < height; ++y) {
                    const unsigned char* src = data->data + (size_t)y * stride;
                    uint16_t* dst = f.px + (size_t)y * (size_t)width;
                    for (x = 0; x < width; x += 4, src += 5) {
                        unsigned low = src[4];
                        dst[x] = (uint16_t)((src[0] << 2) | (low & 3));
                        dst[x + 1] = (uint16_t)((src[1] << 2) | ((low >> 2) & 3));
                        dst[x + 2] = (uint16_t)((src[2] << 2) | ((low >> 4) & 3));
                        dst[x + 3] = (uint16_t)((src[3] << 2) | ((low >> 6) & 3));
                    }
                }
            } else {
                size_t i, n = (size_t)width * (size_t)height;
                for (i = 0; i < n; ++i) {
                    unsigned v = (unsigned)data->data[2 * i] | ((unsigned)data->data[2 * i + 1] << 8);
                    f.px[i] = (uint16_t)v;
                    any_bits |= v;
                }
                /* Samples stored in the top bits of each 16-bit word come down to their own depth. */
                while (any_bits && !(any_bits & 1) && shift < 6) {
                    any_bits >>= 1;
                    shift++;
                }
                if (shift)
                    for (i = 0; i < n; ++i) f.px[i] = (uint16_t)(f.px[i] >> shift);
            }
            fz_drop_buffer(ctx, data);
            data = NULL;
            {
                size_t i, n = (size_t)width * (size_t)height;
                for (i = 0; i < n; ++i)
                    if (f.px[i] > max_sample) max_sample = f.px[i];
            }
            while (bits < 16 && max_sample > (1u << bits) - 1) bits++;
            f.unit = (float)(1u << (bits - 10));
            f.sat = (float)((1u << bits) - 1);
            if (quad) {
                /* 2x2 same-colour cells summed into one Bayer sample each. */
                int qw = width / 2, qh = height / 2;
                for (y = 0; y < qh; ++y)
                    for (x = 0; x < qw; ++x) {
                        const uint16_t* a = f.px + (size_t)(2 * y) * (size_t)width + (size_t)(2 * x);
                        unsigned sum = (unsigned)a[0] + a[1] + a[width] + a[width + 1];
                        f.px[(size_t)y * (size_t)qw + (size_t)x] = (uint16_t)(sum > 65535 ? 65535 : sum);
                    }
                f.width = qw;
                f.height = qh;
                f.unit *= 4.0f;
                f.sat = f.sat * 4.0f > 65535.0f ? 65535.0f : f.sat * 4.0f;
            }
            f.black = detect_black(&f);
        }

        picture = render_frame(ctx, &f, order, &shown_order);
        fz_free(ctx, f.px);
        f.px = NULL;
        doc = fz_open_document_with_buffer(ctx, "image/x-portable-pixmap", picture);
        remember_shown(path, shown_order);
    }
    fz_always(ctx) {
        fz_drop_stream(ctx, stm);
        fz_drop_buffer(ctx, data);
        fz_drop_buffer(ctx, picture);
        fz_free(ctx, f.px);
    }
    fz_catch(ctx) {
        fz_drop_document(ctx, doc);
        fz_rethrow(ctx);
    }
    return doc;
}

static fz_document* open_hook(fz_context* ctx, const char* path) {
    int order;
    if (!spdf_sensor_raw_path(path)) return NULL;
    order = order_lookup ? order_lookup(path) : SPDF_SENSOR_ORDER_AUTO;
    return spdf_sensor_raw_open_document(ctx, path, order);
}

void spdf_sensor_raw_install(void) { spdf_core_add_open_hook(open_hook); }
