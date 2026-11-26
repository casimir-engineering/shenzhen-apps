/* A live placement on a PDF page in the dark reading theme (spdf_paint_render_placed): the region is recoloured as
 * the reader recolours a page (shenzhen_pdf_core.c, SPDF_RENDER_DARK_THEME), once everything in it is drawn, so the
 * objects being moved and the annotations around them take the reader's colours. With SPDF_RENDER_PRESERVE_IMAGES the
 * reader leaves the page's own pictures as they are: the images its structured text finds in the page's contents
 * (fz_new_stext_page_from_page runs the contents only: pictures in annotations, ours included, are recoloured). The
 * same rectangles are kept here, read once per page and scaled by the reader's own rule. */
#include "spdf_paint_pdf_internal.h"

#include <string.h>

/* As the reader's collect_image_rects_from_blocks. */
static void add_blocks(fz_stext_block* block, spdf_recolor_page_entry* into) {
    for (; block; block = block->next) {
        if (block->type == FZ_STEXT_BLOCK_IMAGE) {
            if (into->count < SPDF_RECOLOR_MAX_REGIONS && block->bbox.x1 > block->bbox.x0 &&
                block->bbox.y1 > block->bbox.y0) {
                spdf_recolor_frect* r = &into->rects[into->count++];
                r->x0 = block->bbox.x0, r->y0 = block->bbox.y0, r->x1 = block->bbox.x1, r->y1 = block->bbox.y1;
            }
        } else if (block->type == FZ_STEXT_BLOCK_STRUCT && block->u.s.down) {
            add_blocks(block->u.s.down->first_block, into);
        }
    }
}

/* As the reader's page_recolor_exclusions: the page's contents through a structured-text device keeping images. */
static void read_page_images(spdf_paint_doc* doc, spdf_recolor_page_entry* into) {
    fz_context* ctx = doc->ctx;
    pdf_page* volatile page = NULL;
    fz_stext_page* volatile text = NULL;
    fz_device* volatile dev = NULL;
    fz_try(ctx) {
        fz_stext_options opts;
        memset(&opts, 0, sizeof(opts));
        opts.flags = FZ_STEXT_PRESERVE_IMAGES;
        page = spdf_paint_pdf_load_page(doc);
        text = fz_new_stext_page(ctx, fz_bound_page(ctx, &page->super));
        dev = fz_new_stext_device(ctx, text, &opts);
        pdf_run_page_contents(ctx, page, dev, fz_identity, NULL);
        fz_close_device(ctx, dev);
        add_blocks(text->first_block, into);
    }
    fz_always(ctx) {
        fz_drop_device(ctx, dev);
        fz_drop_stext_page(ctx, text);
        pdf_drop_page(ctx, page);
    }
    fz_catch(ctx) { /* as the reader: a page it can't read keeps no pictures, recoloured whole */
        fz_ignore_error(ctx);
        into->count = 0;
    }
}

void spdf_paint_dark_recolor(spdf_paint_doc* doc, fz_pixmap* dest, fz_irect box, float scale, int keep_images) {
    spdf_paint_pdf_state* st = spdf_paint_pdf_state_of(doc);
    spdf_recolor_irect keep[SPDF_RECOLOR_MAX_REGIONS];
    int kept = 0;
    if (dest->n != 4) return;
    if (keep_images && st && st->page_list) {
        if (st->images_of != st->page_list) { /* the page was read again since: its pictures too */
            fz_drop_display_list(doc->ctx, st->images_of);
            st->images_of = fz_keep_display_list(doc->ctx, st->page_list);
            memset(&st->page_images, 0, sizeof(st->page_images));
            read_page_images(doc, &st->page_images);
        }
        kept = spdf_recolor_page_entry_exclusions(&st->page_images, scale, box.x0, box.y0, keep,
                                                  SPDF_RECOLOR_MAX_REGIONS);
    }
    spdf_recolor_table table;
    spdf_recolor_table_init(&table, SPDF_RECOLOR_LUMA_REMAP, spdf_recolor_default_dark_theme());
    for (int y = 0; y < dest->h; y++)
        spdf_recolor_rgba_row(dest->samples + (size_t)y * dest->stride, dest->w, y, &table, keep, kept);
}
