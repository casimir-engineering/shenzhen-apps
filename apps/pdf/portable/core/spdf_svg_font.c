/* spdf_svg_font.c -- see spdf_svg_font.h. */
#include "spdf_svg_font.h"

#include <stdlib.h>
#include <string.h>

typedef struct {
    unsigned char* data;
    size_t len;
    size_t cap;
} spdf_sfnt_buf;

static void spdf_sfnt_reserve(fz_context* ctx, spdf_sfnt_buf* b, size_t more) {
    if (b->len + more <= b->cap) return;
    while (b->len + more > b->cap) b->cap = b->cap ? b->cap * 2 : 4096;
    b->data = (unsigned char*)fz_realloc(ctx, b->data, b->cap);
}

static void spdf_sfnt_u8(fz_context* ctx, spdf_sfnt_buf* b, unsigned v) {
    spdf_sfnt_reserve(ctx, b, 1);
    b->data[b->len++] = (unsigned char)v;
}

static void spdf_sfnt_u16(fz_context* ctx, spdf_sfnt_buf* b, unsigned v) {
    spdf_sfnt_u8(ctx, b, (v >> 8) & 0xff);
    spdf_sfnt_u8(ctx, b, v & 0xff);
}

static void spdf_sfnt_u32(fz_context* ctx, spdf_sfnt_buf* b, unsigned long v) {
    spdf_sfnt_u16(ctx, b, (unsigned)((v >> 16) & 0xffff));
    spdf_sfnt_u16(ctx, b, (unsigned)(v & 0xffff));
}

static void spdf_sfnt_bytes(fz_context* ctx, spdf_sfnt_buf* b, const void* data, size_t len) {
    spdf_sfnt_reserve(ctx, b, len);
    memcpy(b->data + b->len, data, len);
    b->len += len;
}

static void spdf_sfnt_pad(fz_context* ctx, spdf_sfnt_buf* b) {
    while (b->len & 3) spdf_sfnt_u8(ctx, b, 0);
}

static unsigned long spdf_sfnt_checksum(const unsigned char* p, size_t len) {
    unsigned long sum = 0;
    size_t i;
    for (i = 0; i < len; i += 4) {
        unsigned long v = 0;
        int k;
        for (k = 0; k < 4; k++) v = (v << 8) | (i + k < len ? p[i + k] : 0);
        sum = (sum + v) & 0xffffffffUL;
    }
    return sum;
}

typedef struct {
    unsigned code;
    unsigned gid;
} spdf_sfnt_map;

static int spdf_sfnt_map_cmp(const void* a, const void* b) {
    const spdf_sfnt_map* x = (const spdf_sfnt_map*)a;
    const spdf_sfnt_map* y = (const spdf_sfnt_map*)b;
    if (x->code != y->code) return x->code < y->code ? -1 : 1;
    return x->gid < y->gid ? -1 : x->gid > y->gid;
}

/* A format 4 cmap (Windows, Unicode BMP) of `map` (sorted by code, one glyph per code): one segment per run of
 * codes whose glyph ids run alongside them. */
