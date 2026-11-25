/* Fill & Sign's items on a PDF page canvas (docs/plans/annotate.md § 5 PDFs: "objects of this model as they are, with
 * no rewrite of files already filled"): what the canvas changed on a typed text, a mark, a signature, a pen line or an
 * arrow is written through Fill & Sign's own core calls (spdf_fill_items.h, spdf_fill_ink.h), so the item stays
 * exactly what Fill & Sign writes and reads; only visibility (Hidden), opacity (/CA) and a renamed layer's name
 * (/SPDFAnnotate /Name) are set here directly. A duplicated item is a copy of its annotation under a new /NM. */
#include "spdf_paint_pdf_internal.h"

#include "spdf_core_document.h"
#include "spdf_fill_ink.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void fail_unless(fz_context* ctx, int ok, const char* err) {
    if (!ok) fz_throw(ctx, FZ_ERROR_ARGUMENT, "%s", err && *err ? err : "Couldn't change the item.");
}

static int matches(const char* nm, const char* group) {
    size_t len = strlen(group);
    return strncmp(nm, group, len) == 0 && (nm[len] == 0 || strncmp(nm + len, "-c", 2) == 0);
}

pdf_annot* spdf_paint_pdf_clone_annot(fz_context* ctx, pdf_page* page, pdf_obj* source, const char* nm) {
    static const char* const skip[] = {"Type", "Subtype", "P", "Popup", "NM", "IRT", "StructParent", NULL};
    enum pdf_annot_type type = pdf_annot_type_from_string(ctx, pdf_to_name(ctx, pdf_dict_get(ctx, source, PDF_NAME(Subtype))));
    pdf_annot* annot = pdf_create_annot_raw(ctx, page, type);
    pdf_obj* obj = pdf_annot_obj(ctx, annot);
    int i, k;
    fz_try(ctx) {
        for (i = 0; i < pdf_dict_len(ctx, source); ++i) {
            pdf_obj* key = pdf_dict_get_key(ctx, source, i);
            int skipped = 0;
            for (k = 0; skip[k] && !skipped; ++k) skipped = strcmp(pdf_to_name(ctx, key), skip[k]) == 0;
            if (!skipped) pdf_dict_put_drop(ctx, obj, key, pdf_deep_copy_obj(ctx, pdf_dict_get_val(ctx, source, i)));
        }
        for (k = 0; k < 3; ++k) { /* its own appearance streams: moving one copy must not move the other's drawing */
            static const char* const states[] = {"AP/N", "AP/D", "AP/R"};
            pdf_obj* ap = pdf_dict_getp(ctx, source, states[k]);
            if (pdf_is_stream(ctx, ap)) {
                fz_buffer* raw = pdf_load_raw_stream(ctx, ap);
                pdf_obj* dict = pdf_copy_dict(ctx, ap);
                fz_try(ctx) pdf_dict_putp_drop(ctx, obj, states[k], pdf_add_stream(ctx, page->doc, raw, dict, 1));
                fz_always(ctx) {
                    pdf_drop_obj(ctx, dict);
                    fz_drop_buffer(ctx, raw);
                }
                fz_catch(ctx) fz_rethrow(ctx);
            }
        }
        pdf_dict_puts_drop(ctx, obj, "NM", pdf_new_text_string(ctx, nm));
        pdf_clean_obj(ctx, obj); /* keep the copied appearance */
    }
    fz_catch(ctx) {
        pdf_drop_annot(ctx, annot);
        fz_rethrow(ctx);
    }
    return annot;
}

/* A new name of the same family: spdf-fill-<uuid>, a signature's spdf-fill-sig-<id>-<uuid>, a pen line's
 * spdf-fill-pen-<uuid>... */
