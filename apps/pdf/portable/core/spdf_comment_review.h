#pragma once

/* Which annotations are comments, and whether a comment is resolved (shenzhen_pdf_core.h, spdf_comment_item.resolved
 * and spdf_set_comment_resolved). Kept out of shenzhen_pdf_core.c (whose line cap is frozen) and included there,
 * where it is compiled.
 *
 * A resolved comment is marked the way Acrobat and Preview mark one, so they show it too: a hidden Text annotation
 * replying to it (/IRT) with /StateModel /Review and /State /Completed. Reopening adds one with /State /None; the
 * last one in the page's annotation order wins. These state annotations are never comments themselves. */

static int annot_type_should_surface(enum pdf_annot_type type) {
    return type != PDF_ANNOT_LINK && type != PDF_ANNOT_POPUP && type != PDF_ANNOT_WIDGET && type != PDF_ANNOT_SCREEN;
}

static int comment_is_review_state(fz_context* ctx, pdf_obj* obj) {
    return obj && pdf_dict_get(ctx, obj, PDF_NAME(IRT)) && pdf_dict_gets(ctx, obj, "StateModel");
}

static int comment_annotation_should_surface(fz_context* ctx, pdf_obj* obj, const char* contents, const char* author,
                                             enum pdf_annot_type annot_type) {
    if (comment_is_review_state(ctx, obj)) return 0;
    return (contents && *contents) || (author && *author) || annot_type_should_surface(annot_type);
}

/* YES when the last review state answering `comment` among the page's annotations is Completed. */
static int comment_is_resolved(fz_context* ctx, pdf_obj* annots, pdf_obj* comment) {
    int resolved = 0;
    int i;
    int count = pdf_array_len(ctx, annots);

    for (i = 0; i < count; ++i) {
        pdf_obj* annot = pdf_array_get(ctx, annots, i);
        if (!comment_is_review_state(ctx, annot)) continue;
        if (strcmp(pdf_to_name(ctx, pdf_dict_gets(ctx, annot, "StateModel")), "Review") != 0) continue;
        if (pdf_objcmp_resolve(ctx, pdf_dict_get(ctx, annot, PDF_NAME(IRT)), comment) != 0) continue;
        resolved = strcmp(pdf_to_name(ctx, pdf_dict_gets(ctx, annot, "State")), "Completed") == 0;
    }
    return resolved;
}

static pdf_obj* popup_for_parent(fz_context* ctx, pdf_obj* annots, pdf_obj* parent);
static const char* dict_text_or_empty(fz_context* ctx, pdf_obj* obj, pdf_obj* key);
static const char* comment_author_or_empty(fz_context* ctx, pdf_obj* annot_obj, pdf_obj* popup);

/* Adds the hidden review-state reply to the visible comment `comment_index` (spdf_load_comments' numbering). */
static void add_review_state(fz_context* ctx, pdf_page* page, pdf_annot* comment, int resolved, const char* author) {
    pdf_obj* comment_obj = pdf_annot_obj(ctx, comment);
    pdf_annot* reply = pdf_create_annot_raw(ctx, page, PDF_ANNOT_TEXT);
    pdf_obj* obj = pdf_annot_obj(ctx, reply);
    const char* state = resolved ? "Completed" : "None";
    char contents[256];

    pdf_dict_put_rect(ctx, obj, PDF_NAME(Rect), pdf_dict_get_rect(ctx, comment_obj, PDF_NAME(Rect)));
    pdf_dict_put(ctx, obj, PDF_NAME(IRT), comment_obj);
    pdf_dict_puts_drop(ctx, obj, "StateModel", pdf_new_name(ctx, "Review"));
    pdf_dict_puts_drop(ctx, obj, "State", pdf_new_name(ctx, state));
    /* Hidden, NoZoom, NoRotate, Print: never drawn, as Acrobat writes it. */
    pdf_dict_put_int(ctx, obj, PDF_NAME(F), 30);
    if (author && *author) pdf_dict_put_text_string(ctx, obj, PDF_NAME(T), author);
    snprintf(contents, sizeof(contents), "%s set by %s", state, author && *author ? author : "ShenzhenPDF");
    pdf_dict_put_text_string(ctx, obj, PDF_NAME(Contents), contents);
    pdf_dict_put_date(ctx, obj, PDF_NAME(CreationDate), (int64_t)time(NULL));
    pdf_dict_put_date(ctx, obj, PDF_NAME(M), (int64_t)time(NULL));
}

int spdf_set_comment_resolved(spdf_document* doc, int comment_index, int resolved, const char* author, char* err,
                              size_t err_len) {
    pdf_document* pdf = NULL;
    pdf_page* page = NULL;
    int visible_index = 0;
    int found = 0;
    int i;

    set_error(err, err_len, "");
    if (!doc || comment_index < 0) {
        set_error(err, err_len, "Comment index is out of range.");
        return 0;
    }
    fz_try(doc->ctx) {
        pdf = pdf_specifics(doc->ctx, doc->doc);
        if (!pdf) fz_throw(doc->ctx, FZ_ERROR_FORMAT, "Comments can only be resolved in PDF files.");
        for (i = 0; i < doc->page_count && !found; ++i) {
            pdf_annot* annot;
            pdf_obj* annots;
            page = pdf_load_page(doc->ctx, pdf, i);
            annots = pdf_dict_get(doc->ctx, page->obj, PDF_NAME(Annots));
            for (annot = pdf_first_annot(doc->ctx, page); annot; annot = pdf_next_annot(doc->ctx, annot)) {
                pdf_obj* obj = pdf_annot_obj(doc->ctx, annot);
                pdf_obj* popup = pdf_dict_get(doc->ctx, obj, PDF_NAME(Popup));
                const char* contents = pdf_annot_contents(doc->ctx, annot);
                if (!popup) popup = popup_for_parent(doc->ctx, annots, obj);
                if (!contents || !*contents) contents = dict_text_or_empty(doc->ctx, popup, PDF_NAME(Contents));
                if (!comment_annotation_should_surface(doc->ctx, obj, contents, comment_author_or_empty(doc->ctx, obj,
                                                       popup), pdf_annot_type(doc->ctx, annot)))
                    continue;
                if (visible_index++ != comment_index) continue;
                if (comment_is_resolved(doc->ctx, annots, obj) != !!resolved)
                    add_review_state(doc->ctx, page, annot, resolved, author);
                found = 1;
                break;
            }
            pdf_drop_page(doc->ctx, page);
            page = NULL;
        }
        if (!found) fz_throw(doc->ctx, FZ_ERROR_FORMAT, "Comment was not found.");
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        if (page) pdf_drop_page(doc->ctx, page);
        spdf_drop_page_list_cache(doc, -1);
        return 0;
    }
    spdf_drop_page_list_cache(doc, -1);
    return 1;
}