static void spdf_sfnt_cmap(fz_context* ctx, spdf_sfnt_buf* b, const spdf_sfnt_map* map, int count) {
    int segs = 0, i, j, s;
    unsigned* start;
    unsigned* end;
    int* delta;
    unsigned seg2, search = 2, selector = 0;
    start = fz_malloc_array(ctx, count + 1, unsigned);
    end = fz_malloc_array(ctx, count + 1, unsigned);
    delta = fz_malloc_array(ctx, count + 1, int);
    for (i = 0; i < count; i = j) {
        for (j = i + 1; j < count && map[j].code == map[j - 1].code + 1 && map[j].gid == map[j - 1].gid + 1; j++) {
        }
        start[segs] = map[i].code;
        end[segs] = map[j - 1].code;
        delta[segs] = (int)map[i].gid - (int)map[i].code;
        segs++;
    }
    start[segs] = end[segs] = 0xffff;
    delta[segs] = 1;
    segs++;
    seg2 = (unsigned)segs * 2;
    while (search * 2 <= seg2) {
        search *= 2;
        selector++;
    }
    spdf_sfnt_u16(ctx, b, 0); /* version */
    spdf_sfnt_u16(ctx, b, 1); /* one subtable */
    spdf_sfnt_u16(ctx, b, 3);
    spdf_sfnt_u16(ctx, b, 1);
    spdf_sfnt_u32(ctx, b, 12);
    spdf_sfnt_u16(ctx, b, 4);
    spdf_sfnt_u16(ctx, b, 16 + 8 * (unsigned)segs);
    spdf_sfnt_u16(ctx, b, 0);
    spdf_sfnt_u16(ctx, b, seg2);
    spdf_sfnt_u16(ctx, b, search);
    spdf_sfnt_u16(ctx, b, selector);
    spdf_sfnt_u16(ctx, b, seg2 - search);
    for (s = 0; s < segs; s++) spdf_sfnt_u16(ctx, b, end[s]);
    spdf_sfnt_u16(ctx, b, 0);
    for (s = 0; s < segs; s++) spdf_sfnt_u16(ctx, b, start[s]);
    for (s = 0; s < segs; s++) spdf_sfnt_u16(ctx, b, (unsigned)delta[s] & 0xffff);
    for (s = 0; s < segs; s++) spdf_sfnt_u16(ctx, b, 0);
    fz_free(ctx, start);
    fz_free(ctx, end);
    fz_free(ctx, delta);
}

static void spdf_sfnt_name_record(fz_context* ctx, spdf_sfnt_buf* records, spdf_sfnt_buf* strings, unsigned id,
                                  const char* text) {
    size_t at = strings->len;
    const char* p;
    for (p = text; *p; p++) spdf_sfnt_u16(ctx, strings, (unsigned char)*p);
    spdf_sfnt_u16(ctx, records, 3);
    spdf_sfnt_u16(ctx, records, 1);
    spdf_sfnt_u16(ctx, records, 0x409);
    spdf_sfnt_u16(ctx, records, id);
    spdf_sfnt_u16(ctx, records, (unsigned)(strings->len - at));
    spdf_sfnt_u16(ctx, records, (unsigned)at);
}

/* The OpenType font around `cff`, whose glyph `g` has Unicode `unicode[g]` (0: none) and an advance of
 * `advance[g]` thousandths of an em. */
