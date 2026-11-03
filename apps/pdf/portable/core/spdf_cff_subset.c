/* spdf_cff_subset.c -- see spdf_cff_subset.h. Table layouts: Adobe Technical Notes 5176 (CFF) and 5177 (Type 2
 * charstrings). */
#include "spdf_cff_subset.h"

#include <stdint.h>
#include <string.h>

static unsigned spdf_get16(const unsigned char* p) {
    return (unsigned)p[0] << 8 | p[1];
}

static uint32_t spdf_get32(const unsigned char* p) {
    return (uint32_t)spdf_get16(p) << 16 | spdf_get16(p + 2);
}

#define SPDF_CFF_BAD(ctx, what) fz_throw(ctx, FZ_ERROR_FORMAT, "CFF subset: %s", what)

typedef struct {
    unsigned count, offsize;
    size_t offsets, data, end; /* the offset array; the byte before the first item; just past the INDEX */
} spdf_cff_index;

static size_t spdf_cff_offset(const unsigned char* p, const spdf_cff_index* x, unsigned i) {
    const unsigned char* o = p + x->offsets + (size_t)i * x->offsize;
    size_t v = 0;
    unsigned k;
    for (k = 0; k < x->offsize; k++) v = v << 8 | o[k];
    return v;
}

static void spdf_cff_read_index(fz_context* ctx, const unsigned char* p, size_t len, size_t at, spdf_cff_index* x) {
    if (at + 2 > len) SPDF_CFF_BAD(ctx, "INDEX out of range");
    x->count = spdf_get16(p + at);
    x->offsize = 1;
    x->offsets = x->data = x->end = at + 2;
    if (x->count == 0) return;
    if (at + 3 > len || p[at + 2] < 1 || p[at + 2] > 4) SPDF_CFF_BAD(ctx, "bad INDEX");
    x->offsize = p[at + 2];
    x->offsets = at + 3;
    if (x->offsets + ((size_t)x->count + 1) * x->offsize > len) SPDF_CFF_BAD(ctx, "INDEX out of range");
    x->data = x->offsets + ((size_t)x->count + 1) * x->offsize - 1;
    if (spdf_cff_offset(p, x, 0) != 1) SPDF_CFF_BAD(ctx, "bad INDEX");
    x->end = x->data + spdf_cff_offset(p, x, x->count);
    if (x->end > len) SPDF_CFF_BAD(ctx, "INDEX out of range");
}

static void spdf_cff_item(fz_context* ctx, const unsigned char* p, const spdf_cff_index* x, unsigned i, size_t* start,
                          size_t* end) {
    size_t a, b;
    if (i >= x->count) SPDF_CFF_BAD(ctx, "INDEX item out of range");
    a = spdf_cff_offset(p, x, i);
    b = spdf_cff_offset(p, x, i + 1);
    if (a < 1 || b < a || x->data + b > x->end) SPDF_CFF_BAD(ctx, "bad INDEX item");
    *start = x->data + a;
    *end = x->data + b;
}

/* Writes an INDEX of `count` items, item i being data[offs[i]..offs[i + 1]). */
static void spdf_cff_put_index(fz_context* ctx, fz_buffer* out, const unsigned char* data, const size_t* offs,
                               unsigned count) {
    unsigned offsize = 1, i, k;
    while (offsize < 4 && ((offs[count] + 1) >> (8 * offsize))) offsize++;
    fz_append_int16_be(ctx, out, (int)count);
    if (!count) return;
    fz_append_byte(ctx, out, (int)offsize);
    for (i = 0; i <= count; i++)
        for (k = offsize; k-- > 0;) fz_append_byte(ctx, out, (int)(((offs[i] + 1) >> (8 * k)) & 0xff));
    fz_append_data(ctx, out, data, offs[count]);
}

typedef struct {
    int op; /* 0-21, or 1200 + the second byte of an escaped operator */
    int nargs;
    double args[48];
    size_t start, end; /* the bytes of the entry, operands and operator */
} spdf_cff_entry;

