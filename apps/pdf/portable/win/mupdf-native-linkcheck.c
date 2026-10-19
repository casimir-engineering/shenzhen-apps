/* mupdf-native-linkcheck -- prove the x64 libmupdf.lib actually links AND runs.
 *
 *   mupdf-native-linkcheck <file.pdf> [page] [zoom]
 *
 * Built and run by portable/win/mupdf-native-linkcheck.cmd. Deliberately does
 * NOT go through portable/core/shenzhen_pdf_core.h: this checks the MuPDF
 * archives on their own, so that "libmupdf is broken" and "the core shim is
 * broken" cannot be confused for each other. portable/win/smoke/core_smoke.c is
 * the test that exercises the core layer.
 *
 * WHY IT TOUCHES THE THINGS IT TOUCHES
 *   fz_new_context          the CRT agreement. A /MD-vs-/MT mismatch shows up
 *                           here as unresolved externals at link time, or as a
 *                           heap assert the moment MuPDF allocates.
 *   fz_register_document_handlers
 *                           pulls in document-all.c, hence every format handler,
 *                           hence most of the archive.
 *   fz_new_pixmap_from_page_number
 *                           the font blobs. Rendering any text at all resolves
 *                           _binary_<font> / _binary_<font>_size, which is the
 *                           only real proof that mupdf-bin2coff's x64 COFF
 *                           output (machine word 0x8664, see
 *                           mupdf-gen-ninja-native.sh D4) is a valid object and
 *                           not merely one the librarian accepted.
 *
 * JUDGE THIS BY ITS EXIT CODE, never by grepping its output (repo rule).
 *   0   rendered a non-blank page
 *   2   bad usage
 *   3   fz_new_context failed
 *   4   MuPDF threw (message on stderr)
 *   5   rendered, but the pixmap is a uniform colour -- linked and ran, yet drew
 *       nothing, which is what a silently missing font blob would look like
 * The stdout line is for humans and is not part of the contract.
 */

#include <stdio.h>
#include <stdlib.h>

#include "mupdf/fitz.h"

int main(int argc, char** argv)
{
    fz_context* ctx;
    fz_pixmap* pix = NULL;
    const char* path;
    int page = 0;
    float zoom = 1.0f;
    int rc = 0;

    if (argc < 2 || argc > 4) {
        fprintf(stderr, "usage: mupdf-native-linkcheck <file.pdf> [page] [zoom]\n");
        return 2;
    }
    path = argv[1];
    if (argc >= 3)
        page = atoi(argv[2]);
    if (argc >= 4)
        zoom = (float)atof(argv[3]);

    ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
    if (!ctx) {
        fprintf(stderr, "mupdf-native-linkcheck: fz_new_context failed\n");
        return 3;
    }

    fz_try(ctx) {
        fz_document* doc;
        int pages;
        unsigned char* s;
        size_t n, i;
        int uniform = 1;

        fz_register_document_handlers(ctx);

        doc = fz_open_document(ctx, path);
        pages = fz_count_pages(ctx, doc);

        pix = fz_new_pixmap_from_page_number(ctx, doc, page,
                fz_scale(zoom, zoom), fz_device_rgb(ctx), 0);

        /* A pixmap of one single colour means we linked, ran, and drew nothing.
         * Checking it here is what makes the font blobs part of the proof. */
        s = pix->samples;
        n = (size_t)pix->stride * (size_t)pix->h;
        for (i = 1; i < n; i++) {
            if (s[i] != s[0]) {
                uniform = 0;
                break;
            }
        }

        printf("mupdf %s: %s pages=%d page=%d zoom=%.2f -> %dx%d n=%d stride=%d %s\n",
               FZ_VERSION, path, pages, page, (double)zoom,
               pix->w, pix->h, pix->n, (int)pix->stride,
               uniform ? "UNIFORM" : "has content");

        if (uniform)
            rc = 5;

        fz_drop_document(ctx, doc);
    }
    fz_catch(ctx) {
        fprintf(stderr, "mupdf-native-linkcheck: %s\n", fz_caught_message(ctx));
        rc = 4;
    }

    fz_drop_pixmap(ctx, pix);
    fz_drop_context(ctx);
    return rc;
}
