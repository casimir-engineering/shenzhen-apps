#pragma once
/* A PDF's own form fields (Fill & Sign, docs/plans/fill-and-sign.md, CORE 1).
 *
 * Coordinates are page space, as everywhere in the core: points, origin at the top left of the page as shown, y down,
 * page rotation applied (the same space as spdf_load_comments bounds and spdf_rect elsewhere).
 *
 * Threading: like every spdf_document call, one thread per document. Reads (summary, page widgets) belong on a worker
 * document; the setters write the main-thread document, which the caller then saves with spdf_save_document.
 * Nothing here runs JavaScript: MuPDF's JS engine is never enabled, so calculated fields stay as they are. */
#include "shenzhen_pdf_core.h"

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum spdf_form_kind {
    SPDF_FORM_NONE = 0,        /* no field anyone can fill (no AcroForm, or an empty Fields array) */
    SPDF_FORM_FILLABLE = 1,    /* at least one field to fill: switch Fill & Sign on for this tab */
    SPDF_FORM_SIGNED_ONLY = 2, /* only signature fields that are already signed */
    SPDF_FORM_XFA_ONLY = 3     /* an XFA form with no fillable AcroForm field; placed items still work */
} spdf_form_kind;

typedef struct spdf_form_summary {
    spdf_form_kind kind;
    int fillable_count;           /* text, checkbox, radio and choice fields not read-only, plus unsigned signatures */
    int required_count;           /* of those, the ones marked required */
    int signed_count;             /* signature fields already signed */
    int unsigned_signature_count; /* signature fields still to sign (counted in fillable_count too) */
    int has_xfa;                  /* /AcroForm/XFA present (removed on the first fill) */
    int incremental_ok;           /* an incremental save keeps existing signatures valid */
    int docmdp;                   /* certification level from /Perms/DocMDP: 0 none, 1 no changes, 2 fields only, 3 */
    int can_fill_fields;          /* the owner allows filling fields (permission 'f') */
    int can_add_items;            /* the owner allows placing text, marks and signatures (permission 'n') */
    int truncated;                /* the walk stopped at its node cap; counts are lower bounds */
} spdf_form_summary;

/* Reads Root/AcroForm/Fields and their /Kids (capped at 4096 nodes) without loading any page. Cheap: meant to ride on
 * a document open that already happens after first paint. A non-PDF document reads as SPDF_FORM_NONE with
 * can_add_items 0. Returns 1, or 0 with err. */
int spdf_form_summary_read(spdf_document* doc, spdf_form_summary* out, char* err, size_t err_len);

typedef enum spdf_field_type {
    SPDF_FIELD_TEXT = 0,
    SPDF_FIELD_CHECKBOX = 1,
    SPDF_FIELD_RADIO = 2,
    SPDF_FIELD_COMBO = 3,
    SPDF_FIELD_LIST = 4,
    SPDF_FIELD_SIGNATURE = 5
} spdf_field_type;

enum {
    SPDF_FIELD_READ_ONLY = 1 << 0,
    SPDF_FIELD_REQUIRED = 1 << 1,
    SPDF_FIELD_MULTILINE = 1 << 2,
    SPDF_FIELD_COMB = 1 << 3,
    SPDF_FIELD_ON = 1 << 4,             /* checkbox or radio widget currently on */
    SPDF_FIELD_SIGNED = 1 << 5,         /* signature field already signed */
    SPDF_FIELD_EDITABLE_COMBO = 1 << 6, /* combo that also takes typed text */
    SPDF_FIELD_HIDDEN = 1 << 7,         /* hidden or no-view widget: draw nothing, skip in Tab order */
    SPDF_FIELD_MULTI_SELECT = 1 << 8    /* list box allowing several choices (only the first is set by Fill & Sign) */
};

typedef struct spdf_form_widget {
    int page_index;
    int object_number; /* the widget annotation's object number: the handle every setter takes */
    int group_id;      /* object number of the field it belongs to; radio buttons of one group share it */
    int tab_index;     /* position among the page's fields, in /Annots order */
    spdf_rect rect;    /* page space */
    spdf_field_type type;
    unsigned flags;    /* SPDF_FIELD_* */
    int max_len;       /* text: MaxLen, 0 = none; comb fields have one cell per character */
    float font_size;   /* from /DA; 0 = fit the height */
    char* name;        /* fully qualified field name (UTF-8) */
    char* label;       /* /TU tooltip when present, else the name: the best hint for suggestions */
    char* value;       /* text and choice: current value; checkbox/radio: this widget's on-state name */
    int option_count;  /* combo and list */
    char** options;    /* display values, option_count of them */
    char** export_values; /* export values, option_count of them (same as options when the field has none) */
} spdf_form_widget;

typedef struct spdf_form_widgets {
    spdf_form_widget* items;
    int count;
    char tabs; /* the page's /Tabs: 'R' rows, 'C' columns, 'S' structure, 0 none (use rows, then x) */
} spdf_form_widgets;

/* Every widget on one page, in /Annots order. Returns 1, or 0 with err (out is then empty). */
int spdf_form_load_page_widgets(spdf_document* doc, int page_index, spdf_form_widgets* out, char* err, size_t err_len);
void spdf_free_form_widgets(spdf_form_widgets* widgets);

/* Setters. `object_number` is spdf_form_widget.object_number on `page_index`. Each refuses read-only fields and
 * signed signature fields, removes /AcroForm/XFA the first time (so other readers show the new value), tags text with
 * Chinese characters as zh-Hans so MuPDF picks a Chinese font, regenerates the appearance of every widget of the field
 * and drops the core's cached page drawings for each page that holds one.
 *
 * pages_changed receives the zero-based pages whose drawing changed (a radio group or a field with several widgets can
 * span pages), at most `max` of them, ascending. Returns how many pages changed (>= 1), or -1 with err. The caller
 * saves with spdf_save_document. */
int spdf_form_set_text(spdf_document* doc, int page_index, int object_number, const char* utf8, int* pages_changed,
                       int max, char* err, size_t err_len);
/* Checkbox or radio: on = 1 turns this widget on (and, for a radio, its siblings off); 0 turns it off. */
int spdf_form_set_on(spdf_document* doc, int page_index, int object_number, int on, int* pages_changed, int max,
                     char* err, size_t err_len);
/* Combo or list: utf8 is one of the display values, or any text for an editable combo. */
int spdf_form_set_choice(spdf_document* doc, int page_index, int object_number, const char* utf8, int* pages_changed,
                         int max, char* err, size_t err_len);

#ifdef __cplusplus
}
#endif
