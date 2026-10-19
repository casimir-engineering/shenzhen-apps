/* Toolchain smoke test for the Windows port.
 *
 * This is NOT an application: it exists only to prove that the cross-machine
 * build chain (macOS -> Parallels guest -> MSVC ARM64 -> run) produces the
 * same bytes as a native macOS build. portable/core/spdf_recolor.c is the
 * ideal subject because it is pure C99 with no MuPDF, no platform headers and
 * no floating point -- every value below is fixed by integer arithmetic, so
 * ANY difference between the two outputs is a real toolchain problem rather
 * than acceptable numerical drift.
 *
 * Keep the output free of pointers, addresses, sizeof and time: those legitimately
 * differ between the two targets and would make the diff useless.
 */
#include "spdf_recolor.h"

#include <stdio.h>

static const char* mode_name(spdf_recolor_mode mode) {
    switch (mode) {
        case SPDF_RECOLOR_NONE: return "NONE";
        case SPDF_RECOLOR_LUMA_REMAP: return "LUMA_REMAP";
        case SPDF_RECOLOR_TINT: return "TINT";
        case SPDF_RECOLOR_INVERT: return "INVERT";
        default: return "?";
    }
}

/* A deliberately awkward spread: the two theme endpoints, the primaries (whose
 * chroma LUMA_REMAP must preserve), mid grey, and two off-axis colors. */
static const unsigned char kPixels[][4] = {
    {255, 255, 255, 255}, /* paper white  */
    {  0,   0,   0, 255}, /* body black   */
    {128, 128, 128, 255}, /* mid grey     */
    {255,   0,   0, 255}, /* red          */
    {  0, 255,   0, 255}, /* green        */
    {  0,   0, 255, 255}, /* blue         */
    {200,  60,  30, 128}, /* warm, alpha must survive */
    { 30,  90, 200,  17}, /* cool, alpha must survive */
};
#define PIXEL_COUNT ((int)(sizeof(kPixels) / sizeof(kPixels[0])))

static void run_mode(spdf_recolor_mode mode) {
    spdf_recolor_table table;
    unsigned char buf[PIXEL_COUNT][4];
    int i;

    spdf_recolor_table_init(&table, mode, spdf_recolor_default_dark_theme());

    printf("mode=%s kind=%d ink=[%d %d %d] span=[%d %d %d]\n", mode_name(mode), table.kind, table.ink[0],
           table.ink[1], table.ink[2], table.span[0], table.span[1], table.span[2]);
    /* Table probes at the endpoints and midpoint; for LUMA_REMAP these stay 0,
     * which is itself worth asserting across compilers. */
    printf("  lut r[0]=%d r[128]=%d r[255]=%d g[0]=%d g[128]=%d g[255]=%d b[0]=%d b[128]=%d b[255]=%d\n",
           table.r[0], table.r[128], table.r[255], table.g[0], table.g[128], table.g[255], table.b[0],
           table.b[128], table.b[255]);

    for (i = 0; i < PIXEL_COUNT; ++i) {
        buf[i][0] = kPixels[i][0];
        buf[i][1] = kPixels[i][1];
        buf[i][2] = kPixels[i][2];
        buf[i][3] = kPixels[i][3];
    }

    /* One row, tightly packed: width = PIXEL_COUNT, stride = width * 4. */
    spdf_recolor_rgba(&buf[0][0], PIXEL_COUNT, 1, PIXEL_COUNT * 4, &table);

    for (i = 0; i < PIXEL_COUNT; ++i) {
        printf("  in=(%3d,%3d,%3d,%3d) out=(%3d,%3d,%3d,%3d)\n", kPixels[i][0], kPixels[i][1], kPixels[i][2],
               kPixels[i][3], buf[i][0], buf[i][1], buf[i][2], buf[i][3]);
    }
}

/* Exercises the exclusion walker: pixels inside the rectangle must come back
 * byte identical, which is the property the whole image-preserving path rests on. */
static void run_exclusions(void) {
    spdf_recolor_table table;
    spdf_recolor_irect keep;
    unsigned char buf[8][4];
    int i;

    spdf_recolor_table_init(&table, SPDF_RECOLOR_LUMA_REMAP, spdf_recolor_default_dark_theme());
    for (i = 0; i < 8; ++i) {
        buf[i][0] = (unsigned char)(i * 32);
        buf[i][1] = (unsigned char)(255 - i * 32);
        buf[i][2] = (unsigned char)(i * 16 + 8);
        buf[i][3] = 255;
    }
    keep.x0 = 2;
    keep.y0 = 0;
    keep.x1 = 5;
    keep.y1 = 1;
    spdf_recolor_rgba_excluding(&buf[0][0], 8, 1, 32, &table, &keep, 1);

    printf("exclusions x=[2,5)\n");
    for (i = 0; i < 8; ++i) {
        printf("  x=%d in=(%3d,%3d,%3d) out=(%3d,%3d,%3d)%s\n", i, i * 32, 255 - i * 32, i * 16 + 8, buf[i][0],
               buf[i][1], buf[i][2], (i >= 2 && i < 5) ? " [kept]" : "");
    }
}

static void run_paths(void) {
    static const char* kPaths[] = {"a.cbz", "A.CBR", "photo.JPG", "book.pdf", "notes.epub", "noext", "x.Png"};
    int i;
    printf("path_is_picture\n");
    for (i = 0; i < (int)(sizeof(kPaths) / sizeof(kPaths[0])); ++i) {
        printf("  %-12s -> %d\n", kPaths[i], spdf_recolor_path_is_picture(kPaths[i]));
    }
    printf("  (null)       -> %d\n", spdf_recolor_path_is_picture(0));
}

int main(void) {
    spdf_recolor_theme theme = spdf_recolor_default_dark_theme();
    printf("spdf recolor smoke test\n");
    printf("theme paper=0x%06X ink=0x%06X\n", theme.paper_rgb, theme.ink_rgb);
    run_mode(SPDF_RECOLOR_LUMA_REMAP);
    run_mode(SPDF_RECOLOR_TINT);
    run_mode(SPDF_RECOLOR_INVERT);
    run_mode(SPDF_RECOLOR_NONE);
    run_exclusions();
    run_paths();
    printf("ok\n");
    return 0;
}
