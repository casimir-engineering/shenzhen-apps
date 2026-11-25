/* spdf_form_original.c -- what a PDF's own fields held before Fill & Sign first changed them, and putting it back
 * (spdf_form.h: spdf_form_filled_count, spdf_form_reset_filled, spdf_form_restore_filled).
 *
 * The record lives in the file: /Info /ShenzhenPDFFillOriginals [ << /T (full name) /N 12 /V (value) >> ... ]. A field
 * gets its entry the first time a setter changes it, so the entry holds what the PDF came with (or what another app
 * wrote), never a value Fill & Sign typed. Putting a field back goes through the same appearance and page bookkeeping
 * as the setters: text and choices are redrawn by MuPDF, checkboxes and radio buttons show their own states again. */
#include "spdf_form.h"
#include "spdf_core_document.h"
#include "spdf_form_internal.h"

#include "mupdf/pdf.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ORIGINALS_KEY "ShenzhenPDFFillOriginals"

enum { ORIGINAL_DEPTH_CAP = 32 };

static void original_error(char* err, size_t err_len, const char* message) {
    if (err && err_len) snprintf(err, err_len, "%s", message ? message : "");
}

static pdf_obj* info_of(fz_context* ctx, pdf_document* pdf) {
    return pdf_dict_get(ctx, pdf_trailer(ctx, pdf), PDF_NAME(Info));
}

static pdf_obj* record_of(fz_context* ctx, pdf_document* pdf) {
    pdf_obj* list = pdf_dict_gets(ctx, info_of(ctx, pdf), ORIGINALS_KEY);
    return pdf_is_array(ctx, list) ? list : NULL;
}

/* The record, made on first use. A missing (or direct) /Info becomes a new object first: creating it starts this
 * change, so the trailer that receives it is the one the next save writes. */
static pdf_obj* record_for_writing(fz_context* ctx, pdf_document* pdf) {
    pdf_obj* info = info_of(ctx, pdf);
    pdf_obj* list;
    if (!pdf_is_indirect(ctx, info) || !pdf_is_dict(ctx, info)) {
        pdf_obj* fresh = pdf_add_new_dict(ctx, pdf, 4);
        fz_try(ctx) {
            int i, n = pdf_is_dict(ctx, info) ? pdf_dict_len(ctx, info) : 0;
            for (i = 0; i < n; ++i)
                pdf_dict_put(ctx, fresh, pdf_dict_get_key(ctx, info, i), pdf_dict_get_val(ctx, info, i));
            pdf_dict_put(ctx, pdf_trailer(ctx, pdf), PDF_NAME(Info), fresh);
        }
        fz_always(ctx) pdf_drop_obj(ctx, fresh);
        fz_catch(ctx) fz_rethrow(ctx);
        info = info_of(ctx, pdf);
    }
    list = pdf_dict_gets(ctx, info, ORIGINALS_KEY);
    if (!pdf_is_array(ctx, list)) {
        list = pdf_new_array(ctx, pdf, 4);
        pdf_dict_puts_drop(ctx, info, ORIGINALS_KEY, list);
    }
    return list;
}

static pdf_obj* value_of(fz_context* ctx, pdf_obj* field) {
    pdf_obj* v = pdf_dict_get_inheritable(ctx, field, PDF_NAME(V));
    return !v || pdf_is_null(ctx, v) ? NULL : v;
}

/* A direct copy of a value, or NULL for none. Text kept in a stream (rich text) is kept as its plain text. */
static pdf_obj* copy_value(fz_context* ctx, pdf_obj* field, pdf_obj* v) {
    if (!v) return NULL;
    if (pdf_is_stream(ctx, v)) return pdf_new_text_string(ctx, pdf_field_value(ctx, field));
    return pdf_deep_copy_obj(ctx, pdf_resolve_indirect_chain(ctx, v));
}

static int value_is_empty(fz_context* ctx, pdf_obj* v) {
    if (!v || pdf_is_null(ctx, v)) return 1;
    if (pdf_is_string(ctx, v)) return pdf_to_text_string(ctx, v)[0] == 0;
    if (pdf_is_name(ctx, v)) return pdf_name_eq(ctx, v, PDF_NAME(Off));
    if (pdf_is_array(ctx, v)) return pdf_array_len(ctx, v) == 0;
    return 0;
}