static void new_fill_name(const char* like, char* out, size_t cap) {
    char uuid[33];
    const char* families[] = {SPDF_FILL_PEN_NM_PREFIX, SPDF_FILL_ARROW_NM_PREFIX, NULL};
    int i;
    spdf_paint_pdf_uuid(uuid);
    for (i = 0; families[i]; ++i)
        if (spdf_paint_pdf_has_prefix(like, families[i])) {
            snprintf(out, cap, "%s%s", families[i], uuid);
            return;
        }
    if (spdf_paint_pdf_has_prefix(like, SPDF_FILL_SIGNATURE_NM_PREFIX) ||
        spdf_paint_pdf_has_prefix(like, SPDF_FILL_INITIALS_NM_PREFIX)) {
        const char* dash = strchr(like + sizeof(SPDF_FILL_SIGNATURE_NM_PREFIX) - 1, '-');
        if (dash) {
            snprintf(out, cap, "%.*s%s", (int)(dash - like + 1), like, uuid);
            return;
        }
    }
    snprintf(out, cap, "%s%s", SPDF_FILL_NM_PREFIX, uuid);
}

void spdf_paint_pdf_stash_appearance(fz_context* ctx, pdf_document* doc, pdf_obj* annot, int hide) {
    pdf_obj* ours = pdf_dict_gets(ctx, annot, SPDF_PAINT_PDF_KEY);
    pdf_obj* kept = pdf_dict_gets(ctx, ours, "AP");
    if (!hide && kept) {
        pdf_dict_putp(ctx, annot, "AP/N", kept);
        pdf_dict_dels(ctx, ours, "AP");
    } else if (hide && !kept && pdf_is_stream(ctx, pdf_dict_getp(ctx, annot, "AP/N"))) {
        pdf_obj* ap = pdf_dict_getp(ctx, annot, "AP/N");
        fz_rect box = pdf_dict_get_rect(ctx, ap, PDF_NAME(BBox));
        pdf_obj* res = pdf_new_dict(ctx, doc, 0);
        fz_buffer* none = fz_new_buffer(ctx, 1);
        if (!ours) ours = pdf_dict_puts_dict(ctx, annot, SPDF_PAINT_PDF_KEY, 1);
        pdf_dict_puts(ctx, ours, "AP", ap);
        fz_try(ctx) pdf_dict_putp_drop(ctx, annot, "AP/N", pdf_new_xobject(ctx, doc, box, fz_identity, res, none));
        fz_always(ctx) {
            pdf_drop_obj(ctx, res);
            fz_drop_buffer(ctx, none);
        }
        fz_catch(ctx) fz_rethrow(ctx);
    }
}

