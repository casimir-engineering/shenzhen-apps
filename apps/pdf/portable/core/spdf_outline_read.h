#pragma once

/* A document's outline as spdf_load_outline gives it (shenzhen_pdf_core.h): read from mupdf's, EPUB links resolved to
 * pages, moved verbatim out of shenzhen_pdf_core.c (whose line cap is frozen) and included there, where it is
 * compiled. */

typedef struct outline_builder {
    spdf_outline_item* items;
    int count;
    int capacity;
} outline_builder;

static int append_outline_item(outline_builder* builder, const char* title, int page_index, int level, float dest_x,
                               float dest_y, int has_dest) {
    spdf_outline_item* next_items;
    int next_capacity;

    if (builder->count == builder->capacity) {
        next_capacity = builder->capacity ? builder->capacity * 2 : 32;
        next_items = (spdf_outline_item*)realloc(builder->items, (size_t)next_capacity * sizeof(spdf_outline_item));
        if (!next_items) return 0;
        builder->items = next_items;
        builder->capacity = next_capacity;
    }

    builder->items[builder->count].title = copy_string(title && *title ? title : "Untitled");
    if (!builder->items[builder->count].title) return 0;
    builder->items[builder->count].page_index = page_index;
    builder->items[builder->count].level = level;
    builder->items[builder->count].dest_x = has_dest ? dest_x : 0.0f;
    builder->items[builder->count].dest_y = has_dest ? dest_y : 0.0f;
    builder->items[builder->count].has_dest = has_dest;
    builder->count++;
    return 1;
}

static void collect_outline(spdf_document* doc, outline_builder* builder, fz_outline* outline, int level) {
    fz_outline* item;

    for (item = outline; item; item = item->next) {
        int page_index = -1;
        fz_location location = item->page;
        /* fz_outline.x/y carry the destination point for the outline link. For
         * /Fit-style destinations mupdf leaves them as 0 (or non-finite); only
         * treat the point as usable when it is finite and not the (0,0) sentinel
         * so position-aware attribution falls back gracefully otherwise. */
        float dest_x = item->x;
        float dest_y = item->y;
        int has_dest = isfinite(dest_x) && isfinite(dest_y) && !(dest_x == 0.0f && dest_y == 0.0f);
        /* EPUB outlines are returned as internal URIs with an unresolved
         * (-1,-1) location. Resolve only that fallback case: PDF destinations
         * remain untouched, while external and invalid links stay unresolved. */
        if ((location.chapter < 0 || location.page < 0) && item->uri && *item->uri &&
            !fz_is_external_link(doc->ctx, item->uri))
            location = fz_resolve_link(doc->ctx, doc->doc, item->uri, NULL, NULL);
        if (location.chapter >= 0 && location.page >= 0)
            page_index = fz_page_number_from_location(doc->ctx, doc->doc, location);
        if (!append_outline_item(builder, item->title, page_index, level, dest_x, dest_y, has_dest))
            fz_throw(doc->ctx, FZ_ERROR_SYSTEM, "Out of memory");
        if (item->down) collect_outline(doc, builder, item->down, level + 1);
    }
}

int spdf_load_outline(spdf_document* doc, spdf_outline* out, char* err, size_t err_len) {
    fz_outline* outline = NULL;
    outline_builder builder;

    set_error(err, err_len, "");
    if (!out) {
        set_error(err, err_len, "No outline output was supplied.");
        return 0;
    }
    memset(out, 0, sizeof(*out));
    memset(&builder, 0, sizeof(builder));
    if (!doc) return 0;

    fz_try(doc->ctx) {
        outline = fz_load_outline(doc->ctx, doc->doc);
        if (outline) collect_outline(doc, &builder, outline, 0);
        if (outline) fz_drop_outline(doc->ctx, outline);
        outline = NULL;
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        if (outline) fz_drop_outline(doc->ctx, outline);
        out->items = builder.items;
        out->count = builder.count;
        spdf_free_outline(out);
        return 0;
    }

    out->items = builder.items;
    out->count = builder.count;
    return 1;
}

void spdf_free_outline(spdf_outline* outline) {
    int i;

    if (!outline) return;
    for (i = 0; i < outline->count; ++i) free(outline->items[i].title);
    free(outline->items);
    memset(outline, 0, sizeof(*outline));
}