/* Equal as the person sees them: no value, an empty text and Off are all "empty"; texts compare as text. */
static int values_equal(fz_context* ctx, pdf_obj* a, pdf_obj* b) {
    if (value_is_empty(ctx, a) || value_is_empty(ctx, b)) return value_is_empty(ctx, a) && value_is_empty(ctx, b);
    if (pdf_is_string(ctx, a) && pdf_is_string(ctx, b))
        return strcmp(pdf_to_text_string(ctx, a), pdf_to_text_string(ctx, b)) == 0;
    return pdf_objcmp_resolve(ctx, a, b) == 0;
}

static int entry_index(fz_context* ctx, pdf_obj* list, const char* name) {
    int i, n = pdf_array_len(ctx, list);
    for (i = 0; i < n; ++i)
        if (!strcmp(pdf_dict_get_text_string(ctx, pdf_array_get(ctx, list, i), PDF_NAME(T)), name)) return i;
    return -1;
}

/* The field an entry names: by object number when that object still carries the name (fast, and right for odd names
 * with dots), else by name (another app renumbered the file). A kept reference, or NULL. */
static pdf_obj* entry_field(fz_context* ctx, pdf_document* pdf, pdf_obj* entry) {
    const char* name = pdf_dict_get_text_string(ctx, entry, PDF_NAME(T));
    int num = pdf_dict_get_int(ctx, entry, PDF_NAME(N));
    pdf_obj* field;
    if (!name[0]) return NULL;
    if (num > 0 && num < pdf_xref_len(ctx, pdf)) {
        char* found = NULL;
        field = pdf_new_indirect(ctx, pdf, num, 0);
        fz_try(ctx) {
            if (pdf_is_dict(ctx, field) && pdf_dict_get(ctx, field, PDF_NAME(T)))
                found = pdf_load_field_name(ctx, field);
        }
        fz_catch(ctx) fz_ignore_error(ctx);
        if (found && !strcmp(found, name)) {
            fz_free(ctx, found);
            return field;
        }
        fz_free(ctx, found);
        pdf_drop_obj(ctx, field);
    }
    field = pdf_lookup_field(ctx, pdf_dict_getp(ctx, pdf_trailer(ctx, pdf), "Root/AcroForm/Fields"), name);
    return pdf_keep_obj(ctx, field);
}

/* Fields nobody may change now: never put back, and their entries stay. */
static int field_is_fixed(fz_context* ctx, pdf_obj* field, pdf_locked_fields* locked, const char* name) {
    int type = pdf_field_type(ctx, field);
    if (type == PDF_WIDGET_TYPE_SIGNATURE || type == PDF_WIDGET_TYPE_BUTTON || type == PDF_WIDGET_TYPE_UNKNOWN)
        return 1;
    if (pdf_field_flags(ctx, field) & PDF_FIELD_IS_READ_ONLY) return 1;
    return locked && pdf_is_field_locked(ctx, locked, name);
}

/* Checkbox and radio widgets show `state` where they have it (each keeps to its own states, as the setter does);
 * other widgets are marked for MuPDF to draw again from the field's value. */
static void refresh_widgets(fz_context* ctx, pdf_obj* node, pdf_obj* state, int depth) {
    pdf_obj* kids = pdf_dict_get(ctx, node, PDF_NAME(Kids));
    int i, n = pdf_array_len(ctx, kids);
    if (depth > ORIGINAL_DEPTH_CAP) return;
    if (pdf_dict_get(ctx, node, PDF_NAME(Subtype)) == PDF_NAME(Widget)) {
        pdf_obj* states = pdf_dict_getp(ctx, node, "AP/N");
        if (!state || !pdf_is_dict(ctx, states)) pdf_dirty_obj(ctx, node);
        if (state) {
            int has = !pdf_is_dict(ctx, states) || pdf_dict_get(ctx, states, state);
            pdf_dict_put(ctx, node, PDF_NAME(AS), has ? state : PDF_NAME(Off));
        }
    } else if (!state) {
        pdf_dirty_obj(ctx, node);
    }
    for (i = 0; i < n; ++i) refresh_widgets(ctx, pdf_array_get(ctx, kids, i), state, depth + 1);
}