/* Hidden flag, opacity and a renamed layer's name on every annotation of the item. */
static void apply_props(spdf_paint_doc* doc, const char* group, const spdf_paint_layer* layer, const cJSON* old) {
    fz_context* ctx = doc->ctx;
    pdf_page* volatile page = spdf_paint_pdf_load_page(doc);
    const cJSON* old_name = cJSON_GetObjectItemCaseSensitive(old, "n");
    int renamed = !cJSON_IsString(old_name) || strcmp(old_name->valuestring, layer->name) != 0;
    fz_try(ctx) {
        pdf_annot* a;
        for (a = pdf_first_annot(ctx, page); a; a = pdf_next_annot(ctx, a)) {
            pdf_obj* obj = pdf_annot_obj(ctx, a);
            int flags = pdf_dict_get_int(ctx, obj, PDF_NAME(F));
            int want = layer->visible ? ((flags & ~PDF_ANNOT_IS_HIDDEN) | PDF_ANNOT_IS_PRINT)
                                      : ((flags | PDF_ANNOT_IS_HIDDEN) & ~PDF_ANNOT_IS_PRINT); /* Quick Look draws Print */
            float opacity = pdf_dict_get_real_default(ctx, obj, PDF_NAME(CA), 1);
            if (!matches(spdf_paint_pdf_nm(ctx, obj), group)) continue;
            spdf_paint_pdf_stash_appearance(ctx, page->doc, obj, 0); /* the real drawing back while it changes */
            if (want != flags) pdf_dict_put_int(ctx, obj, PDF_NAME(F), want);
            if (old && renamed) {
                pdf_obj* ours = pdf_dict_puts_dict(ctx, obj, SPDF_PAINT_PDF_KEY, 1);
                pdf_dict_puts_drop(ctx, ours, "Name", pdf_new_text_string(ctx, layer->name));
            }
            if (fabsf(opacity - layer->opacity) < 0.001f) {
                if (!layer->visible) spdf_paint_pdf_stash_appearance(ctx, page->doc, obj, 1), pdf_clean_obj(ctx, obj);
                continue;
            }
            if (pdf_annot_type(ctx, a) != PDF_ANNOT_STAMP) {
                pdf_set_annot_opacity(ctx, a, layer->opacity); /* MuPDF redraws text and ink with it */
                pdf_update_annot(ctx, a);
            } else { /* a signature keeps its drawing: wrapped in a form that paints it at this opacity */
                pdf_obj* ours = pdf_dict_puts_dict(ctx, obj, SPDF_PAINT_PDF_KEY, 1);
                pdf_obj* base = pdf_dict_gets(ctx, ours, "BaseAP");
                if (!base) base = pdf_dict_getp(ctx, obj, "AP/N"), pdf_dict_puts(ctx, ours, "BaseAP", base);
                if (layer->opacity >= 0.999f) {
                    pdf_dict_putp(ctx, obj, "AP/N", base);
                    pdf_dict_del(ctx, obj, PDF_NAME(CA));
                } else {
                    fz_rect box = fz_transform_rect(pdf_dict_get_rect(ctx, base, PDF_NAME(BBox)),
                                                    pdf_dict_get_matrix(ctx, base, PDF_NAME(Matrix)));
                    pdf_obj* res = pdf_new_dict(ctx, page->doc, 2);
                    pdf_obj *gs, *wrapper;
                    fz_buffer* content = fz_new_buffer_from_copied_data(ctx, (const unsigned char*)"q /GS0 gs /Fm0 Do Q", 19);
                    gs = pdf_new_dict(ctx, page->doc, 2);
                    pdf_dict_put_real(ctx, gs, PDF_NAME(ca), layer->opacity);
                    pdf_dict_put_real(ctx, gs, PDF_NAME(CA), layer->opacity);
                    pdf_dict_putp_drop(ctx, res, "ExtGState/GS0", gs);
                    pdf_dict_putp(ctx, res, "XObject/Fm0", base);
                    wrapper = pdf_new_xobject(ctx, page->doc, box, fz_identity, res, content);
                    pdf_dict_putp_drop(ctx, obj, "AP/N", wrapper);
                    pdf_dict_put_real(ctx, obj, PDF_NAME(CA), layer->opacity);
                    pdf_drop_obj(ctx, res);
                    fz_drop_buffer(ctx, content);
                }
                pdf_clean_obj(ctx, obj);
            }
            if (!layer->visible) spdf_paint_pdf_stash_appearance(ctx, page->doc, obj, 1), pdf_clean_obj(ctx, obj);
        }
    }
    fz_always(ctx) pdf_drop_page(ctx, page);
    fz_catch(ctx) fz_rethrow(ctx);
}

static void write_line(spdf_paint_doc* doc, const spdf_paint_object* o, const char* nm, int existed) {
    fz_context* ctx = doc->ctx;
    char err[512] = "";
    spdf_fill_stroke stroke;
    spdf_fill_point* volatile pts = NULL;
    int i, n = o->u.line.point_count;
    if (existed) fail_unless(ctx, spdf_fill_delete_items(doc->pdf, doc->page_index, &nm, 1, err, sizeof err), err);
    if (n <= 0) return;
    pts = (spdf_fill_point*)calloc((size_t)n, sizeof(*pts));
    if (!pts) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
    for (i = 0; i < n; ++i) pts[i].x = o->u.line.points[i].x, pts[i].y = o->u.line.points[i].y;
    memset(&stroke, 0, sizeof stroke);
    stroke.kind = o->kind == SPDF_PAINT_OBJ_ARROW ? SPDF_FILL_ARROW : SPDF_FILL_PEN;
    stroke.nm = nm;
    spdf_paint_pdf_rgb(o->u.line.color, stroke.rgb);
    stroke.width = o->u.line.width;
    stroke.points = pts;
    stroke.point_count = stroke.kind == SPDF_FILL_ARROW && n > 2 ? 2 : n;
    i = spdf_fill_add_strokes(doc->pdf, doc->page_index, &stroke, 1, err, sizeof err);
    free(pts);
    fail_unless(ctx, i, err);
}

