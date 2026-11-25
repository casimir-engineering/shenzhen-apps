/* spdf_form.c -- a PDF's own form fields for Fill & Sign (spdf_form.h). */
#include "spdf_form.h"
#include "spdf_core_document.h"
#include "spdf_form_internal.h"

#include "mupdf/pdf.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    FORM_NODE_CAP = 4096,
    FORM_DEPTH_CAP = 32,
    FORM_PAGE_SCAN_CAP = 5000,
    ANNOT_FLAG_HIDDEN = 1 << 1,
    ANNOT_FLAG_NO_VIEW = 1 << 5
};

static void form_error(char* err, size_t err_len, const char* message) {
    if (err && err_len) snprintf(err, err_len, "%s", message ? message : "");
}

static char* form_strdup(const char* text) {
    size_t len = strlen(text ? text : "");
    char* copy = (char*)malloc(len + 1);
    if (copy) memcpy(copy, text ? text : "", len + 1);
    return copy;
}

static int obj_is_hidden(fz_context* ctx, pdf_obj* obj) {
    return (pdf_dict_get_int(ctx, obj, PDF_NAME(F)) & (ANNOT_FLAG_HIDDEN | ANNOT_FLAG_NO_VIEW)) != 0;
}

/* A field's /Kids are either child fields (they carry /T) or its widgets (they do not). */
static int kids_are_fields(fz_context* ctx, pdf_obj* kids) {
    int i, n = pdf_array_len(ctx, kids);
    for (i = 0; i < n; ++i)
        if (pdf_dict_get(ctx, pdf_array_get(ctx, kids, i), PDF_NAME(T))) return 1;
    return 0;
}

/* A terminal field shows when it, or at least one of its widgets, is not hidden. */
static int terminal_is_visible(fz_context* ctx, pdf_obj* field) {
    pdf_obj* kids = pdf_dict_get(ctx, field, PDF_NAME(Kids));
    int i, n = pdf_array_len(ctx, kids);
    if (n == 0) return !obj_is_hidden(ctx, field);
    for (i = 0; i < n; ++i)
        if (!obj_is_hidden(ctx, pdf_array_get(ctx, kids, i))) return 1;
    return 0;
}

static void count_terminal(fz_context* ctx, pdf_document* pdf, pdf_obj* field, spdf_form_summary* out) {
    int type = pdf_field_type(ctx, field);
    int flags = pdf_field_flags(ctx, field);
    if (type == PDF_WIDGET_TYPE_SIGNATURE) {
        if (pdf_signature_is_signed(ctx, pdf, field)) {
            out->signed_count++;
        } else if (terminal_is_visible(ctx, field)) {
            out->unsigned_signature_count++;
            out->fillable_count++;
        }
        return;
    }
    if (type == PDF_WIDGET_TYPE_BUTTON || type == PDF_WIDGET_TYPE_UNKNOWN) return; /* push buttons fill nothing */
    if (flags & PDF_FIELD_IS_READ_ONLY) return;
    if (!terminal_is_visible(ctx, field)) return;
    out->fillable_count++;
    if (flags & PDF_FIELD_IS_REQUIRED) out->required_count++;
}

static void walk_fields(fz_context* ctx, pdf_document* pdf, pdf_obj* fields, int depth, int* nodes,
                        spdf_form_summary* out) {
    int i, n = pdf_array_len(ctx, fields);
    for (i = 0; i < n; ++i) {
        pdf_obj* field = pdf_array_get(ctx, fields, i);
        pdf_obj* kids;
        if (++*nodes > FORM_NODE_CAP || depth > FORM_DEPTH_CAP) {
            out->truncated = 1;
            return;
        }
        if (!pdf_is_dict(ctx, field)) continue;
        kids = pdf_dict_get(ctx, field, PDF_NAME(Kids));
        if (pdf_array_len(ctx, kids) > 0 && kids_are_fields(ctx, kids))
            walk_fields(ctx, pdf, kids, depth + 1, nodes, out);
        else
            count_terminal(ctx, pdf, field, out);
    }
}

