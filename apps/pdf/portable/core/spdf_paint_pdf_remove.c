/* Edit > Remove Everything Added with Annotate, for what Annotate itself wrote (docs/plans/annotate.md § 5 PDFs; Fill
 * & Sign's own items and fields are removed by its own code): every annotation whose /NM starts spdf-annotate- on
 * every page, found from /Annots without loading pages that hold none. The _ex form also keeps what it removed as a
 * small PDF of its own (bytes, so it outlives this document and a move to a writable copy), which
 * spdf_paint_pdf_restore_removed grafts back at each annotation's place in /Annots: one undo step. */
#include "spdf_paint_pdf_internal.h"

#include "spdf_core_document.h"

#include <stdlib.h>
#include <string.h>

struct spdf_paint_pdf_removed {
    unsigned char* bytes;
    size_t len;
};

static int page_holds_ours(fz_context* ctx, pdf_document* pdf, int p) {
    pdf_obj* annots = pdf_dict_get(ctx, pdf_lookup_page_obj(ctx, pdf, p), PDF_NAME(Annots));
    int i;
    for (i = 0; i < pdf_array_len(ctx, annots); ++i)
        if (spdf_paint_pdf_has_prefix(spdf_paint_pdf_nm(ctx, pdf_array_get(ctx, annots, i)), SPDF_PAINT_NM_PREFIX)) return 1;
    return 0;
}

/* The annotation without its links to the page, so grafting copies it alone. */
static pdf_obj* detached_copy(fz_context* ctx, pdf_obj* annot) {
    pdf_obj* copy = pdf_copy_dict(ctx, annot);
    pdf_dict_del(ctx, copy, PDF_NAME(P));
    pdf_dict_del(ctx, copy, PDF_NAME(Popup));
    pdf_dict_del(ctx, copy, PDF_NAME(IRT));
    return copy;
}

