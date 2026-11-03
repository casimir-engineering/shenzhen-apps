#pragma once
/* spdf_cff_charstring.h -- included in place by spdf_cff_subset.c (its INDEX reader and subroutine bias): one Type 2
 * charstring with its subroutines inlined. */

/* One charstring written out with its subroutines inlined: the operand naming a subroutine is dropped, the
 * subroutine's own bytes take the place of the call and its return. Stems are counted for the hintmask bytes. */
typedef struct {
    fz_context* ctx;
    const unsigned char* p;
    fz_buffer* out;
    const spdf_cff_index* subrs[2]; /* local, global */
    int nstems, nargs, done, depth;
    double last;
    size_t last_at;
} spdf_cs;

static void spdf_cs_run(spdf_cs* s, size_t i, size_t end) {
    fz_context* ctx = s->ctx;
    const unsigned char* p = s->p;
    while (i < end && !s->done) {
        unsigned b = p[i];
        size_t n = 0, m;
        double v = 0;
        if (b == 28)
            n = 3, v = i + 3 <= end ? (int16_t)spdf_get16(p + i + 1) : 0;
        else if (b >= 32 && b <= 246)
            n = 1, v = (int)b - 139;
        else if (b >= 247 && b <= 250)
            n = 2, v = i + 2 <= end ? ((int)b - 247) * 256 + p[i + 1] + 108 : 0;
        else if (b >= 251 && b <= 254)
            n = 2, v = i + 2 <= end ? -((int)b - 251) * 256 - p[i + 1] - 108 : 0;
        else if (b == 255)
            n = 5, v = i + 5 <= end ? (int32_t)spdf_get32(p + i + 1) / 65536.0 : 0;
        if (n) {
            if (i + n > end) SPDF_CFF_BAD(ctx, "charstring ends in a number");
            s->last = v;
            s->last_at = s->out->len;
            s->nargs++;
            fz_append_data(ctx, s->out, p + i, n);
            i += n;
            continue;
        }
        switch (b) {
            case 10: /* callsubr */
            case 29: /* callgsubr */
            {
                const spdf_cff_index* x = s->subrs[b == 29];
                long k = (long)s->last;
                size_t a, z;
                if (!x || s->nargs < 1 || s->depth >= 10 || (double)k != s->last)
                    SPDF_CFF_BAD(ctx, "bad subroutine call");
                k += (long)spdf_cff_bias(x);
                if (k < 0) SPDF_CFF_BAD(ctx, "bad subroutine call");
                spdf_cff_item(ctx, p, x, (unsigned)k, &a, &z);
                s->out->len = s->last_at;
                s->nargs--;
                s->depth++;
                spdf_cs_run(s, a, z);
                s->depth--;
                i++;
                break;
            }
            case 11: /* return */
                return;
            case 14: /* endchar; with 4 operands more it is seac, an accented glyph made of two others */
                if (s->nargs >= 4) SPDF_CFF_BAD(ctx, "seac");
                fz_append_byte(ctx, s->out, 14);
                s->done = 1;
                return;
            case 1:
            case 3:
            case 18:
            case 23: /* hstem, vstem, hstemhm, vstemhm */
                s->nstems += s->nargs / 2;
                s->nargs = 0;
                fz_append_byte(ctx, s->out, (int)b);
                i++;
                break;
            case 19:
            case 20: /* hintmask, cntrmask: operands left are vstems */
                s->nstems += s->nargs / 2;
                s->nargs = 0;
                m = 1 + (size_t)(s->nstems + 7) / 8;
                if (i + m > end) SPDF_CFF_BAD(ctx, "charstring ends in a hintmask");
                fz_append_data(ctx, s->out, p + i, m);
                i += m;
                break;
            case 12: /* dotsection and the flexes; not the arithmetic and storage operators */
                if (i + 1 >= end || (p[i + 1] != 0 && (p[i + 1] < 34 || p[i + 1] > 37)))
                    SPDF_CFF_BAD(ctx, "charstring operator not handled");
                fz_append_data(ctx, s->out, p + i, 2);
                s->nargs = 0;
                i += 2;
                break;
            case 4:
            case 5:
            case 6:
            case 7:
            case 8:
            case 21:
            case 22:
            case 24:
            case 25:
            case 26:
            case 27:
            case 30:
            case 31:
                fz_append_byte(ctx, s->out, (int)b);
                s->nargs = 0;
                i++;
                break;
            default:
                SPDF_CFF_BAD(ctx, "reserved charstring operator");
        }
    }
}