/* The certification level of /Perms/DocMDP: 1 no changes, 2 form filling and signing, 3 also annotations. */
static int read_docmdp(fz_context* ctx, pdf_document* pdf) {
    pdf_obj* sig = pdf_dict_getp(ctx, pdf_trailer(ctx, pdf), "Root/Perms/DocMDP");
    pdf_obj* refs = pdf_dict_get(ctx, sig, PDF_NAME(Reference));
    int i, n = pdf_array_len(ctx, refs);
    if (!pdf_is_dict(ctx, sig)) return 0;
    for (i = 0; i < n; ++i) {
        pdf_obj* ref = pdf_array_get(ctx, refs, i);
        if (pdf_dict_get(ctx, ref, PDF_NAME(TransformMethod)) != PDF_NAME(DocMDP)) continue;
        int level = pdf_dict_get_int(ctx, pdf_dict_get(ctx, ref, PDF_NAME(TransformParams)), PDF_NAME(P));
        return level >= 1 && level <= 3 ? level : 2;
    }
    return 2;
}

int spdf_form_summary_read(spdf_document* doc, spdf_form_summary* out, char* err, size_t err_len) {
    pdf_document* pdf;
    int nodes = 0;

    form_error(err, err_len, "");
    if (!out) return 0;
    memset(out, 0, sizeof(*out));
    if (!doc || !doc->doc) return 0;
    pdf = pdf_specifics(doc->ctx, doc->doc);
    if (!pdf) return 1;
    fz_try(doc->ctx) {
        pdf_obj* form = pdf_dict_getp(doc->ctx, pdf_trailer(doc->ctx, pdf), "Root/AcroForm");
        out->has_xfa = pdf_dict_get(doc->ctx, form, PDF_NAME(XFA)) != NULL;
        walk_fields(doc->ctx, pdf, pdf_dict_get(doc->ctx, form, PDF_NAME(Fields)), 0, &nodes, out);
        out->incremental_ok = pdf_can_be_saved_incrementally(doc->ctx, pdf);
        out->docmdp = read_docmdp(doc->ctx, pdf);
        out->can_add_items = spdf_owner_allows(doc, FZ_PERMISSION_ANNOTATE);
        out->can_fill_fields = out->can_add_items || spdf_owner_allows(doc, FZ_PERMISSION_FORM);
    }
    fz_catch(doc->ctx) {
        form_error(err, err_len, fz_caught_message(doc->ctx));
        memset(out, 0, sizeof(*out));
        return 0;
    }
    if (out->fillable_count > 0) out->kind = SPDF_FORM_FILLABLE;
    else if (out->has_xfa) out->kind = SPDF_FORM_XFA_ONLY;
    else if (out->signed_count > 0) out->kind = SPDF_FORM_SIGNED_ONLY;
    else out->kind = SPDF_FORM_NONE;
    return 1;
}

/* The field a widget belongs to: itself when it carries /T, else the nearest ancestor that does. */
pdf_obj* spdf_form_field_of_widget(fz_context* ctx, pdf_obj* widget) {
    pdf_obj* node = widget;
    int depth = 0;
    while (node && !pdf_dict_get(ctx, node, PDF_NAME(T)) && depth++ < FORM_DEPTH_CAP) {
        pdf_obj* parent = pdf_dict_get(ctx, node, PDF_NAME(Parent));
        if (!parent) break;
        node = parent;
    }
    return node ? node : widget;
}

static int widget_is_on(fz_context* ctx, pdf_obj* widget) {
    pdf_obj* state = pdf_dict_get(ctx, widget, PDF_NAME(AS));
    return pdf_is_name(ctx, state) && state != PDF_NAME(Off);
}

static int map_type(enum pdf_widget_type type, spdf_field_type* out) {
    switch (type) {
    case PDF_WIDGET_TYPE_TEXT: *out = SPDF_FIELD_TEXT; return 1;
    case PDF_WIDGET_TYPE_CHECKBOX: *out = SPDF_FIELD_CHECKBOX; return 1;
    case PDF_WIDGET_TYPE_RADIOBUTTON: *out = SPDF_FIELD_RADIO; return 1;
    case PDF_WIDGET_TYPE_COMBOBOX: *out = SPDF_FIELD_COMBO; return 1;
    case PDF_WIDGET_TYPE_LISTBOX: *out = SPDF_FIELD_LIST; return 1;
    case PDF_WIDGET_TYPE_SIGNATURE: *out = SPDF_FIELD_SIGNATURE; return 1;
    default: return 0;
    }
}

