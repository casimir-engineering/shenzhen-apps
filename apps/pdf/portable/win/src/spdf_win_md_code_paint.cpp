/* spdf_win_md_code_paint.cpp -- see spdf_win_md_code_paint.h. */
#include "spdf_win_md_code_paint.h"

#include "spdf_win_d2d.h" /* spdf_win_scene */
#include "spdf_win_md_code.h"

#include <dwrite.h>

#include <string.h>

#pragma comment(lib, "d2d1.lib")
#pragma comment(lib, "dwrite.lib")

namespace {

/* Light / dark, the code-surface roles of the Markdown palette
 * (spdf_markdown_support.c's $thead / $codestroke / $muted, which are
 * SPDFMarkdownTheme.mm's values). */
struct Colors {
    D2D1_COLOR_F fill;
    D2D1_COLOR_F stroke;
    D2D1_COLOR_F text;
};

Colors colors_for(int dark) {
    Colors c;
    if (dark) {
        c.fill = D2D1::ColorF(0x2A2A2A, 1.0f);
        c.stroke = D2D1::ColorF(0x363636, 1.0f);
        c.text = D2D1::ColorF(0x999999, 1.0f);
    } else {
        c.fill = D2D1::ColorF(0xEAEEF2, 1.0f);
        c.stroke = D2D1::ColorF(0xD0D7DE, 1.0f);
        c.text = D2D1::ColorF(0x59636E, 1.0f);
    }
    return c;
}

IDWriteFactory* g_dwrite;
IDWriteTextFormat* g_format;
float g_format_px;

/* Centred both ways, 11px medium. Our own format rather than the shared chrome
 * cache, because the alignment is part of it and that cache hands the same
 * object to every caller. */
IDWriteTextFormat* format_for(float size_px) {
    if (g_format && g_format_px == size_px) return g_format;
    if (!g_dwrite &&
        FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                                   reinterpret_cast<IUnknown**>(&g_dwrite))))
        return NULL; /* no text; the pills still draw, which is the graceful half */
    if (g_format) {
        g_format->Release();
        g_format = NULL;
    }
    if (FAILED(g_dwrite->CreateTextFormat(L"Segoe UI", NULL, DWRITE_FONT_WEIGHT_MEDIUM, DWRITE_FONT_STYLE_NORMAL,
                                          DWRITE_FONT_STRETCH_NORMAL, size_px, L"", &g_format)))
        return NULL;
    g_format->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
    g_format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    g_format_px = size_px;
    return g_format;
}

} // namespace

void spdf_win_md_code_paint_shutdown(void) {
    if (g_format) {
        g_format->Release();
        g_format = NULL;
    }
    if (g_dwrite) {
        g_dwrite->Release();
        g_dwrite = NULL;
    }
    g_format_px = 0.0f;
}

void spdf_win_md_code_paint(ID2D1RenderTarget* target, const struct spdf_win_scene* scene) {
    SpdfWinMdCodePill pills[64];
    ID2D1SolidColorBrush* brush = NULL;
    IDWriteTextFormat* format;
    Colors c;
    float s;
    int count, i;

    if (!target || !scene) return;
    count = spdf_win_md_code_pills(pills, 64);
    if (count <= 0) return;
    s = scene->dpi_scale > 0.0f ? scene->dpi_scale : 1.0f;
    c = colors_for(scene->dark);
    if (FAILED(target->CreateSolidColorBrush(c.fill, &brush)) || !brush) return;
    format = format_for(SPDF_WIN_MD_CODE_TITLE_PX * s);

    for (i = 0; i < count; ++i) {
        const SpdfWinMdCodePill* p = &pills[i];
        D2D1_ROUNDED_RECT round;
        if (!(p->w > 0.0f) || !(p->h > 0.0f)) continue;
        round.rect = D2D1::RectF(p->x, p->y, p->x + p->w, p->y + p->h);
        round.radiusX = round.radiusY = SPDF_WIN_MD_CODE_RADIUS * s;
        brush->SetColor(c.fill);
        target->FillRoundedRectangle(round, brush);
        /* Half a pixel in, so the stroke's centreline lands on the pill's edge
         * rather than straddling it. */
        round.rect = D2D1::RectF(p->x + 0.5f, p->y + 0.5f, p->x + p->w - 0.5f, p->y + p->h - 0.5f);
        brush->SetColor(c.stroke);
        target->DrawRoundedRectangle(round, brush, 1.0f * s);
        if (format && p->title) {
            brush->SetColor(c.text);
            target->DrawText(p->title, (UINT32)wcslen(p->title), format,
                             D2D1::RectF(p->x, p->y, p->x + p->w, p->y + p->h), brush,
                             D2D1_DRAW_TEXT_OPTIONS_CLIP);
        }
    }
    brush->Release();
}
