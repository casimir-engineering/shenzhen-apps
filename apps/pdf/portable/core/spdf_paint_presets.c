/* New Canvas's sizes (spdf_paint.h, docs/plans/annotate.md § File > New Canvas): one table for the New Canvas sheet,
 * canvas.new's `preset` and `szpdf canvas new --preset`. Paper is in millimetres and becomes pixels at the canvas's
 * resolution; every other size is in pixels whatever the resolution. Each is as listed unless portrait or landscape
 * is asked for, which turns it so its long side is the height or the width. */
#include "spdf_paint.h"

#include <ctype.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#define PAPER 1
#define PIXELS 0

static const spdf_paint_canvas_preset k_presets[] = {
    {"default", "Default", "Default", "1000 square", 1000, 1000, PIXELS},
    {"a0", "A0", "Paper", "iso paper", 841, 1189, PAPER},
    {"a1", "A1", "Paper", "iso paper", 594, 841, PAPER},
    {"a2", "A2", "Paper", "iso paper", 420, 594, PAPER},
    {"a3", "A3", "Paper", "iso paper", 297, 420, PAPER},
    {"a4", "A4", "Paper", "iso paper", 210, 297, PAPER},
    {"a5", "A5", "Paper", "iso paper", 148, 210, PAPER},
    {"a6", "A6", "Paper", "iso paper postcard", 105, 148, PAPER},
    {"b4", "B4", "Paper", "iso paper", 250, 353, PAPER},
    {"b5", "B5", "Paper", "iso paper", 176, 250, PAPER},
    {"letter", "US Letter", "Paper", "us paper 8.5x11", 215.9, 279.4, PAPER},
    {"legal", "US Legal", "Paper", "us paper 8.5x14", 215.9, 355.6, PAPER},
    {"tabloid", "Tabloid / Ledger", "Paper", "us paper ledger 11x17", 279.4, 431.8, PAPER},
    {"half-letter", "Half Letter", "Paper", "us paper statement 5.5x8.5", 139.7, 215.9, PAPER},
    {"hd", "HD", "Screen", "720p video screen", 1280, 720, PIXELS},
    {"full-hd", "Full HD", "Screen", "1080p fhd hd video screen", 1920, 1080, PIXELS},
    {"qhd", "QHD", "Screen", "1440p 2k hd screen", 2560, 1440, PIXELS},
    {"4k", "4K UHD", "Screen", "2160p uhd video screen", 3840, 2160, PIXELS},
    {"5k", "5K", "Screen", "studio display imac screen", 5120, 2880, PIXELS},
    {"macbook-air", "MacBook Air 13\" wallpaper", "Screen", "mac retina wallpaper desktop", 2560, 1664, PIXELS},
    {"macbook-pro", "MacBook Pro 14\" wallpaper", "Screen", "mac retina wallpaper desktop", 3024, 1964, PIXELS},
    {"iphone", "iPhone 16 Pro", "Screen", "phone ios mobile wallpaper", 1206, 2622, PIXELS},
    {"iphone-max", "iPhone 16 Pro Max", "Screen", "phone ios mobile wallpaper", 1320, 2868, PIXELS},
    {"ipad", "iPad Pro 13\"", "Screen", "tablet ios wallpaper", 2064, 2752, PIXELS},
    {"ipad-air", "iPad Air 11\"", "Screen", "tablet ios wallpaper", 1640, 2360, PIXELS},
    {"instagram-square", "Instagram square", "Social", "post social", 1080, 1080, PIXELS},
    {"instagram-portrait", "Instagram portrait", "Social", "post social", 1080, 1350, PIXELS},
    {"story", "Story / Reel", "Social", "instagram tiktok reel story social vertical video", 1080, 1920, PIXELS},
    {"youtube-thumbnail", "YouTube thumbnail", "Social", "video social", 1280, 720, PIXELS},
    {"x-header", "X header", "Social", "twitter banner social", 1500, 500, PIXELS},
    {"icon-16", "Icon 16", "Icon", "icon favicon", 16, 16, PIXELS},
    {"icon-32", "Icon 32", "Icon", "icon favicon", 32, 32, PIXELS},
    {"icon-64", "Icon 64", "Icon", "icon", 64, 64, PIXELS},
    {"icon-128", "Icon 128", "Icon", "icon", 128, 128, PIXELS},
    {"icon-256", "Icon 256", "Icon", "icon", 256, 256, PIXELS},
    {"icon-512", "Icon 512", "Icon", "icon", 512, 512, PIXELS},
    {"app-icon", "App icon", "Icon", "icon ios macos 1024", 1024, 1024, PIXELS},
};

const spdf_paint_canvas_preset* spdf_paint_canvas_presets(size_t* count) {
    if (count) *count = sizeof(k_presets) / sizeof(k_presets[0]);
    return k_presets;
}

static int same_name(const char* a, const char* b) {
    for (; *a && *b; a++, b++) {
        char x = (char)tolower((unsigned char)*a), y = (char)tolower((unsigned char)*b);
        if (x == ' ' || x == '_') x = '-';
        if (y == ' ' || y == '_') y = '-';
        if (x != y) return 0;
    }
    return *a == *b;
}

const spdf_paint_canvas_preset* spdf_paint_canvas_preset_named(const char* name) {
    if (!name || !*name) return NULL;
    size_t count = 0;
    const spdf_paint_canvas_preset* presets = spdf_paint_canvas_presets(&count);
    for (size_t i = 0; i < count; i++)
        if (same_name(presets[i].name, name) || same_name(presets[i].label, name)) return &presets[i];
    return NULL;
}

void spdf_paint_canvas_preset_pixels(const spdf_paint_canvas_preset* preset, double ppi, int orientation, int* width,
                                     int* height) {
    double w = preset ? preset->width : SPDF_PAINT_DEFAULT_SIZE, h = preset ? preset->height : SPDF_PAINT_DEFAULT_SIZE;
    if (preset && preset->paper) {
        double scale = (ppi > 0 ? ppi : SPDF_PAINT_DEFAULT_PPI) / 25.4;
        w = round(w * scale);
        h = round(h * scale);
    }
    if ((orientation == SPDF_PAINT_LANDSCAPE && w < h) || (orientation == SPDF_PAINT_PORTRAIT && w > h)) {
        double t = w;
        w = h;
        h = t;
    }
    if (width) *width = (int)fmax(1, fmin(SPDF_PAINT_MAX_SIDE, w));
    if (height) *height = (int)fmax(1, fmin(SPDF_PAINT_MAX_SIDE, h));
}

const char* spdf_paint_canvas_preset_names(void) {
    static char names[1024];
    if (!names[0]) {
        size_t count = 0, used = 0;
        const spdf_paint_canvas_preset* presets = spdf_paint_canvas_presets(&count);
        for (size_t i = 0; i < count && used + strlen(presets[i].name) + 3 < sizeof(names); i++)
            used += (size_t)snprintf(names + used, sizeof(names) - used, "%s%s", i ? ", " : "", presets[i].name);
    }
    return names;
}