static void read_options(fz_context* ctx, pdf_annot* widget, spdf_form_widget* item) {
    int i, n = pdf_choice_widget_options(ctx, widget, 0, NULL);
    const char** names;
    if (n <= 0) return;
    names = (const char**)fz_calloc(ctx, (size_t)n, sizeof(*names));
    fz_try(ctx) {
        item->options = (char**)calloc((size_t)n, sizeof(char*));
        item->export_values = (char**)calloc((size_t)n, sizeof(char*));
        if (!item->options || !item->export_values) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
        item->option_count = n;
        pdf_choice_widget_options(ctx, widget, 0, names);
        for (i = 0; i < n; ++i) item->options[i] = form_strdup(names[i]);
        pdf_choice_widget_options(ctx, widget, 1, names);
        for (i = 0; i < n; ++i) item->export_values[i] = form_strdup(names[i]);
    }
    fz_always(ctx) fz_free(ctx, names);
    fz_catch(ctx) fz_rethrow(ctx);
}

/* Fills one entry; returns 0 for widgets nobody fills (push buttons). Strings are malloc'd; on a throw the caller
 * frees whatever was set. */
static int read_widget(fz_context* ctx, pdf_annot* widget, int page_index, int order, spdf_form_widget* item) {
    pdf_obj* obj = pdf_annot_obj(ctx, widget);
    pdf_obj* field = spdf_form_field_of_widget(ctx, obj);
    spdf_field_type type;
    int ff;
    char* name;

    if (!map_type(pdf_widget_type(ctx, widget), &type)) return 0;
    ff = pdf_field_flags(ctx, obj);
    item->page_index = page_index;
    item->object_number = pdf_to_num(ctx, obj);
    item->group_id = pdf_to_num(ctx, field);
    item->tab_index = order;
    {
        fz_rect r = pdf_bound_widget(ctx, widget);
        item->rect.x0 = r.x0, item->rect.y0 = r.y0, item->rect.x1 = r.x1, item->rect.y1 = r.y1;
    }
    item->type = type;
    if (pdf_widget_is_readonly(ctx, widget)) item->flags |= SPDF_FIELD_READ_ONLY;
    if (ff & PDF_FIELD_IS_REQUIRED) item->flags |= SPDF_FIELD_REQUIRED;
    if (obj_is_hidden(ctx, obj)) item->flags |= SPDF_FIELD_HIDDEN;
    if (type == SPDF_FIELD_TEXT) {
        item->max_len = pdf_text_widget_max_len(ctx, widget);
        if (ff & PDF_TX_FIELD_IS_MULTILINE) item->flags |= SPDF_FIELD_MULTILINE;
        if ((ff & PDF_TX_FIELD_IS_COMB) && item->max_len > 0) item->flags |= SPDF_FIELD_COMB;
    }
    if (type == SPDF_FIELD_COMBO && (ff & PDF_CH_FIELD_IS_EDIT)) item->flags |= SPDF_FIELD_EDITABLE_COMBO;
    if (type == SPDF_FIELD_LIST && (ff & PDF_CH_FIELD_IS_MULTI_SELECT)) item->flags |= SPDF_FIELD_MULTI_SELECT;
    if ((type == SPDF_FIELD_CHECKBOX || type == SPDF_FIELD_RADIO) && widget_is_on(ctx, obj))
        item->flags |= SPDF_FIELD_ON;
    if (type == SPDF_FIELD_SIGNATURE && pdf_widget_is_signed(ctx, widget)) item->flags |= SPDF_FIELD_SIGNED;
    if (type == SPDF_FIELD_TEXT || type == SPDF_FIELD_COMBO || type == SPDF_FIELD_LIST) {
        const char* font = NULL;
        float size = 0, color[4];
        int n = 0;
        fz_try(ctx) pdf_annot_default_appearance(ctx, widget, &font, &size, &n, color);
        fz_catch(ctx) size = 0;
        item->font_size = size;
    }
    name = pdf_load_field_name(ctx, obj);
    item->name = form_strdup(name);
    fz_free(ctx, name);
    item->label = form_strdup(pdf_field_label(ctx, obj));
    if (type == SPDF_FIELD_CHECKBOX || type == SPDF_FIELD_RADIO)
        item->value = form_strdup(pdf_to_name(ctx, pdf_button_field_on_state(ctx, obj)));
    else
        item->value = form_strdup(pdf_field_value(ctx, obj));
    if (!item->name || !item->label || !item->value) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
    if (type == SPDF_FIELD_COMBO || type == SPDF_FIELD_LIST) read_options(ctx, widget, item);
    return 1;
}