/* The DICT entry at *at, before `end`; 0 at the end of the DICT. Real operands read as 0: only integers matter here. */
static int spdf_cff_dict_next(fz_context* ctx, const unsigned char* p, size_t end, size_t* at, spdf_cff_entry* e) {
    size_t i = *at;
    if (i >= end) return 0;
    e->start = i;
    e->nargs = 0;
    while (i < end) {
        unsigned b = p[i];
        double v = 0;
        if (b <= 21) {
            if (b == 12 && i + 1 >= end) SPDF_CFF_BAD(ctx, "DICT ends in an escape");
            e->op = b == 12 ? 1200 + p[i + 1] : (int)b;
            i += b == 12 ? 2 : 1;
            e->end = *at = i;
            return 1;
        }
        if (b == 28 && i + 3 <= end)
            v = (int16_t)spdf_get16(p + i + 1), i += 3;
        else if (b == 29 && i + 5 <= end)
            v = (int32_t)spdf_get32(p + i + 1), i += 5;
        else if (b == 30) {
            for (i++; i < end && (p[i] & 0x0f) != 0x0f && (p[i] & 0xf0) != 0xf0; i++) {
            }
            if (i++ >= end) SPDF_CFF_BAD(ctx, "DICT ends in a real");
        } else if (b >= 32 && b <= 246)
            v = (int)b - 139, i++;
        else if (b >= 247 && b <= 250 && i + 2 <= end)
            v = ((int)b - 247) * 256 + p[i + 1] + 108, i += 2;
        else if (b >= 251 && b <= 254 && i + 2 <= end)
            v = -((int)b - 251) * 256 - p[i + 1] - 108, i += 2;
        else
            SPDF_CFF_BAD(ctx, "bad DICT operand");
        if (e->nargs == 48) SPDF_CFF_BAD(ctx, "too many DICT operands");
        e->args[e->nargs++] = v;
    }
    SPDF_CFF_BAD(ctx, "DICT ends in operands");
    return 0;
}

static void spdf_cff_put_op(fz_context* ctx, fz_buffer* out, int op) {
    if (op >= 1200) fz_append_byte(ctx, out, 12);
    fz_append_byte(ctx, out, op % 1200);
}

/* An integer operand in the 5-byte form, so a DICT's size does not depend on the offsets in it. */
static void spdf_cff_put_int5(fz_context* ctx, fz_buffer* out, size_t v) {
    fz_append_byte(ctx, out, 29);
    fz_append_int32_be(ctx, out, (int)v);
}

typedef struct {
    size_t dict, dict_end; /* the Font DICT of a CID-keyed font */
    size_t priv, priv_end;
    spdf_cff_index subrs;
    int has_subrs, used, index;
    size_t new_at, new_len; /* where its Private DICT went in the subset */
} spdf_cff_fd;

static unsigned spdf_cff_bias(const spdf_cff_index* x) {
    return x->count < 1240 ? 107 : x->count < 33900 ? 1131 : 32768;
}

static void spdf_cff_load_private(fz_context* ctx, const unsigned char* p, size_t len, const spdf_cff_entry* e,
                                  spdf_cff_fd* fd) {
    spdf_cff_entry s;
    size_t at;
    if (e->nargs < 2 || e->args[0] < 0 || e->args[1] < 0 || e->args[0] + e->args[1] > (double)len)
        SPDF_CFF_BAD(ctx, "bad Private DICT");
    fd->priv = at = (size_t)e->args[1];
    fd->priv_end = fd->priv + (size_t)e->args[0];
    while (spdf_cff_dict_next(ctx, p, fd->priv_end, &at, &s))
        if (s.op == 19 && s.nargs == 1 && s.args[0] > 0) {
            spdf_cff_read_index(ctx, p, len, fd->priv + (size_t)s.args[0], &fd->subrs);
            fd->has_subrs = 1;
        }
}

#include "spdf_cff_charstring.h"

/* The SID of every glyph of a name-keyed font. */
static void spdf_cff_charset(fz_context* ctx, const unsigned char* p, size_t len, size_t at, unsigned glyphs,
                             unsigned short* sid) {
    unsigned g = 1, fmt, k;
    sid[0] = 0;
    if (at == 0) { /* ISOAdobe: glyph g is SID g */
        if (glyphs > 229) SPDF_CFF_BAD(ctx, "bad charset");
        for (; g < glyphs; g++) sid[g] = (unsigned short)g;
        return;
    }
    if (at < 3 || at >= len) SPDF_CFF_BAD(ctx, "charset not handled");
    fmt = p[at++];
    if (fmt == 0 && at + 2 * (size_t)(glyphs - 1) <= len)
        for (; g < glyphs; g++, at += 2) sid[g] = (unsigned short)spdf_get16(p + at);
    else if (fmt == 1 || fmt == 2)
        while (g < glyphs) {
            unsigned first, left;
            if (at + 2 + fmt > len) SPDF_CFF_BAD(ctx, "bad charset");
            first = spdf_get16(p + at);
            left = fmt == 1 ? p[at + 2] : spdf_get16(p + at + 2);
            at += 2 + fmt;
            for (k = 0; k <= left && g < glyphs; k++) sid[g++] = (unsigned short)(first + k);
        }
    else
        SPDF_CFF_BAD(ctx, "bad charset");
}

