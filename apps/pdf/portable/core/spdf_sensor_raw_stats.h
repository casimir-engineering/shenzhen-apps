#pragma once

/* The per-frame measurements behind spdf_sensor_raw.c's rendering (focus pixels, Bayer order, black level), kept
 * apart to hold each file under the size cap and included there, where they are compiled. */

static int compare_float(const void* a, const void* b) {
    float x = *(const float*)a, y = *(const float*)b;
    return x < y ? -1 : x > y ? 1 : 0;
}

/* p in [0,100] of n values; sorts the array. */
static float percentile(float* values, int n, float p) {
    int i;
    if (n <= 0) return 0.0f;
    qsort(values, (size_t)n, sizeof(float), compare_float);
    i = (int)floorf(p / 100.0f * (float)(n - 1) + 0.5f);
    if (i < 0) i = 0;
    if (i >= n) i = n - 1;
    return values[i];
}

/* Bayer site (row parity, column parity) of R, the two G and B for each order. */
static const int site_of[SPDF_SENSOR_ORDER_COUNT][4][2] = {
    /* R       G1      G2      B */
    {{1, 1}, {0, 1}, {1, 0}, {0, 0}}, /* BGGR */
    {{0, 0}, {0, 1}, {1, 0}, {1, 1}}, /* RGGB */
    {{1, 0}, {0, 0}, {1, 1}, {0, 1}}, /* GBRG */
    {{0, 1}, {0, 0}, {1, 1}, {1, 0}}, /* GRBG */
};

typedef struct frame {
    uint16_t* px; /* width x height Bayer samples */
    int width, height;
    float black;  /* in sample units */
    float unit;   /* one 10-bit step in sample units */
    float sat;    /* samples at or above this are clipped */
} frame;

/* Phase-detection pixels repeat on a 16x16 grid and read darker than the rest of their colour; when a phase of the
 * grid averages under 90% of its colour, its pixels take the mean of their same-colour neighbours two away. Too
 * dark a frame says nothing either way and is left alone. */
static void fill_focus_pixels(frame* f) {
    double sums[16][16] = {{0}};
    long counts[16][16] = {{0}};
    double site_sum[2][2] = {{0}};
    long site_count[2][2] = {{0}};
    int marked[16][16] = {{0}};
    int x, y, any = 0, n = 0;

    for (y = 0; y < f->height; ++y) {
        const uint16_t* row = f->px + (size_t)y * (size_t)f->width;
        for (x = 0; x < f->width; ++x) {
            sums[y & 15][x & 15] += row[x];
            counts[y & 15][x & 15]++;
        }
    }
    for (y = 0; y < 16; ++y)
        for (x = 0; x < 16; ++x) {
            site_sum[y & 1][x & 1] += sums[y][x] - f->black * (double)counts[y][x];
            site_count[y & 1][x & 1] += counts[y][x];
        }
    for (y = 0; y < 2; ++y)
        for (x = 0; x < 2; ++x)
            if (!site_count[y][x] || site_sum[y][x] / (double)site_count[y][x] < 4.0 * f->unit) return;
    for (y = 0; y < 16; ++y)
        for (x = 0; x < 16; ++x) {
            double mean = counts[y][x] ? sums[y][x] / (double)counts[y][x] - f->black : 0.0;
            double site = site_sum[y & 1][x & 1] / (double)site_count[y & 1][x & 1];
            if (counts[y][x] && mean < 0.9 * site) {
                marked[y][x] = 1;
                any = 1;
                n++;
            }
        }
    /* A real pattern is sparse; most of the grid reading dark is the scene, not the sensor. */
    if (!any || n > 64) return;
    for (y = 0; y < f->height; ++y) {
        uint16_t* row = f->px + (size_t)y * (size_t)f->width;
        for (x = 0; x < f->width; ++x) {
            static const int d[4][2] = {{0, 2}, {0, -2}, {2, 0}, {-2, 0}};
            int k, count = 0;
            unsigned sum = 0;
            if (!marked[y & 15][x & 15]) continue;
            for (k = 0; k < 4; ++k) {
                int yy = y + d[k][0], xx = x + d[k][1];
                if (yy < 0 || xx < 0 || yy >= f->height || xx >= f->width || marked[yy & 15][xx & 15]) continue;
                sum += f->px[(size_t)yy * (size_t)f->width + (size_t)xx];
                count++;
            }
            if (count) row[x] = (uint16_t)((sum + (unsigned)count / 2) / (unsigned)count);
        }
    }
}

/* The two green sites of a cell see the same light, so over the brighter half of the frame they track each other
 * more closely than red tracks blue. Greens on the anti-diagonal is BGGR (the OV50X50's own order); on the diagonal,
 * the same pattern a column over, GBRG. */
static int guess_order(const frame* f) {
    int bw = f->width / 16, bh = f->height / 16, bx, by, n = bw * bh, i;
    float* s[4];
    float* lum;
    double diagonal = 0.0, anti = 0.0;
    float median;
    if (n <= 0) return SPDF_SENSOR_ORDER_BGGR;
    for (i = 0; i < 4; ++i) s[i] = (float*)calloc((size_t)n, sizeof(float));
    lum = (float*)calloc((size_t)n, sizeof(float));
    if (!s[0] || !s[1] || !s[2] || !s[3] || !lum) {
        for (i = 0; i < 4; ++i) free(s[i]);
        free(lum);
        return SPDF_SENSOR_ORDER_BGGR;
    }
    for (by = 0; by < bh; ++by)
        for (bx = 0; bx < bw; ++bx) {
            int x, y, b = by * bw + bx;
            for (y = 0; y < 16; ++y) {
                const uint16_t* row = f->px + (size_t)(by * 16 + y) * (size_t)f->width + (size_t)bx * 16;
                for (x = 0; x < 16; ++x) s[(y & 1) * 2 + (x & 1)][b] += row[x];
            }
            lum[b] = s[0][b] + s[1][b] + s[2][b] + s[3][b];
        }
    {
        float* sorted = (float*)malloc((size_t)n * sizeof(float));
        if (sorted) {
            memcpy(sorted, lum, (size_t)n * sizeof(float));
            median = percentile(sorted, n, 50.0f);
            free(sorted);
        } else {
            median = 0.0f;
        }
    }
    for (i = 0; i < n; ++i) {
        if (lum[i] < median) continue;
        diagonal += fabs((double)s[0][i] - (double)s[3][i]);
        anti += fabs((double)s[1][i] - (double)s[2][i]);
    }
    for (i = 0; i < 4; ++i) free(s[i]);
    free(lum);
    return anti <= diagonal ? SPDF_SENSOR_ORDER_BGGR : SPDF_SENSOR_ORDER_GBRG;
}

/* Black level: OmniVision's 64 at 10 bits, scaled to the samples' depth, when the darkest pixels sit near it or
 * above; zero when they sit near zero (a frame saved with black already taken off). */
static float detect_black(const frame* f) {
    static uint32_t counts[65536];
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    size_t i, n = (size_t)f->width * (size_t)f->height, target, seen = 0;
    float low = 0.0f, nominal = 64.0f * f->unit;
    int v;
    pthread_mutex_lock(&lock);
    memset(counts, 0, sizeof(counts));
    for (i = 0; i < n; ++i) counts[f->px[i]]++;
    target = n / 200; /* 0.5% */
    for (v = 0; v < 65536; ++v) {
        seen += counts[v];
        if (seen > target) {
            low = (float)v;
            break;
        }
    }
    pthread_mutex_unlock(&lock);
    return low >= 0.5f * nominal ? nominal : 0.0f;
}