static void free_widget(spdf_form_widget* item) {
    int i;
    free(item->name);
    free(item->label);
    free(item->value);
    for (i = 0; i < item->option_count; ++i) {
        if (item->options) free(item->options[i]);
        if (item->export_values) free(item->export_values[i]);
    }
    free(item->options);
    free(item->export_values);
    memset(item, 0, sizeof(*item));
}

void spdf_free_form_widgets(spdf_form_widgets* widgets) {
    int i;
    if (!widgets) return;
    for (i = 0; i < widgets->count; ++i) free_widget(&widgets->items[i]);
    free(widgets->items);
    memset(widgets, 0, sizeof(*widgets));
}

int spdf_form_load_page_widgets(spdf_document* doc, int page_index, spdf_form_widgets* out, char* err,
                                size_t err_len) {
    pdf_document* pdf;
    pdf_page* volatile page = NULL;
    pdf_annot* widget;
    int total = 0, order = 0;

    form_error(err, err_len, "");
    if (!out) return 0;
    memset(out, 0, sizeof(*out));
    if (!doc || page_index < 0 || page_index >= doc->page_count) {
        form_error(err, err_len, "Page index is out of range.");
        return 0;
    }
    pdf = pdf_specifics(doc->ctx, doc->doc);
    if (!pdf) return 1;
    fz_try(doc->ctx) {
        const char* tabs;
        page = pdf_load_page(doc->ctx, pdf, page_index);
        tabs = pdf_to_name(doc->ctx, pdf_dict_gets(doc->ctx, page->obj, "Tabs"));
        out->tabs = (tabs[0] == 'R' || tabs[0] == 'C' || tabs[0] == 'S') ? tabs[0] : 0;
        for (widget = pdf_first_widget(doc->ctx, page); widget; widget = pdf_next_widget(doc->ctx, widget)) ++total;
        if (total > 0) {
            out->items = (spdf_form_widget*)calloc((size_t)total, sizeof(spdf_form_widget));
            if (!out->items) fz_throw(doc->ctx, FZ_ERROR_SYSTEM, "Out of memory");
        }
        for (widget = pdf_first_widget(doc->ctx, page); widget && out->count < total;
             widget = pdf_next_widget(doc->ctx, widget)) {
            spdf_form_widget* item = &out->items[out->count];
            int kept;
            out->count++; /* counted before reading, so a throw frees what was read */
            kept = read_widget(doc->ctx, widget, page_index, order, item);
            if (!kept) {
                free_widget(item);
                out->count--;
            } else {
                order++;
            }
        }
    }
    fz_always(doc->ctx) pdf_drop_page(doc->ctx, page);
    fz_catch(doc->ctx) {
        form_error(err, err_len, fz_caught_message(doc->ctx));
        spdf_free_form_widgets(out);
        return 0;
    }
    return 1;
}

/* -- setters ------------------------------------------------------------------------------------------------- */

/* Each widget under `node` shows `value` when it has an appearance by that name, else Off. */
static void put_button_states(fz_context* ctx, pdf_obj* node, pdf_obj* value, int depth) {
    pdf_obj* kids = pdf_dict_get(ctx, node, PDF_NAME(Kids));
    int i, n = pdf_array_len(ctx, kids);
    if (depth > FORM_DEPTH_CAP) return;
    if (pdf_dict_get(ctx, node, PDF_NAME(Subtype)) == PDF_NAME(Widget)) {
        int has = value != PDF_NAME(Off) && pdf_dict_get(ctx, pdf_dict_getp(ctx, node, "AP/N"), value);
        pdf_dict_put(ctx, node, PDF_NAME(AS), has ? value : PDF_NAME(Off));
    }
    for (i = 0; i < n; ++i) put_button_states(ctx, pdf_array_get(ctx, kids, i), value, depth + 1);
}

/* A checkbox or radio button on or off. MuPDF's own toggle gives every widget of the field the clicked one's state
 * name, so all buttons of a radio group showed as chosen; this keeps each widget to the states it has. A widget
 * without appearances of its own is left to MuPDF, which draws them. */