/* The item's current box on the page (all comb cells), and how many annotations it has. */
static int item_box(spdf_paint_doc* doc, const char* group, fz_rect* box) {
    fz_context* ctx = doc->ctx;
    pdf_page* page = spdf_paint_pdf_load_page(doc);
    pdf_annot* a;
    int cells = 0;
    *box = fz_empty_rect;
    for (a = pdf_first_annot(ctx, page); a; a = pdf_next_annot(ctx, a))
        if (matches(spdf_paint_pdf_nm(ctx, pdf_annot_obj(ctx, a)), group)) {
            *box = cells ? fz_union_rect(*box, pdf_bound_annot(ctx, a)) : pdf_bound_annot(ctx, a);
            ++cells;
        }
    pdf_drop_page(ctx, page);
    return cells;
}

static void clone_item(spdf_paint_doc* doc, const char* source, const char* group) {
    fz_context* ctx = doc->ctx;
    pdf_page* volatile page = spdf_paint_pdf_load_page(doc);
    fz_try(ctx) {
        pdf_obj* annots = pdf_dict_get(ctx, page->obj, PDF_NAME(Annots));
        int i, n = pdf_array_len(ctx, annots);
        for (i = 0; i < n; ++i) {
            pdf_obj* a = pdf_array_get(ctx, annots, i);
            const char* nm = spdf_paint_pdf_nm(ctx, a);
            char name[160];
            if (!matches(nm, source)) continue;
            snprintf(name, sizeof name, "%s%s", group, nm + strlen(source)); /* a comb cell keeps its -cNN */
            pdf_drop_annot(ctx, spdf_paint_pdf_clone_annot(ctx, page, a, name));
        }
    }
    fz_always(ctx) pdf_drop_page(ctx, page);
    fz_catch(ctx) fz_rethrow(ctx);
    spdf_drop_page_list_cache(doc->pdf, doc->page_index);
}

static spdf_rect old_rect(const cJSON* old) {
    const cJSON* r = cJSON_GetObjectItemCaseSensitive(old, "rect");
    spdf_rect out = {0, 0, 0, 0};
    const cJSON *x = cJSON_GetObjectItemCaseSensitive(r, "x"), *y = cJSON_GetObjectItemCaseSensitive(r, "y");
    const cJSON *w = cJSON_GetObjectItemCaseSensitive(r, "w"), *h = cJSON_GetObjectItemCaseSensitive(r, "h");
    if (cJSON_IsNumber(x) && cJSON_IsNumber(y) && cJSON_IsNumber(w) && cJSON_IsNumber(h)) {
        out.x0 = (float)x->valuedouble, out.y0 = (float)y->valuedouble;
        out.x1 = out.x0 + (float)w->valuedouble, out.y1 = out.y0 + (float)h->valuedouble;
    }
    return out;
}