static fz_buffer* spdf_sfnt_from_cff(fz_context* ctx, const unsigned char* cff, size_t cff_len, int glyphs,
                                     const unsigned* unicode, const int* advance, const char* name, fz_rect bbox,
                                     float ascender, float descender, int bold, int italic, int mono) {
    enum { CFF, OS2, CMAP, HEAD, HHEA, HMTX, MAXP, NAME, POST, TABLES };
    static const char tags[TABLES][5] = {"CFF ", "OS/2", "cmap", "head", "hhea", "hmtx", "maxp", "name", "post"};
    spdf_sfnt_buf t[TABLES];
    spdf_sfnt_buf out = {0};
    spdf_sfnt_map* map = NULL;
    spdf_sfnt_buf records = {0}, strings = {0};
    fz_buffer* result = NULL;
    int count = 0, g, i, max_advance = 0, min_lsb = 0;
    int asc = (int)(ascender * 1000), desc = (int)(descender * 1000);
    int x0 = (int)(bbox.x0 * 1000), y0 = (int)(bbox.y0 * 1000), x1 = (int)(bbox.x1 * 1000), y1 = (int)(bbox.y1 * 1000);
    unsigned long head_at = 0;
    char clean[64];
    size_t n = 0;
    memset(t, 0, sizeof t);
    fz_var(map);
    fz_var(result);

    for (i = 0; name && name[i] && n + 1 < sizeof clean; i++)
        if (name[i] > 32 && name[i] < 127 && !strchr("[](){}<>/%", name[i])) clean[n++] = name[i];
    if (!n) clean[n++] = 'F';
    clean[n] = 0;

    fz_try(ctx) {
        spdf_sfnt_bytes(ctx, &t[CFF], cff, cff_len);

        map = fz_malloc_array(ctx, glyphs ? glyphs : 1, spdf_sfnt_map);
        for (g = 0; g < glyphs; g++)
            if (unicode[g] > 0 && unicode[g] < 0xffff) {
                map[count].code = unicode[g];
                map[count].gid = (unsigned)g;
                count++;
            }
        qsort(map, (size_t)count, sizeof *map, spdf_sfnt_map_cmp);
        for (i = 0, g = 0; i < count; i++) /* keep the lowest glyph for each code */
            if (!g || map[g - 1].code != map[i].code) map[g++] = map[i];
        count = g;
        spdf_sfnt_cmap(ctx, &t[CMAP], map, count);

        for (g = 0; g < glyphs; g++) {
            spdf_sfnt_u16(ctx, &t[HMTX], (unsigned)advance[g]);
            spdf_sfnt_u16(ctx, &t[HMTX], 0);
            if (advance[g] > max_advance) max_advance = advance[g];
        }

        spdf_sfnt_u32(ctx, &t[HEAD], 0x00010000UL); /* version */
        spdf_sfnt_u32(ctx, &t[HEAD], 0x00010000UL); /* fontRevision */
        spdf_sfnt_u32(ctx, &t[HEAD], 0);            /* checkSumAdjustment, set below */
        spdf_sfnt_u32(ctx, &t[HEAD], 0x5F0F3CF5UL);
        spdf_sfnt_u16(ctx, &t[HEAD], 3);    /* flags */
        spdf_sfnt_u16(ctx, &t[HEAD], 1000); /* unitsPerEm */
        for (i = 0; i < 4; i++) spdf_sfnt_u32(ctx, &t[HEAD], 0); /* created, modified */
        spdf_sfnt_u16(ctx, &t[HEAD], (unsigned)x0 & 0xffff);
        spdf_sfnt_u16(ctx, &t[HEAD], (unsigned)y0 & 0xffff);
        spdf_sfnt_u16(ctx, &t[HEAD], (unsigned)x1 & 0xffff);
        spdf_sfnt_u16(ctx, &t[HEAD], (unsigned)y1 & 0xffff);
        spdf_sfnt_u16(ctx, &t[HEAD], (bold ? 1 : 0) | (italic ? 2 : 0)); /* macStyle */
        spdf_sfnt_u16(ctx, &t[HEAD], 8);                                 /* lowestRecPPEM */
        spdf_sfnt_u16(ctx, &t[HEAD], 2);                                 /* fontDirectionHint */
        spdf_sfnt_u16(ctx, &t[HEAD], 0);                                 /* indexToLocFormat */
        spdf_sfnt_u16(ctx, &t[HEAD], 0);                                 /* glyphDataFormat */

        spdf_sfnt_u32(ctx, &t[HHEA], 0x00010000UL);
        spdf_sfnt_u16(ctx, &t[HHEA], (unsigned)asc & 0xffff);
        spdf_sfnt_u16(ctx, &t[HHEA], (unsigned)desc & 0xffff);
        spdf_sfnt_u16(ctx, &t[HHEA], 0); /* lineGap */
        spdf_sfnt_u16(ctx, &t[HHEA], (unsigned)max_advance);
        spdf_sfnt_u16(ctx, &t[HHEA], (unsigned)min_lsb & 0xffff);
        spdf_sfnt_u16(ctx, &t[HHEA], 0); /* minRightSideBearing */
        spdf_sfnt_u16(ctx, &t[HHEA], (unsigned)x1 & 0xffff);
        spdf_sfnt_u16(ctx, &t[HHEA], 1); /* caretSlopeRise */
        for (i = 0; i < 6; i++) spdf_sfnt_u16(ctx, &t[HHEA], 0); /* caretSlopeRun, caretOffset, reserved */
        spdf_sfnt_u16(ctx, &t[HHEA], 0); /* metricDataFormat */
        spdf_sfnt_u16(ctx, &t[HHEA], (unsigned)glyphs);

        spdf_sfnt_u32(ctx, &t[MAXP], 0x00005000UL); /* version 0.5: CFF outlines */
        spdf_sfnt_u16(ctx, &t[MAXP], (unsigned)glyphs);

        spdf_sfnt_u16(ctx, &t[OS2], 3); /* version */
        spdf_sfnt_u16(ctx, &t[OS2], (unsigned)(glyphs ? max_advance / 2 : 0));
        spdf_sfnt_u16(ctx, &t[OS2], bold ? 700 : 400);
        spdf_sfnt_u16(ctx, &t[OS2], 5);   /* usWidthClass: medium */
        spdf_sfnt_u16(ctx, &t[OS2], 0);   /* fsType: installable */
        for (i = 0; i < 10; i++) spdf_sfnt_u16(ctx, &t[OS2], 0); /* sub/superscript, strikeout */
        spdf_sfnt_u16(ctx, &t[OS2], 0);   /* sFamilyClass */
        for (i = 0; i < 10; i++) spdf_sfnt_u8(ctx, &t[OS2], 0); /* panose */
        spdf_sfnt_u32(ctx, &t[OS2], 1);   /* ulUnicodeRange1: Basic Latin */
        for (i = 0; i < 3; i++) spdf_sfnt_u32(ctx, &t[OS2], 0);
        spdf_sfnt_bytes(ctx, &t[OS2], "SZPD", 4);
        spdf_sfnt_u16(ctx, &t[OS2], (italic ? 1 : 0) | (bold ? 0x20 : 0) | (!bold && !italic ? 0x40 : 0));
        spdf_sfnt_u16(ctx, &t[OS2], count ? map[0].code : 0);
        spdf_sfnt_u16(ctx, &t[OS2], count ? map[count - 1].code : 0);
        spdf_sfnt_u16(ctx, &t[OS2], (unsigned)asc & 0xffff);
        spdf_sfnt_u16(ctx, &t[OS2], (unsigned)desc & 0xffff);
        spdf_sfnt_u16(ctx, &t[OS2], 0);                         /* sTypoLineGap */
        spdf_sfnt_u16(ctx, &t[OS2], (unsigned)(y1 > 0 ? y1 : asc));    /* usWinAscent */
        spdf_sfnt_u16(ctx, &t[OS2], (unsigned)(y0 < 0 ? -y0 : -desc)); /* usWinDescent */
        spdf_sfnt_u32(ctx, &t[OS2], 1); /* ulCodePageRange1: Latin 1 */
        spdf_sfnt_u32(ctx, &t[OS2], 0);
        for (i = 0; i < 5; i++) spdf_sfnt_u16(ctx, &t[OS2], 0); /* sxHeight .. usMaxContext */

        spdf_sfnt_name_record(ctx, &records, &strings, 1, clean);
        spdf_sfnt_name_record(ctx, &records, &strings, 2,
                              bold && italic ? "Bold Italic" : bold ? "Bold" : italic ? "Italic" : "Regular");
        spdf_sfnt_name_record(ctx, &records, &strings, 4, clean);
        spdf_sfnt_name_record(ctx, &records, &strings, 6, clean);
        spdf_sfnt_u16(ctx, &t[NAME], 0);
        spdf_sfnt_u16(ctx, &t[NAME], 4);
        spdf_sfnt_u16(ctx, &t[NAME], (unsigned)(6 + records.len));
        spdf_sfnt_bytes(ctx, &t[NAME], records.data, records.len);
        spdf_sfnt_bytes(ctx, &t[NAME], strings.data, strings.len);

        spdf_sfnt_u32(ctx, &t[POST], 0x00030000UL); /* version 3: no glyph names */
        spdf_sfnt_u32(ctx, &t[POST], italic ? 0xFFF40000UL : 0); /* italicAngle */
        spdf_sfnt_u16(ctx, &t[POST], (unsigned)-100 & 0xffff);   /* underlinePosition */
        spdf_sfnt_u16(ctx, &t[POST], 50);                        /* underlineThickness */
        spdf_sfnt_u32(ctx, &t[POST], mono ? 1 : 0);
        for (i = 0; i < 4; i++) spdf_sfnt_u32(ctx, &t[POST], 0);

        {
            unsigned search = 1, selector = 0;
            unsigned long offset = 12 + 16 * TABLES;
            while (search * 2 <= TABLES) {
                search *= 2;
                selector++;
            }
            spdf_sfnt_bytes(ctx, &out, "OTTO", 4);
            spdf_sfnt_u16(ctx, &out, TABLES);
            spdf_sfnt_u16(ctx, &out, search * 16);
            spdf_sfnt_u16(ctx, &out, selector);
            spdf_sfnt_u16(ctx, &out, TABLES * 16 - search * 16);
            for (i = 0; i < TABLES; i++) {
                spdf_sfnt_bytes(ctx, &out, tags[i], 4);
                spdf_sfnt_u32(ctx, &out, spdf_sfnt_checksum(t[i].data, t[i].len));
                spdf_sfnt_u32(ctx, &out, offset);
                spdf_sfnt_u32(ctx, &out, (unsigned long)t[i].len);
                if (i == HEAD) head_at = offset;
                offset += (t[i].len + 3) & ~(size_t)3;
            }
            for (i = 0; i < TABLES; i++) {
                spdf_sfnt_bytes(ctx, &out, t[i].data, t[i].len);
                spdf_sfnt_pad(ctx, &out);
            }
            {
                unsigned long adjust = (0xB1B0AFBAUL - spdf_sfnt_checksum(out.data, out.len)) & 0xffffffffUL;
                out.data[head_at + 8] = (unsigned char)(adjust >> 24);
                out.data[head_at + 9] = (unsigned char)(adjust >> 16);
                out.data[head_at + 10] = (unsigned char)(adjust >> 8);
                out.data[head_at + 11] = (unsigned char)adjust;
            }
        }
        result = fz_new_buffer_from_copied_data(ctx, out.data, out.len);
    }
    fz_always(ctx) {
        for (i = 0; i < TABLES; i++) fz_free(ctx, t[i].data);
        fz_free(ctx, out.data);
        fz_free(ctx, records.data);
        fz_free(ctx, strings.data);
        fz_free(ctx, map);
    }
    fz_catch(ctx) fz_rethrow(ctx);
    return result;
}