static void set_button(fz_context* ctx, pdf_annot* widget, int on) {
    pdf_obj* obj = pdf_annot_obj(ctx, widget);
    pdf_obj* field = spdf_form_field_of_widget(ctx, obj);
    pdf_obj* value = on ? pdf_button_field_on_state(ctx, obj) : PDF_NAME(Off);
    if (!pdf_is_dict(ctx, pdf_dict_getp(ctx, obj, "AP/N")) || !pdf_is_name(ctx, value)) {
        pdf_toggle_widget(ctx, widget);
        return;
    }
    pdf_dict_put(ctx, field, PDF_NAME(V), value);
    put_button_states(ctx, field, value, 0);
}

typedef enum { SET_TEXT, SET_ON, SET_CHOICE } form_set_mode;

void spdf_form_page_set_add(spdf_form_page_set* set, int page) {
    int i;
    if (page < 0) return;
    for (i = 0; i < set->count; ++i)
        if (set->pages[i] == page) return;
    if (set->count < SPDF_FORM_PAGE_SET_CAP) set->pages[set->count++] = page;
}

/* Every widget under `node` (the field itself, its widget kids, or child fields): its page joins `set`, and text
 * with Chinese characters tags it zh-Hans so the regenerated appearance gets a Chinese font. */
void spdf_form_visit_field_widgets(fz_context* ctx, pdf_document* pdf, pdf_obj* node, int depth, int han,
                                   spdf_form_page_set* set) {
    pdf_obj* kids = pdf_dict_get(ctx, node, PDF_NAME(Kids));
    int i, n = pdf_array_len(ctx, kids);
    if (depth > FORM_DEPTH_CAP) return;
    if (pdf_dict_get(ctx, node, PDF_NAME(Subtype)) == PDF_NAME(Widget)) {
        pdf_obj* page_obj = pdf_dict_get(ctx, node, PDF_NAME(P));
        fz_try(ctx) {
            if (page_obj) {
                spdf_form_page_set_add(set, pdf_lookup_page_number(ctx, pdf, page_obj));
            } else {
                /* /P is optional: the page whose annotations list the widget (a radio button on another page). */
                int p, count = pdf_count_pages(ctx, pdf);
                for (p = 0; p < count && p < FORM_PAGE_SCAN_CAP; ++p)
                    if (pdf_array_contains(ctx, pdf_dict_get(ctx, pdf_lookup_page_obj(ctx, pdf, p), PDF_NAME(Annots)),
                                           node)) {
                        spdf_form_page_set_add(set, p);
                        break;
                    }
            }
        }
        fz_catch(ctx) fz_ignore_error(ctx);
        if (han) pdf_dict_put_text_string(ctx, node, PDF_NAME(Lang), "zh-Hans");
    }
    for (i = 0; i < n; ++i) spdf_form_visit_field_widgets(ctx, pdf, pdf_array_get(ctx, kids, i), depth + 1, han, set);
}