int spdf_paint_pdf_write_fill(spdf_paint_doc* doc, spdf_paint_layer* layer, spdf_paint_pdf_entry** entry) {
    fz_context* ctx = doc->ctx;
    spdf_paint_object* o = layer->object;
    spdf_paint_pdf_entry* e = *entry;
    cJSON* volatile old = e && e->model ? cJSON_Parse(e->model) : NULL;
    char err[512] = "", name[160];
    fz_try(ctx) {
        const char* nm;
        if (o->kind == SPDF_PAINT_OBJ_PEN || o->kind == SPDF_PAINT_OBJ_ARROW) {
            if (e) snprintf(name, sizeof name, "%s", e->nm);
            else new_fill_name(o->kind == SPDF_PAINT_OBJ_ARROW ? SPDF_FILL_ARROW_NM_PREFIX : SPDF_FILL_PEN_NM_PREFIX,
                               name, sizeof name);
            write_line(doc, o, name, e != NULL);
        } else {
            spdf_rect was, now = o->place.rect;
            fz_rect box;
            int cells;
            const cJSON* text = cJSON_GetObjectItemCaseSensitive(old, "t");
            const cJSON* kind = cJSON_GetObjectItemCaseSensitive(old, "fk");
            if (!e) { /* a duplicate: a copy of the item it was made from, moved to where the canvas put it */
                const char* source = o->u.fill.nm ? o->u.fill.nm : o->pdf_nm;
                if (!source || !item_box(doc, source, &box)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "The item to copy is gone.");
                new_fill_name(source, name, sizeof name);
                clone_item(doc, source, name);
                was.x0 = box.x0, was.y0 = box.y0, was.x1 = box.x1, was.y1 = box.y1;
                {
                    spdf_paint_pdf_entry* se = NULL;
                    int i;
                    for (i = 0; i < doc->pdf_state->count && !se; ++i)
                        if (doc->pdf_state->entries[i].nm && strcmp(doc->pdf_state->entries[i].nm, source) == 0)
                            se = &doc->pdf_state->entries[i];
                    if (se && se->model) {
                        cJSON* sm = cJSON_Parse(se->model);
                        was = old_rect(sm);
                        cJSON_Delete(sm);
                    }
                }
                fz_free(ctx, o->u.fill.nm), o->u.fill.nm = fz_strdup(ctx, name);
                fz_free(ctx, o->pdf_nm), o->pdf_nm = fz_strdup(ctx, name);
            } else {
                snprintf(name, sizeof name, "%s", e->nm);
                was = old_rect(old);
            }
            nm = name;
            cells = item_box(doc, nm, &box);
            if (fabsf((was.x1 - was.x0) - (now.x1 - now.x0)) < 0.01f && fabsf((was.y1 - was.y0) - (now.y1 - now.y0)) < 0.01f) {
                if (fabsf(now.x0 - was.x0) > 0.001f || fabsf(now.y0 - was.y0) > 0.001f)
                    fail_unless(ctx, spdf_fill_move_items(doc->pdf, doc->page_index, &nm, 1, now.x0 - was.x0,
                                                          now.y0 - was.y0, err, sizeof err), err);
            } else if (cells > 1) { /* comb cells keep their size: the entry moves */
                fail_unless(ctx, spdf_fill_move_items(doc->pdf, doc->page_index, &nm, 1, now.x0 - was.x0, now.y0 - was.y0,
                                                      err, sizeof err), err);
            } else {
                fail_unless(ctx, spdf_fill_update(doc->pdf, doc->page_index, nm, &now, 0, NULL, err, sizeof err), err);
            }
            if (o->kind == SPDF_PAINT_OBJ_FILL_TEXT && cells == 1 && o->u.fill.text &&
                (!cJSON_IsString(text) || strcmp(text->valuestring, o->u.fill.text) != 0) && e)
                fail_unless(ctx, spdf_fill_update(doc->pdf, doc->page_index, nm, NULL, o->u.fill.font_size, o->u.fill.text,
                                                  err, sizeof err), err);
            if (o->kind == SPDF_PAINT_OBJ_FILL_MARK && cJSON_IsNumber(kind) && kind->valueint != o->u.fill.fill_kind)
                fail_unless(ctx, spdf_fill_set_mark_kind(doc->pdf, doc->page_index, nm, o->u.fill.fill_kind == SPDF_FILL_CROSS,
                                                         err, sizeof err), err);
        }
        apply_props(doc, name, layer, old);
        if (!e) e = spdf_paint_pdf_entry_add(doc, layer->id, SPDF_PAINT_PDF_FILL, name, 0);
        e->seen = 1;
        spdf_paint_pdf_entry_set(doc, e, NULL, spdf_paint_pdf_strdup("")); /* read again after the write */
        fz_free(ctx, o->pdf_nm), o->pdf_nm = fz_strdup(ctx, name);
    }
    fz_always(ctx) cJSON_Delete(old);
    fz_catch(ctx) fz_rethrow(ctx);
    *entry = e;
    spdf_drop_page_list_cache(doc->pdf, doc->page_index);
    return 1;
}

void spdf_paint_pdf_delete_fill(spdf_paint_doc* doc, const char* group) {
    char err[512] = "";
    fail_unless(doc->ctx, spdf_fill_delete_items(doc->pdf, doc->page_index, &group, 1, err, sizeof err), err);
}