spdf_paint_status spdf_paint_pdf_remove_all_ex(spdf_document* doc, spdf_paint_pdf_removed** removed, int* pages,
                                               int max_pages, int* page_count, char* err, size_t err_len) {
    fz_context* ctx;
    pdf_document* pdf = doc ? pdf_specifics(doc->ctx, doc->doc) : NULL;
    pdf_document* volatile scratch = NULL;
    pdf_graft_map* volatile map = NULL;
    pdf_page* volatile page = NULL;
    fz_buffer* volatile buf = NULL;
    fz_output* volatile out = NULL;
    int volatile found = 0;
    if (removed) *removed = NULL;
    if (page_count) *page_count = 0;
    if (!pdf) return SPDF_PAINT_OK;
    ctx = doc->ctx;
    fz_try(ctx) {
        pdf_obj* list;
        int p, n = pdf_count_pages(ctx, pdf);
        if (removed) {
            scratch = pdf_create_document(ctx);
            map = pdf_new_graft_map(ctx, scratch);
            list = pdf_add_new_array(ctx, scratch, 8);
            pdf_dict_puts_drop(ctx, pdf_dict_get(ctx, pdf_trailer(ctx, scratch), PDF_NAME(Root)), "SPDFRemoved", list);
        } else {
            list = NULL;
        }
        for (p = 0; p < n; ++p) {
            pdf_obj* annots;
            int i;
            if (!page_holds_ours(ctx, pdf, p)) continue;
            page = pdf_load_page(ctx, pdf, p);
            annots = pdf_dict_get(ctx, page->obj, PDF_NAME(Annots));
            for (i = 0; list && i < pdf_array_len(ctx, annots); ++i) {
                pdf_obj* a = pdf_array_get(ctx, annots, i);
                pdf_obj *copy, *item;
                if (!spdf_paint_pdf_has_prefix(spdf_paint_pdf_nm(ctx, a), SPDF_PAINT_NM_PREFIX)) continue;
                copy = detached_copy(ctx, a);
                item = pdf_array_push_dict(ctx, list, 3);
                pdf_dict_puts_drop(ctx, item, "Page", pdf_new_int(ctx, p));
                pdf_dict_puts_drop(ctx, item, "Index", pdf_new_int(ctx, i));
                pdf_dict_puts_drop(ctx, item, "Annot", pdf_graft_mapped_object(ctx, map, copy));
                pdf_drop_obj(ctx, copy);
            }
            for (;;) {
                pdf_annot* a;
                for (a = pdf_first_annot(ctx, page); a; a = pdf_next_annot(ctx, a))
                    if (spdf_paint_pdf_has_prefix(spdf_paint_pdf_nm(ctx, pdf_annot_obj(ctx, a)), SPDF_PAINT_NM_PREFIX)) break;
                if (!a) break;
                pdf_delete_annot(ctx, page, a);
            }
            pdf_drop_page(ctx, page);
            page = NULL;
            spdf_drop_page_list_cache(doc, p);
            if (pages && found < max_pages) pages[found] = p;
            ++found;
        }
        if (removed && found) {
            pdf_write_options opts = pdf_default_write_options;
            unsigned char* data;
            size_t len;
            opts.do_compress = 1;
            buf = fz_new_buffer(ctx, 4096);
            out = fz_new_output_with_buffer(ctx, buf);
            pdf_write_document(ctx, scratch, out, &opts);
            fz_close_output(ctx, out);
            len = fz_buffer_storage(ctx, buf, &data);
            *removed = (spdf_paint_pdf_removed*)calloc(1, sizeof(**removed));
            if (!*removed || !((*removed)->bytes = (unsigned char*)malloc(len))) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
            memcpy((*removed)->bytes, data, len);
            (*removed)->len = len;
        }
    }
    fz_always(ctx) {
        pdf_drop_page(ctx, page);
        fz_drop_output(ctx, out);
        fz_drop_buffer(ctx, buf);
        pdf_drop_graft_map(ctx, map);
        pdf_drop_document(ctx, scratch);
    }
    fz_catch(ctx) {
        if (removed) spdf_paint_pdf_free_removed(*removed), *removed = NULL;
        spdf_paint_set_error(err, err_len, fz_caught_message(ctx));
        return SPDF_PAINT_ERR_FAILED;
    }
    if (page_count) *page_count = found;
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_pdf_remove_all(spdf_document* pdf, char* err, size_t err_len) {
    return spdf_paint_pdf_remove_all_ex(pdf, NULL, NULL, 0, NULL, err, err_len);
}

spdf_paint_status spdf_paint_pdf_restore_removed(spdf_document* doc, const spdf_paint_pdf_removed* removed, int* pages,
                                                 int max_pages, int* page_count, char* err, size_t err_len) {
    fz_context* ctx;
    pdf_document* pdf = doc ? pdf_specifics(doc->ctx, doc->doc) : NULL;
    fz_stream* volatile stream = NULL;
    pdf_document* volatile scratch = NULL;
    pdf_graft_map* volatile map = NULL;
    pdf_page* volatile page = NULL;
    int volatile found = 0;
    if (page_count) *page_count = 0;
    if (!pdf || !removed || !removed->len) return SPDF_PAINT_OK;
    ctx = doc->ctx;
    fz_try(ctx) {
        pdf_obj* list;
        int i, n, last = -1;
        stream = fz_open_memory(ctx, removed->bytes, removed->len);
        scratch = pdf_open_document_with_stream(ctx, stream);
        map = pdf_new_graft_map(ctx, pdf);
        list = pdf_dict_gets(ctx, pdf_dict_get(ctx, pdf_trailer(ctx, scratch), PDF_NAME(Root)), "SPDFRemoved");
        n = pdf_array_len(ctx, list);
        for (i = 0; i < n; ++i) { /* written page by page, each in /Annots order: put back the same way */
            pdf_obj* item = pdf_array_get(ctx, list, i);
            int p = pdf_to_int(ctx, pdf_dict_gets(ctx, item, "Page")), at = pdf_to_int(ctx, pdf_dict_gets(ctx, item, "Index"));
            pdf_obj* copy = pdf_graft_mapped_object(ctx, map, pdf_dict_gets(ctx, item, "Annot"));
            pdf_obj *annots, *obj;
            pdf_annot* annot;
            int k, len;
            if (p < 0 || p >= pdf_count_pages(ctx, pdf)) {
                pdf_drop_obj(ctx, copy);
                continue;
            }
            if (p != last) {
                if (page) pdf_sync_annots(ctx, page), spdf_drop_page_list_cache(doc, last);
                pdf_drop_page(ctx, page);
                page = NULL;
                page = pdf_load_page(ctx, pdf, p);
                last = p;
                if (pages && found < max_pages) pages[found] = p;
                ++found;
            }
            annot = pdf_create_annot_raw(ctx, page, pdf_annot_type_from_string(ctx, pdf_to_name(ctx,
                                                     pdf_dict_get(ctx, copy, PDF_NAME(Subtype)))));
            obj = pdf_annot_obj(ctx, annot);
            for (k = 0; k < pdf_dict_len(ctx, copy); ++k)
                if (pdf_dict_get_key(ctx, copy, k) != PDF_NAME(Type) && pdf_dict_get_key(ctx, copy, k) != PDF_NAME(Subtype))
                    pdf_dict_put(ctx, obj, pdf_dict_get_key(ctx, copy, k), pdf_dict_get_val(ctx, copy, k));
            pdf_drop_obj(ctx, copy);
            annots = pdf_dict_get(ctx, page->obj, PDF_NAME(Annots));
            len = pdf_array_len(ctx, annots);
            if (at < len - 1) { /* created last: back to its depth */
                pdf_obj* ref = pdf_keep_obj(ctx, pdf_array_get(ctx, annots, len - 1));
                pdf_array_delete(ctx, annots, len - 1);
                pdf_array_insert_drop(ctx, annots, ref, at < 0 ? 0 : at);
            }
            pdf_clean_obj(ctx, obj);
            pdf_drop_annot(ctx, annot);
        }
        if (page) pdf_sync_annots(ctx, page), spdf_drop_page_list_cache(doc, last);
    }
    fz_always(ctx) {
        pdf_drop_page(ctx, page);
        pdf_drop_graft_map(ctx, map);
        pdf_drop_document(ctx, scratch);
        fz_drop_stream(ctx, stream);
    }
    fz_catch(ctx) {
        spdf_paint_set_error(err, err_len, fz_caught_message(ctx));
        return SPDF_PAINT_ERR_FAILED;
    }
    if (page_count) *page_count = found;
    return SPDF_PAINT_OK;
}

void spdf_paint_pdf_free_removed(spdf_paint_pdf_removed* removed) {
    if (!removed) return;
    free(removed->bytes);
    free(removed);
}
