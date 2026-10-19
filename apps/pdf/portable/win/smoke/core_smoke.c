/* core_smoke -- the proof that libmupdf links and renders identically on both hosts.
 *
 *   core_smoke <pdf> [page] [zoom] [out.rgba]
 *
 * Opens a real PDF through portable/core/shenzhen_pdf_core.h, prints the page
 * count and page geometry, renders one page to RGBA, and prints a digest of the
 * pixels. Build and run it on macOS (clang/arm64) and in the Windows guest
 * (MSVC/ARM64) against the same file and diff the two outputs: everything it
 * prints is either an integer or a fixed-precision decimal, so any difference is
 * a real difference, not formatting drift.
 *
 * Why a digest AND an optional raw dump: the digest makes "same or not" a
 * one-line answer, and the dump makes "how different" answerable with cmp(1)
 * when the answer is "not". The guest can write the dump straight onto the
 * Parallels share, so it lands on the Mac with no copy step.
 *
 * The pixel digest deliberately walks width*4 bytes per row rather than the
 * whole stride. Stride padding is an allocator detail that is allowed to differ
 * between the two toolchains; the printed `stride=` field reports it separately
 * so a difference there is visible rather than smuggled into the digest.
 *
 * Owned by track T0 (portable/win/smoke). Nothing else may edit it.
 */

#include "shenzhen_pdf_core.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* FNV-1a, 64-bit. Chosen over anything cryptographic because it is ten lines
 * with no endianness or word-size ambiguity, which is the whole point when the
 * output has to match across two compilers. */
static unsigned long long fnv1a(const unsigned char* data, size_t len, unsigned long long h)
{
    size_t i;
    for (i = 0; i < len; i++) {
        h ^= (unsigned long long)data[i];
        h *= 1099511628211ULL;
    }
    return h;
}

static int fail(const char* what, const char* err)
{
    fprintf(stderr, "core_smoke: %s: %s\n", what, err && *err ? err : "(no detail)");
    return 1;
}

int main(int argc, char** argv)
{
    const char* path;
    int page = 0;
    float zoom = 1.0f;
    const char* out_path = NULL;
    char err[512];
    spdf_document* doc;
    spdf_bitmap bmp;
    float w = 0.0f, h = 0.0f;
    int pages, y, i;
    unsigned long long digest = 14695981039346656037ULL;
    size_t row_bytes;

    if (argc < 2) {
        fprintf(stderr, "usage: core_smoke <pdf> [page] [zoom] [out.rgba]\n");
        return 64;
    }
    path = argv[1];
    if (argc > 2)
        page = atoi(argv[2]);
    if (argc > 3)
        zoom = (float)atof(argv[3]);
    if (argc > 4)
        out_path = argv[4];

    err[0] = '\0';
    doc = spdf_open(path, err, sizeof err);
    if (!doc)
        return fail("open", err);

    pages = spdf_page_count(doc);
    printf("pages=%d\n", pages);

    err[0] = '\0';
    if (!spdf_page_size(doc, page, &w, &h, err, sizeof err)) {
        spdf_close(doc);
        return fail("page_size", err);
    }
    printf("page=%d size=%.4f x %.4f\n", page, (double)w, (double)h);

    memset(&bmp, 0, sizeof bmp);
    err[0] = '\0';
    if (!spdf_render_page_rgba_opts(doc, page, zoom, SPDF_RENDER_DEFAULT, NULL, &bmp, err, sizeof err)) {
        spdf_close(doc);
        return fail("render", err);
    }
    printf("render zoom=%.4f -> %dx%d stride=%d\n", (double)zoom, bmp.width, bmp.height, bmp.stride);

    row_bytes = (size_t)bmp.width * 4u;
    for (y = 0; y < bmp.height; y++)
        digest = fnv1a(bmp.rgba + (size_t)y * (size_t)bmp.stride, row_bytes, digest);
    printf("rgba fnv1a=%016llx bytes=%llu\n", digest, (unsigned long long)(row_bytes * (size_t)bmp.height));

    /* Nine fixed sample points, so a human reading two diffed logs can see
     * *where* they diverge without reaching for the raw dump. */
    for (i = 0; i < 9; i++) {
        int sx = (bmp.width - 1) * (i % 3) / 2;
        int sy = (bmp.height - 1) * (i / 3) / 2;
        const unsigned char* p = bmp.rgba + (size_t)sy * (size_t)bmp.stride + (size_t)sx * 4u;
        printf("px(%d,%d)=(%3u,%3u,%3u,%3u)\n", sx, sy, p[0], p[1], p[2], p[3]);
    }

    if (out_path) {
        FILE* f = fopen(out_path, "wb");
        if (!f) {
            spdf_free_bitmap(&bmp);
            spdf_close(doc);
            return fail("fopen(out)", out_path);
        }
        for (y = 0; y < bmp.height; y++) {
            if (fwrite(bmp.rgba + (size_t)y * (size_t)bmp.stride, 1, row_bytes, f) != row_bytes) {
                fclose(f);
                spdf_free_bitmap(&bmp);
                spdf_close(doc);
                return fail("fwrite(out)", out_path);
            }
        }
        fclose(f);
        fprintf(stderr, "core_smoke: wrote %s\n", out_path);
    }

    spdf_free_bitmap(&bmp);
    spdf_close(doc);
    printf("ok\n");
    return 0;
}
