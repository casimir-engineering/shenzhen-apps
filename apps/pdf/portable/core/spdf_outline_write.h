/* spdf_pdf_add_outline (shenzhen_pdf_core.h): chapters written into a PDF that has none. Included once, at the end of
 * shenzhen_pdf_core.c, so it shares the core's document internals without being a separate object in every build. */

/* Item i's parent and siblings come from the levels alone: a level deeper than the one before is clamped to one
 * deeper, so any list of levels makes a valid tree. */
static int outline_write_clamped_level(const spdf_outline_item* items, int i, const int* levels) {
    int level = items[i].level < 0 ? 0 : items[i].level;
    if (i == 0) return 0;
    return level > levels[i - 1] + 1 ? levels[i - 1] + 1 : level;
}

static pdf_obj* outline_write_build(fz_context* ctx, fz_document* doc, pdf_document* pdf, const spdf_outline_item* items,
                                    int count, int page_count) {
    pdf_obj* root = pdf_add_new_dict(ctx, pdf, 4);
    pdf_obj** nodes = NULL;
    int* levels = NULL;
    int* descendants = NULL;
    pdf_obj* parents[64];   /* parents[l]: the node new items at level l go under (the root for level 0) */
    pdf_obj* last_child[64];
    int ancestors[64];      /* ancestors[l]: the index of the latest item at level l */
    int i;

    fz_var(nodes);
    fz_var(levels);
    fz_var(descendants);
    fz_try(ctx) {
        nodes = (pdf_obj**)fz_calloc(ctx, (size_t)count, sizeof(pdf_obj*));
        levels = (int*)fz_calloc(ctx, (size_t)count, sizeof(int));
        descendants = (int*)fz_calloc(ctx, (size_t)count, sizeof(int));
        pdf_dict_put(ctx, root, PDF_NAME(Type), PDF_NAME(Outlines));
        memset(last_child, 0, sizeof(last_child));
        parents[0] = root;
        for (i = 0; i < count; ++i) {
            int level = outline_write_clamped_level(items, i, levels);
            int page = items[i].page_index;
            pdf_obj* node;
            pdf_obj* parent;
            int up;
            if (level > 62) level = 62;
            levels[i] = level;
            parent = parents[level];
            node = pdf_add_new_dict(ctx, pdf, 6);
            nodes[i] = node;
            pdf_dict_put_text_string(ctx, node, PDF_NAME(Title),
                                     items[i].title && *items[i].title ? items[i].title : "Untitled");
            pdf_dict_put(ctx, node, PDF_NAME(Parent), parent);
            if (page >= 0 && page < page_count) {
                /* The heading's own point when it has one, the top of its page otherwise. */
                fz_link_dest dest = items[i].has_dest
                                        ? fz_make_link_dest_xyz(0, page, items[i].dest_x, items[i].dest_y, 0)
                                        : fz_make_link_dest_xyz(0, page, 0, 0, 0);
                char* uri = fz_format_link_uri(ctx, doc, dest);
                fz_try(ctx) pdf_dict_put_drop(ctx, node, PDF_NAME(Dest), pdf_new_dest_from_link(ctx, pdf, uri, 0));
                fz_always(ctx) fz_free(ctx, uri);
                fz_catch(ctx) fz_rethrow(ctx);
            }
            if (last_child[level]) {
                pdf_dict_put(ctx, last_child[level], PDF_NAME(Next), node);
                pdf_dict_put(ctx, node, PDF_NAME(Prev), last_child[level]);
            } else {
                pdf_dict_put(ctx, parent, PDF_NAME(First), node);
            }
            pdf_dict_put(ctx, parent, PDF_NAME(Last), node);
            last_child[level] = node;
            /* Every ancestor gains a descendant; the deeper levels start over under this node. */
            for (up = 0; up < level; ++up) descendants[ancestors[up]]++;
            ancestors[level] = i;
            parents[level + 1] = node;
            last_child[level + 1] = NULL;
        }
        /* Open throughout, as the chapter list shows them. */
        for (i = 0; i < count; ++i)
            if (descendants[i]) pdf_dict_put_int(ctx, nodes[i], PDF_NAME(Count), descendants[i]);
        pdf_dict_put_int(ctx, root, PDF_NAME(Count), count);
    }
    fz_always(ctx) {
        fz_free(ctx, nodes);
        fz_free(ctx, levels);
        fz_free(ctx, descendants);
    }
    fz_catch(ctx) {
        pdf_drop_obj(ctx, root);
        fz_rethrow(ctx);
    }
    return root;
}

int spdf_pdf_add_outline(const char* path, const spdf_outline_item* items, int count, char* err, size_t err_len) {
    spdf_document* doc;
    pdf_document* pdf;
    char temporary[4096];
    struct stat info;
    int ok = 0;
    int written = 0;

    set_error(err, err_len, "");
    if (!path || !*path || count < 0 || (count > 0 && !items)) {
        set_error(err, err_len, "No chapters were supplied.");
        return 0;
    }
    if (count == 0) return 1;
    if (snprintf(temporary, sizeof(temporary), "%s.chapters-%ld.tmp", path, spdf_compat_getpid()) >= (int)sizeof(temporary)) {
        set_error(err, err_len, "The path is too long.");
        return 0;
    }
    doc = spdf_open(path, err, err_len);
    if (!doc) return 0;
    fz_var(ok);
    fz_var(written);
    fz_try(doc->ctx) {
        pdf_obj* root;
        pdf_obj* existing;
        pdf_write_options options;
        pdf = pdf_specifics(doc->ctx, doc->doc);
        if (!pdf) fz_throw(doc->ctx, FZ_ERROR_FORMAT, "Only a PDF can take chapters.");
        root = pdf_dict_get(doc->ctx, pdf_trailer(doc->ctx, pdf), PDF_NAME(Root));
        existing = pdf_dict_get(doc->ctx, root, PDF_NAME(Outlines));
        /* Chapters the document has already are never replaced. */
        if (!pdf_dict_get(doc->ctx, existing, PDF_NAME(First))) {
            pdf_dict_put_drop(doc->ctx, root, PDF_NAME(Outlines),
                              outline_write_build(doc->ctx, doc->doc, pdf, items, count, doc->page_count));
            pdf_dict_put(doc->ctx, root, PDF_NAME(PageMode), PDF_NAME(UseOutlines));
            options = pdf_default_write_options;
            options.do_compress = 1;
            options.do_compress_images = 1;
            options.do_compress_fonts = 1;
            pdf_save_document(doc->ctx, pdf, temporary, &options);
            written = 1;
        }
        ok = 1;
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        ok = 0;
    }
    spdf_close(doc);
    if (ok && written) {
#ifndef _WIN32
        /* The file keeps who may read it (a private output stays private). */
        if (stat(path, &info) == 0) chmod(temporary, info.st_mode & 07777);
#else
        (void)info;
#endif
        if (spdf_compat_replace_file(temporary, path) != 0) {
            set_error(err, err_len, strerror(errno));
            ok = 0;
        }
    }
    if (!ok) spdf_compat_unlink(temporary);
    return ok;
}