/* Wraps the bare CFF font program of the Type0 font `font` in OpenType, as the note above says. A font that is not a
 * Type0 font over a bare CFF program with a ToUnicode map is left as it is. */
static void spdf_svg_font_to_opentype(fz_context* ctx, pdf_document* doc, pdf_obj* font) {
    pdf_obj* descendant;
    pdf_obj* descriptor;
    pdf_obj* file;
    pdf_obj* to_unicode;
    fz_buffer* cff = NULL;
    fz_buffer* otf = NULL;
    fz_font* face = NULL;
    pdf_cmap* cmap = NULL;
    unsigned* unicode = NULL;
    int* advance = NULL;

    if (!pdf_name_eq(ctx, pdf_dict_get(ctx, font, PDF_NAME(Subtype)), PDF_NAME(Type0))) return;
    if (!pdf_name_eq(ctx, pdf_dict_get(ctx, font, PDF_NAME(Encoding)), PDF_NAME(Identity_H))) return;
    to_unicode = pdf_dict_get(ctx, font, PDF_NAME(ToUnicode));
    descendant = pdf_array_get(ctx, pdf_dict_get(ctx, font, PDF_NAME(DescendantFonts)), 0);
    descriptor = pdf_dict_get(ctx, descendant, PDF_NAME(FontDescriptor));
    file = pdf_dict_get(ctx, descriptor, PDF_NAME(FontFile3));
    if (!pdf_is_stream(ctx, to_unicode) || !pdf_is_stream(ctx, file) ||
        !pdf_name_eq(ctx, pdf_dict_get(ctx, file, PDF_NAME(Subtype)), PDF_NAME(CIDFontType0C)))
        return;

    fz_var(cff);
    fz_var(otf);
    fz_var(face);
    fz_var(cmap);
    fz_var(unicode);
    fz_var(advance);
    fz_try(ctx) {
        unsigned char* data;
        size_t len;
        int glyphs, g;
        cff = pdf_load_stream(ctx, file);
        face = fz_new_font_from_buffer(ctx, NULL, cff, 0, 0);
        glyphs = face->glyph_count;
        if (glyphs <= 0 || glyphs > 65535) fz_throw(ctx, FZ_ERROR_FORMAT, "font without glyphs");
        cmap = pdf_load_embedded_cmap(ctx, doc, to_unicode);
        unicode = fz_malloc_array(ctx, glyphs, unsigned);
        advance = fz_malloc_array(ctx, glyphs, int);
        for (g = 0; g < glyphs; g++) {
            int ucs[256];
            int n = pdf_lookup_cmap_full(cmap, (unsigned)g, ucs);
            unicode[g] = n == 1 && ucs[0] > 0 ? (unsigned)ucs[0] : 0;
            advance[g] = (int)(fz_advance_glyph(ctx, face, g, 0) * 1000 + 0.5f);
            if (advance[g] < 0) advance[g] = 0;
            if (advance[g] > 0xffff) advance[g] = 0xffff;
        }
        len = fz_buffer_storage(ctx, cff, &data);
        otf = spdf_sfnt_from_cff(ctx, data, len, glyphs, unicode, advance,
                                 pdf_to_name(ctx, pdf_dict_get(ctx, descendant, PDF_NAME(BaseFont))),
                                 fz_font_bbox(ctx, face), fz_font_ascender(ctx, face),
                                 fz_font_descender(ctx, face), fz_font_is_bold(ctx, face),
                                 fz_font_is_italic(ctx, face), fz_font_is_monospaced(ctx, face));
        pdf_update_stream(ctx, doc, file, otf, 0);
        pdf_dict_put(ctx, file, PDF_NAME(Subtype), PDF_NAME(OpenType));
        pdf_dict_del(ctx, file, PDF_NAME(Length1));
    }
    fz_always(ctx) {
        fz_free(ctx, advance);
        fz_free(ctx, unicode);
        pdf_drop_cmap(ctx, cmap);
        fz_drop_font(ctx, face);
        fz_drop_buffer(ctx, otf);
        fz_drop_buffer(ctx, cff);
    }
    fz_catch(ctx) {
        /* The font stays as MuPDF wrote it: it draws, only its text does not survive Quartz. */
        fz_report_error(ctx);
    }
}

void spdf_svg_fonts_to_opentype(fz_context* ctx, pdf_document* doc) {
    int i, n = pdf_xref_len(ctx, doc);
    for (i = 1; i < n; i++) {
        pdf_obj* obj = NULL;
        fz_var(obj);
        fz_try(ctx) {
            obj = pdf_load_object(ctx, doc, i);
            if (pdf_name_eq(ctx, pdf_dict_get(ctx, obj, PDF_NAME(Type)), PDF_NAME(Font)))
                spdf_svg_font_to_opentype(ctx, doc, obj);
        }
        fz_always(ctx) pdf_drop_obj(ctx, obj);
        fz_catch(ctx) fz_report_error(ctx); /* a free or broken object: nothing to wrap */
    }
}