/* Gives a field `v` (NULL = no value) and notes the pages whose drawing changes. */
static void put_value(fz_context* ctx, pdf_document* pdf, pdf_obj* field, pdf_obj* v, spdf_form_page_set* set) {
    int type = pdf_field_type(ctx, field);
    int button = type == PDF_WIDGET_TYPE_CHECKBOX || type == PDF_WIDGET_TYPE_RADIOBUTTON;
    int han = pdf_is_string(ctx, v) && spdf_text_contains_han(pdf_to_text_string(ctx, v));
    if (v) pdf_dict_put(ctx, field, PDF_NAME(V), v);
    else pdf_dict_del(ctx, field, PDF_NAME(V));
    refresh_widgets(ctx, field, button ? (pdf_is_name(ctx, v) ? v : PDF_NAME(Off)) : NULL, 0);
    if (!button) pdf->resynth_required = 1;
    spdf_form_visit_field_widgets(ctx, pdf, field, 0, han, set);
}

/* Draws the changed pages again and reports them ascending. */
static int finish_pages(spdf_document* doc, pdf_document* pdf, spdf_form_page_set* set, int* pages_changed, int max) {
    fz_context* ctx = doc->ctx;
    pdf_page* volatile page = NULL;
    int i;
    for (i = 1; i < set->count; ++i) {
        int v = set->pages[i], j = i - 1;
        while (j >= 0 && set->pages[j] > v) {
            set->pages[j + 1] = set->pages[j];
            --j;
        }
        set->pages[j + 1] = v;
    }
    fz_try(ctx) {
        for (i = 0; i < set->count; ++i) {
            page = pdf_load_page(ctx, pdf, set->pages[i]);
            pdf_update_page(ctx, page);
            pdf_drop_page(ctx, page);
            page = NULL;
        }
    }
    fz_always(ctx) pdf_drop_page(ctx, page);
    fz_catch(ctx) fz_rethrow(ctx);
    for (i = 0; i < set->count; ++i) {
        spdf_drop_page_list_cache(doc, set->pages[i]);
        if (pages_changed && i < max) pages_changed[i] = set->pages[i];
    }
    return set->count;
}

void spdf_form_note_original(fz_context* ctx, pdf_document* pdf, pdf_obj* field) {
    char* name = pdf_load_field_name(ctx, field);
    fz_try(ctx) {
        if (name[0] && entry_index(ctx, record_of(ctx, pdf), name) < 0) {
            pdf_obj* entry = pdf_array_push_dict(ctx, record_for_writing(ctx, pdf), 3);
            pdf_obj* v = copy_value(ctx, field, value_of(ctx, field));
            pdf_dict_put_text_string(ctx, entry, PDF_NAME(T), name);
            pdf_dict_put_int(ctx, entry, PDF_NAME(N), pdf_to_num(ctx, field));
            if (v) pdf_dict_put_drop(ctx, entry, PDF_NAME(V), v);
        }
    }
    fz_always(ctx) fz_free(ctx, name);
    fz_catch(ctx) fz_rethrow(ctx);
}

static pdf_document* writable_form(spdf_document* doc, char* err, size_t err_len) {
    pdf_document* pdf = doc && doc->doc ? pdf_specifics(doc->ctx, doc->doc) : NULL;
    original_error(err, err_len, "");
    if (!pdf) original_error(err, err_len, "Only PDF forms can be filled in.");
    else if (!spdf_owner_allows(doc, FZ_PERMISSION_FORM) && !spdf_owner_allows(doc, FZ_PERMISSION_ANNOTATE)) {
        original_error(err, err_len, "This PDF's owner doesn't allow filling it in.");
        return NULL;
    }
    return pdf;
}

