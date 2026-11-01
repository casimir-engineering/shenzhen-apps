#pragma once

/* Reading comments for spdf_load_comments (shenzhen_pdf_core.h): the list being built, each annotation's date and the
 * comment it answers, and the passages highlights mark. Kept out of shenzhen_pdf_core.c (whose line cap is frozen)
 * and included there, where it is compiled. */

typedef struct comment_builder {
    spdf_comment_item* items;
    int count;
    int capacity;
    /* Per item while loading: the annotation's object number, and the one its IRT names (0: none). */
    int* object_numbers;
    int* reply_numbers;
} comment_builder;

static int append_comment_item(comment_builder* builder, const char* author, const char* text, const char* type,
                               int comment_index, int page_index, fz_rect bounds) {
    spdf_comment_item* next_items;
    char* author_copy;
    char* text_copy;
    char* type_copy;
    int next_capacity;

    if (builder->count == builder->capacity) {
        int* next_numbers;
        next_capacity = builder->capacity ? builder->capacity * 2 : 32;
        next_items = (spdf_comment_item*)realloc(builder->items, (size_t)next_capacity * sizeof(spdf_comment_item));
        if (!next_items) return 0;
        builder->items = next_items;
        next_numbers = (int*)realloc(builder->object_numbers, (size_t)next_capacity * sizeof(int));
        if (!next_numbers) return 0;
        builder->object_numbers = next_numbers;
        next_numbers = (int*)realloc(builder->reply_numbers, (size_t)next_capacity * sizeof(int));
        if (!next_numbers) return 0;
        builder->reply_numbers = next_numbers;
        builder->capacity = next_capacity;
    }

    author_copy = copy_string(author && *author ? author : "");
    text_copy = copy_string(text && *text ? text : "");
    type_copy = copy_string(type && *type ? type : "Annotation");
    if (!author_copy || !text_copy || !type_copy) {
        free(author_copy);
        free(text_copy);
        free(type_copy);
        return 0;
    }
    builder->items[builder->count].author = author_copy;
    builder->items[builder->count].text = text_copy;
    builder->items[builder->count].type = type_copy;
    builder->items[builder->count].index = comment_index;
    builder->items[builder->count].page_index = page_index;
    builder->items[builder->count].bounds.x0 = bounds.x0;
    builder->items[builder->count].bounds.y0 = bounds.y0;
    builder->items[builder->count].bounds.x1 = bounds.x1;
    builder->items[builder->count].bounds.y1 = bounds.y1;
    builder->items[builder->count].modified = 0;
    builder->items[builder->count].in_reply_to = -1;
    builder->object_numbers[builder->count] = 0;
    builder->reply_numbers[builder->count] = 0;
    builder->count++;
    return 1;
}

/* The date and the comment it answers, for the Comments panel. Reads two entries the annotation already holds. */
static void note_comment_metadata(fz_context* ctx, comment_builder* builder, pdf_annot* annot, pdf_obj* obj) {
    spdf_comment_item* item = &builder->items[builder->count - 1];
    pdf_obj* parent = pdf_dict_get(ctx, obj, PDF_NAME(IRT));
    int64_t when = 0;

    fz_try(ctx) {
        when = pdf_annot_modification_date(ctx, annot);
        if (when <= 0) when = pdf_annot_creation_date(ctx, annot);
    }
    fz_catch(ctx) when = 0;
    item->modified = when > 0 ? (double)when : 0;
    builder->object_numbers[builder->count - 1] = pdf_to_num(ctx, obj);
    builder->reply_numbers[builder->count - 1] = parent ? pdf_to_num(ctx, parent) : 0;
}

static void resolve_comment_replies(comment_builder* builder) {
    int i, j;

    for (i = 0; i < builder->count; ++i) {
        if (builder->reply_numbers[i] <= 0) continue;
        for (j = 0; j < builder->count; ++j)
            if (j != i && builder->object_numbers[j] == builder->reply_numbers[i]) {
                builder->items[i].in_reply_to = builder->items[j].index;
                break;
            }
    }
}

int spdf_page_text_in_rects(spdf_document* doc, int page_index, const spdf_rect* rects, int count, char** texts_out,
                            char* err, size_t err_len) {
    fz_stext_page* text = NULL;
    char* copied = NULL;
    int failed = 0;
    int i;

    set_error(err, err_len, "");
    if (!texts_out || count <= 0) return 0;
    for (i = 0; i < count; ++i) texts_out[i] = NULL;
    if (!doc || !rects || page_index < 0 || page_index >= doc->page_count) {
        set_error(err, err_len, "Page index is out of range.");
        return 0;
    }
    fz_var(copied);
    fz_try(doc->ctx) {
        text = fz_new_stext_page_from_page_number(doc->ctx, doc->doc, page_index, NULL);
        for (i = 0; i < count; ++i) {
            fz_rect area = fz_make_rect(rects[i].x0, rects[i].y0, rects[i].x1, rects[i].y1);
            copied = fz_copy_rectangle(doc->ctx, text, area, 0);
            texts_out[i] = copy_string(copied ? copied : "");
            fz_free(doc->ctx, copied);
            copied = NULL;
            if (!texts_out[i]) fz_throw(doc->ctx, FZ_ERROR_SYSTEM, "Out of memory");
        }
    }
    fz_always(doc->ctx) {
        if (copied) fz_free(doc->ctx, copied);
        if (text) fz_drop_stext_page(doc->ctx, text);
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        failed = 1;
    }
    if (failed) {
        for (i = 0; i < count; ++i) {
            free(texts_out[i]);
            texts_out[i] = NULL;
        }
        return 0;
    }
    return 1;
}