static int form_set(spdf_document* doc, int page_index, int object_number, form_set_mode mode, const char* text,
                    int on, int* pages_changed, int max, char* err, size_t err_len) {
    pdf_document* pdf;
    pdf_page* volatile page = NULL;
    pdf_page* volatile other = NULL;
    spdf_form_page_set set;
    int i;

    form_error(err, err_len, "");
    memset(&set, 0, sizeof(set));
    if (!doc || page_index < 0 || page_index >= doc->page_count) {
        form_error(err, err_len, "Page index is out of range.");
        return -1;
    }
    pdf = pdf_specifics(doc->ctx, doc->doc);
    if (!pdf) {
        form_error(err, err_len, "Only PDF forms can be filled in.");
        return -1;
    }
    fz_try(doc->ctx) {
        fz_context* ctx = doc->ctx;
        pdf_annot* widget;
        pdf_obj *form, *field;
        enum pdf_widget_type type;
        int han = text && spdf_text_contains_han(text);
        if (!spdf_owner_allows(doc, FZ_PERMISSION_FORM) && !spdf_owner_allows(doc, FZ_PERMISSION_ANNOTATE))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "This PDF's owner doesn't allow filling it in.");
        page = pdf_load_page(ctx, pdf, page_index);
        for (widget = pdf_first_widget(ctx, page); widget; widget = pdf_next_widget(ctx, widget))
            if (pdf_to_num(ctx, pdf_annot_obj(ctx, widget)) == object_number) break;
        if (!widget) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This field is no longer on the page.");
        if (pdf_widget_is_readonly(ctx, widget) || pdf_widget_is_signed(ctx, widget))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "This field can't be changed");
        type = pdf_widget_type(ctx, widget);
        if (mode == SET_TEXT && type != PDF_WIDGET_TYPE_TEXT)
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "This field doesn't take text.");
        if (mode == SET_CHOICE && type != PDF_WIDGET_TYPE_COMBOBOX && type != PDF_WIDGET_TYPE_LISTBOX)
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "This field isn't a list of choices.");
        if (mode == SET_ON && type != PDF_WIDGET_TYPE_CHECKBOX && type != PDF_WIDGET_TYPE_RADIOBUTTON)
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "This field isn't a checkbox.");

        /* Other readers keep showing XFA data over the fields until it goes (as Preview and pdf.js do). */
        form = pdf_dict_getp(ctx, pdf_trailer(ctx, pdf), "Root/AcroForm");
        if (pdf_dict_get(ctx, form, PDF_NAME(XFA))) pdf_dict_del(ctx, form, PDF_NAME(XFA));
        field = spdf_form_field_of_widget(ctx, pdf_annot_obj(ctx, widget));
        spdf_form_note_original(ctx, pdf, field); /* what it held before Fill & Sign first changed it */
        spdf_form_page_set_add(&set, page_index);
        spdf_form_visit_field_widgets(ctx, pdf, field, 0, han && mode != SET_ON, &set);
        if (mode == SET_TEXT && !pdf_set_text_field_value(ctx, widget, text ? text : ""))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "This field doesn't accept that value.");
        if (mode == SET_CHOICE && !pdf_set_choice_field_value(ctx, widget, text ? text : ""))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "This field doesn't accept that value.");
        if (mode == SET_ON && widget_is_on(ctx, pdf_annot_obj(ctx, widget)) != (on != 0)) set_button(ctx, widget, on);

        /* Regenerate the appearance on every page holding a widget of this field. */
        for (i = 0; i < set.count; ++i) {
            if (set.pages[i] == page_index) {
                pdf_update_page(ctx, page);
                continue;
            }
            other = pdf_load_page(ctx, pdf, set.pages[i]);
            pdf_update_page(ctx, other);
            pdf_drop_page(ctx, other);
            other = NULL;
        }
    }
    fz_always(doc->ctx) {
        pdf_drop_page(doc->ctx, other);
        pdf_drop_page(doc->ctx, page);
    }
    fz_catch(doc->ctx) {
        form_error(err, err_len, fz_caught_message(doc->ctx));
        for (i = 0; i < set.count; ++i) spdf_drop_page_list_cache(doc, set.pages[i]);
        return -1;
    }
    /* ascending, for the caller's re-render order */
    for (i = 1; i < set.count; ++i) {
        int v = set.pages[i], j = i - 1;
        while (j >= 0 && set.pages[j] > v) {
            set.pages[j + 1] = set.pages[j];
            --j;
        }
        set.pages[j + 1] = v;
    }
    for (i = 0; i < set.count; ++i) {
        spdf_drop_page_list_cache(doc, set.pages[i]);
        if (pages_changed && i < max) pages_changed[i] = set.pages[i];
    }
    return set.count;
}

int spdf_form_set_text(spdf_document* doc, int page_index, int object_number, const char* utf8, int* pages_changed,
                       int max, char* err, size_t err_len) {
    return form_set(doc, page_index, object_number, SET_TEXT, utf8, 0, pages_changed, max, err, err_len);
}

int spdf_form_set_on(spdf_document* doc, int page_index, int object_number, int on, int* pages_changed, int max,
                     char* err, size_t err_len) {
    return form_set(doc, page_index, object_number, SET_ON, NULL, on, pages_changed, max, err, err_len);
}

int spdf_form_set_choice(spdf_document* doc, int page_index, int object_number, const char* utf8, int* pages_changed,
                         int max, char* err, size_t err_len) {
    return form_set(doc, page_index, object_number, SET_CHOICE, utf8, 0, pages_changed, max, err, err_len);
}