/* The Font DICT of every glyph of a CID-keyed font. */
static void spdf_cff_fdselect(fz_context* ctx, const unsigned char* p, size_t len, size_t at, unsigned glyphs,
                              unsigned char* fd) {
    unsigned g, r, ranges;
    if (at >= len) SPDF_CFF_BAD(ctx, "bad FDSelect");
    if (p[at] == 0) {
        if (at + 1 + glyphs > len) SPDF_CFF_BAD(ctx, "bad FDSelect");
        memcpy(fd, p + at + 1, glyphs);
        return;
    }
    if (p[at] != 3 || at + 3 > len) SPDF_CFF_BAD(ctx, "bad FDSelect");
    ranges = spdf_get16(p + at + 1);
    at += 3;
    if (at + 3 * (size_t)ranges + 2 > len) SPDF_CFF_BAD(ctx, "bad FDSelect");
    for (r = 0; r < ranges; r++) {
        unsigned first = spdf_get16(p + at + 3 * r), next = spdf_get16(p + at + 3 * r + 3);
        for (g = first; g < next && g < glyphs; g++) fd[g] = p[at + 3 * r + 2];
    }
}

/* Copies the DICT [start, end) without the entries whose operator is in `drop` (ending in -1). */
static void spdf_cff_copy_dict(fz_context* ctx, fz_buffer* out, const unsigned char* p, size_t start, size_t end,
                               const int* drop) {
    spdf_cff_entry e;
    size_t at = start;
    while (spdf_cff_dict_next(ctx, p, end, &at, &e)) {
        const int* d;
        for (d = drop; *d >= 0 && *d != e.op; d++) {
        }
        if (*d < 0) fz_append_data(ctx, out, p + e.start, e.end - e.start);
    }
}

typedef struct {
    size_t charset, charstrings, fdselect, fdarray, priv_size, priv;
} spdf_cff_layout;

/* The Top DICT with the subset's offsets; Encoding (a name-keyed subset keeps the standard one) and the unique ids
 * (the subset is another font) are dropped. */
static void spdf_cff_top_dict(fz_context* ctx, fz_buffer* out, const unsigned char* p, size_t start, size_t end,
                              const spdf_cff_layout* at) {
    spdf_cff_entry e;
    size_t i = start;
    while (spdf_cff_dict_next(ctx, p, end, &i, &e)) {
        if (e.op == 15 || e.op == 17 || e.op == 1236 || e.op == 1237)
            spdf_cff_put_int5(ctx, out,
                              e.op == 15     ? at->charset
                              : e.op == 17   ? at->charstrings
                              : e.op == 1236 ? at->fdarray
                                             : at->fdselect);
        else if (e.op == 18) {
            spdf_cff_put_int5(ctx, out, at->priv_size);
            spdf_cff_put_int5(ctx, out, at->priv);
        } else {
            if (e.op != 16 && e.op != 13 && e.op != 14 && e.op != 1235)
                fz_append_data(ctx, out, p + e.start, e.end - e.start);
            continue;
        }
        spdf_cff_put_op(ctx, out, e.op);
    }
}

static size_t spdf_cff_index_len(size_t data_len, unsigned count) {
    unsigned offsize = 1;
    while (offsize < 4 && ((data_len + 1) >> (8 * offsize))) offsize++;
    return count ? 3 + ((size_t)count + 1) * offsize + data_len : 2;
}