int spdf_form_filled_count(spdf_document* doc, char* err, size_t err_len) {
    pdf_document* pdf = doc && doc->doc ? pdf_specifics(doc->ctx, doc->doc) : NULL;
    pdf_obj* volatile field = NULL;
    pdf_obj* volatile now = NULL;
    int count = 0;
    original_error(err, err_len, "");
    if (!pdf) return 0;
    fz_try(doc->ctx) {
        fz_context* ctx = doc->ctx;
        pdf_obj* list = record_of(ctx, pdf);
        int i, n = pdf_array_len(ctx, list);
        for (i = 0; i < n; ++i) {
            pdf_obj* entry = pdf_array_get(ctx, list, i);
            field = entry_field(ctx, pdf, entry);
            if (field && !field_is_fixed(ctx, field, NULL, "")) {
                now = copy_value(ctx, field, value_of(ctx, field));
                if (!values_equal(ctx, now, pdf_dict_get(ctx, entry, PDF_NAME(V)))) ++count;
                pdf_drop_obj(ctx, now);
                now = NULL;
            }
            pdf_drop_obj(ctx, field);
            field = NULL;
        }
    }
    fz_always(doc->ctx) {
        pdf_drop_obj(doc->ctx, now);
        pdf_drop_obj(doc->ctx, field);
    }
    fz_catch(doc->ctx) {
        original_error(err, err_len, fz_caught_message(doc->ctx));
        return -1;
    }
    return count;
}

int spdf_form_reset_filled(spdf_document* doc, char** undo, int* pages_changed, int max, char* err, size_t err_len) {
    pdf_document* pdf = writable_form(doc, err, err_len);
    pdf_obj* volatile snapshot = NULL;
    pdf_obj* volatile field = NULL;
    pdf_locked_fields* volatile locked = NULL;
    char* volatile printed = NULL;
    spdf_form_page_set set;
    int count = -1;
    memset(&set, 0, sizeof(set));
    if (undo) *undo = NULL;
    if (!pdf) return -1;
    fz_try(doc->ctx) {
        fz_context* ctx = doc->ctx;
        pdf_obj* list = record_of(ctx, pdf);
        int i;
        if (pdf_array_len(ctx, list) > 0) {
            snapshot = pdf_new_array(ctx, pdf, pdf_array_len(ctx, list));
            locked = pdf_find_locked_fields(ctx, pdf, 0);
            for (i = pdf_array_len(ctx, list) - 1; i >= 0; --i) {
                pdf_obj* entry = pdf_array_get(ctx, list, i);
                pdf_obj *was, *now, *kept;
                char* name;
                field = entry_field(ctx, pdf, entry);
                if (!field) continue;
                name = pdf_load_field_name(ctx, field);
                fz_try(ctx) {
                    if (!field_is_fixed(ctx, field, locked, name)) {
                        was = pdf_dict_get(ctx, entry, PDF_NAME(V));
                        kept = pdf_array_push_dict(ctx, snapshot, 4);
                        pdf_dict_put(ctx, kept, PDF_NAME(T), pdf_dict_get(ctx, entry, PDF_NAME(T)));
                        pdf_dict_put_int(ctx, kept, PDF_NAME(N), pdf_to_num(ctx, field));
                        if (was) pdf_dict_puts(ctx, kept, "Was", was);
                        now = copy_value(ctx, field, value_of(ctx, field));
                        if (now) pdf_dict_puts_drop(ctx, kept, "Now", now);
                        now = pdf_dict_gets(ctx, kept, "Now");
                        if (!values_equal(ctx, now, was)) put_value(ctx, pdf, field, was, &set);
                        pdf_array_delete(ctx, list, i);
                    }
                }
                fz_always(ctx) fz_free(ctx, name);
                fz_catch(ctx) fz_rethrow(ctx);
                pdf_drop_obj(ctx, field);
                field = NULL;
            }
            if (pdf_array_len(ctx, list) == 0) pdf_dict_dels(ctx, info_of(ctx, pdf), ORIGINALS_KEY);
            if (undo && pdf_array_len(ctx, snapshot) > 0) {
                size_t len = 0;
                printed = pdf_sprint_obj(ctx, NULL, 0, &len, snapshot, 1, 1);
                *undo = (char*)malloc(len + 1);
                if (!*undo) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
                memcpy(*undo, printed, len);
                (*undo)[len] = 0;
            }
        }
        count = finish_pages(doc, pdf, &set, pages_changed, max);
    }
    fz_always(doc->ctx) {
        fz_free(doc->ctx, printed);
        pdf_drop_locked_fields(doc->ctx, locked);
        pdf_drop_obj(doc->ctx, field);
        pdf_drop_obj(doc->ctx, snapshot);
    }
    fz_catch(doc->ctx) {
        original_error(err, err_len, fz_caught_message(doc->ctx));
        if (undo) {
            free(*undo);
            *undo = NULL;
        }
        spdf_drop_page_list_cache(doc, -1);
        return -1;
    }
    return count;
}