fz_buffer* spdf_cff_subset(fz_context* ctx, const unsigned char* p, size_t len, const int* gids, int count,
                           const char* name) {
    static const int drop_subrs[] = {19, -1};
    static const int drop_private[] = {18, -1};
    spdf_cff_index names, tops, strings, gsubrs, charstrings, fdarray;
    spdf_cff_entry e, top_priv;
    spdf_cff_layout lay;
    spdf_cff_fd* fds = NULL;
    unsigned char* fdsel = NULL;
    unsigned short* sid = NULL;
    size_t* offs = NULL;
    fz_buffer* cs = NULL;
    fz_buffer* priv = NULL;
    fz_buffer* fdbuf = NULL;
    fz_buffer* top = NULL;
    fz_buffer* out = NULL;
    size_t top_start, top_end, at, charset_at = 0, charstrings_at = 0, fdarray_at = 0, fdselect_at = 0;
    int cid = 0, has_priv = 0, i;
    unsigned nfd = 1, used = 0, f;

    memset(&lay, 0, sizeof lay);
    memset(&top_priv, 0, sizeof top_priv);
    fz_var(fds);
    fz_var(fdsel);
    fz_var(sid);
    fz_var(offs);
    fz_var(cs);
    fz_var(priv);
    fz_var(fdbuf);
    fz_var(top);
    fz_var(out);
    fz_try(ctx) {
        if (len < 4 || p[0] != 1 || count < 1 || !name) SPDF_CFF_BAD(ctx, "not a CFF program");
        spdf_cff_read_index(ctx, p, len, p[2], &names);
        spdf_cff_read_index(ctx, p, len, names.end, &tops);
        spdf_cff_read_index(ctx, p, len, tops.end, &strings);
        spdf_cff_read_index(ctx, p, len, strings.end, &gsubrs);
        spdf_cff_item(ctx, p, &tops, 0, &top_start, &top_end);
        at = top_start;
        while (spdf_cff_dict_next(ctx, p, top_end, &at, &e)) {
            size_t v = e.nargs > 0 && e.args[0] > 0 ? (size_t)e.args[0] : 0;
            if (e.op == 15)
                charset_at = v;
            else if (e.op == 17)
                charstrings_at = v;
            else if (e.op == 18)
                top_priv = e, has_priv = 1;
            else if (e.op == 1230)
                cid = 1;
            else if (e.op == 1236)
                fdarray_at = v;
            else if (e.op == 1237)
                fdselect_at = v;
            else if ((e.op == 1206 && (e.nargs != 1 || e.args[0] != 2)) || e.op == 1220)
                SPDF_CFF_BAD(ctx, "font kind not handled");
        }
        if (!charstrings_at || (cid ? !fdarray_at || !fdselect_at : !has_priv))
            SPDF_CFF_BAD(ctx, "incomplete Top DICT");
        spdf_cff_read_index(ctx, p, len, charstrings_at, &charstrings);
        for (i = 0; i < count; i++)
            if (gids[i] < 0 || (unsigned)gids[i] >= charstrings.count) SPDF_CFF_BAD(ctx, "glyph out of range");
        if (cid) {
            spdf_cff_read_index(ctx, p, len, fdarray_at, &fdarray);
            nfd = fdarray.count;
            fdsel = (unsigned char*)fz_calloc(ctx, charstrings.count, 1);
            spdf_cff_fdselect(ctx, p, len, fdselect_at, charstrings.count, fdsel);
        } else {
            sid = fz_malloc_array(ctx, charstrings.count, unsigned short);
            spdf_cff_charset(ctx, p, len, charset_at, charstrings.count, sid);
        }
        fds = (spdf_cff_fd*)fz_calloc(ctx, nfd ? nfd : 1, sizeof *fds);
        for (f = 0; f < nfd; f++) {
            if (!cid) {
                spdf_cff_load_private(ctx, p, len, &top_priv, &fds[0]);
                continue;
            }
            spdf_cff_item(ctx, p, &fdarray, f, &fds[f].dict, &fds[f].dict_end);
            at = fds[f].dict;
            while (spdf_cff_dict_next(ctx, p, fds[f].dict_end, &at, &e))
                if (e.op == 18) spdf_cff_load_private(ctx, p, len, &e, &fds[f]);
            if (!fds[f].priv_end) SPDF_CFF_BAD(ctx, "Font DICT without Private DICT");
        }

        cs = fz_new_buffer(ctx, 256 * (size_t)count);
        offs = fz_malloc_array(ctx, count + 1, size_t);
        offs[0] = 0;
        for (i = 0; i < count; i++) {
            unsigned d = cid ? fdsel[gids[i]] : 0;
            spdf_cs s;
            size_t a, z;
            if (d >= nfd) SPDF_CFF_BAD(ctx, "bad FDSelect");
            memset(&s, 0, sizeof s);
            s.ctx = ctx;
            s.p = p;
            s.out = cs;
            s.subrs[0] = fds[d].has_subrs ? &fds[d].subrs : NULL;
            s.subrs[1] = &gsubrs;
            spdf_cff_item(ctx, p, &charstrings, (unsigned)gids[i], &a, &z);
            spdf_cs_run(&s, a, z);
            if (!s.done) SPDF_CFF_BAD(ctx, "charstring without endchar");
            fds[d].used = 1;
            offs[i + 1] = cs->len;
        }
        priv = fz_new_buffer(ctx, 256);
        for (f = 0; f < nfd; f++)
            if (fds[f].used) {
                fds[f].index = (int)used++;
                fds[f].new_at = priv->len;
                spdf_cff_copy_dict(ctx, priv, p, fds[f].priv, fds[f].priv_end, drop_subrs);
                fds[f].new_len = priv->len - fds[f].new_at;
            }

        /* Header, Name INDEX, Top DICT INDEX, String INDEX, an empty Global Subr INDEX, charset, FDSelect, CharStrings
         * INDEX, the Private DICTs, FDArray INDEX. */
        top = fz_new_buffer(ctx, 256);
        spdf_cff_top_dict(ctx, top, p, top_start, top_end, &lay); /* only its size, which the offsets do not change */
        out = fz_new_buffer(ctx, 1024 + cs->len);
        fz_append_data(ctx, out, "\1\0\4\4", 4);
        {
            size_t one[2] = {0, strlen(name)};
            spdf_cff_put_index(ctx, out, (const unsigned char*)name, one, 1);
        }
        at = out->len + spdf_cff_index_len(top->len, 1) + (strings.end - tops.end) + 2;
        lay.charset = at;
        at += 1 + 2 * (size_t)(count - 1);
        lay.fdselect = at;
        at += cid ? 1 + (size_t)count : 0;
        lay.charstrings = at;
        at += spdf_cff_index_len(cs->len, (unsigned)count);
        lay.priv = at;
        lay.priv_size = fds[0].new_len;
        lay.fdarray = at + priv->len;
        {
            size_t top_len = top->len, one[2] = {0, 0};
            top->len = 0;
            spdf_cff_top_dict(ctx, top, p, top_start, top_end, &lay);
            if (top->len != top_len) SPDF_CFF_BAD(ctx, "Top DICT changed size");
            one[1] = top->len;
            spdf_cff_put_index(ctx, out, top->data, one, 1);
        }
        fz_append_data(ctx, out, p + tops.end, strings.end - tops.end);
        fz_append_int16_be(ctx, out, 0);
        fz_append_byte(ctx, out, 0);
        for (i = 1; i < count; i++) fz_append_int16_be(ctx, out, cid ? i : sid[gids[i]]);
        if (cid) {
            fz_append_byte(ctx, out, 0);
            for (i = 0; i < count; i++) fz_append_byte(ctx, out, fds[fdsel[gids[i]]].index);
        }
        spdf_cff_put_index(ctx, out, cs->data, offs, (unsigned)count);
        fz_append_data(ctx, out, priv->data, priv->len);
        if (cid) {
            fdbuf = fz_new_buffer(ctx, 256);
            offs[0] = 0;
            for (f = 0, i = 0; f < nfd; f++)
                if (fds[f].used) {
                    spdf_cff_copy_dict(ctx, fdbuf, p, fds[f].dict, fds[f].dict_end, drop_private);
                    spdf_cff_put_int5(ctx, fdbuf, fds[f].new_len);
                    spdf_cff_put_int5(ctx, fdbuf, lay.priv + fds[f].new_at);
                    spdf_cff_put_op(ctx, fdbuf, 18);
                    offs[++i] = fdbuf->len;
                }
            spdf_cff_put_index(ctx, out, fdbuf->data, offs, used);
        }
    }
    fz_always(ctx) {
        fz_free(ctx, fds);
        fz_free(ctx, fdsel);
        fz_free(ctx, sid);
        fz_free(ctx, offs);
        fz_drop_buffer(ctx, cs);
        fz_drop_buffer(ctx, priv);
        fz_drop_buffer(ctx, fdbuf);
        fz_drop_buffer(ctx, top);
    }
    fz_catch(ctx) {
        fz_drop_buffer(ctx, out);
        fz_rethrow(ctx);
    }
    return out;
}