static pdf_obj* parse_snapshot(fz_context* ctx, pdf_document* pdf, const char* text) {
    fz_stream* volatile stm = NULL;
    pdf_obj* volatile array = NULL;
    pdf_lexbuf lexbuf;
    pdf_lexbuf_init(ctx, &lexbuf, PDF_LEXBUF_SMALL);
    fz_try(ctx) {
        stm = fz_open_memory(ctx, (const unsigned char*)text, strlen(text));
        if (pdf_lex(ctx, stm, &lexbuf) != PDF_TOK_OPEN_ARRAY) fz_throw(ctx, FZ_ERROR_FORMAT, "Nothing to put back.");
        array = pdf_parse_array(ctx, pdf, stm, &lexbuf);
    }
    fz_always(ctx) {
        fz_drop_stream(ctx, stm);
        pdf_lexbuf_fin(ctx, &lexbuf);
    }
    fz_catch(ctx) fz_rethrow(ctx);
    return array;
}

int spdf_form_restore_filled(spdf_document* doc, const char* undo, int* pages_changed, int max, char* err,
                             size_t err_len) {
    pdf_document* pdf = writable_form(doc, err, err_len);
    pdf_obj* volatile snapshot = NULL;
    pdf_obj* volatile field = NULL;
    spdf_form_page_set set;
    int count = -1;
    memset(&set, 0, sizeof(set));
    if (!pdf) return -1;
    fz_try(doc->ctx) {
        fz_context* ctx = doc->ctx;
        int i, n;
        snapshot = parse_snapshot(ctx, pdf, undo ? undo : "");
        n = pdf_array_len(ctx, snapshot);
        for (i = n - 1; i >= 0; --i) {
            pdf_obj* kept = pdf_array_get(ctx, snapshot, i);
            pdf_obj* now = pdf_dict_gets(ctx, kept, "Now");
            pdf_obj* current;
            field = entry_field(ctx, pdf, kept);
            if (field && !field_is_fixed(ctx, field, NULL, "")) {
                pdf_obj* list = record_for_writing(ctx, pdf);
                current = copy_value(ctx, field, value_of(ctx, field));
                if (!values_equal(ctx, current, now)) put_value(ctx, pdf, field, now, &set);
                pdf_drop_obj(ctx, current);
                if (entry_index(ctx, list, pdf_dict_get_text_string(ctx, kept, PDF_NAME(T))) < 0) {
                    pdf_obj* entry = pdf_array_push_dict(ctx, list, 3);
                    pdf_obj* was = pdf_dict_gets(ctx, kept, "Was");
                    pdf_dict_put(ctx, entry, PDF_NAME(T), pdf_dict_get(ctx, kept, PDF_NAME(T)));
                    pdf_dict_put_int(ctx, entry, PDF_NAME(N), pdf_to_num(ctx, field));
                    if (was) pdf_dict_put(ctx, entry, PDF_NAME(V), was);
                }
            }
            pdf_drop_obj(ctx, field);
            field = NULL;
        }
        count = finish_pages(doc, pdf, &set, pages_changed, max);
    }
    fz_always(doc->ctx) {
        pdf_drop_obj(doc->ctx, field);
        pdf_drop_obj(doc->ctx, snapshot);
    }
    fz_catch(doc->ctx) {
        original_error(err, err_len, fz_caught_message(doc->ctx));
        spdf_drop_page_list_cache(doc, -1);
        return -1;
    }
    return count;
}
