#pragma once
/* Shared between spdf_form.c (fields, setters) and spdf_form_original.c (what the fields held before Fill & Sign). */
#include "mupdf/pdf.h"

enum { SPDF_FORM_PAGE_SET_CAP = 256 };

typedef struct spdf_form_page_set {
    int pages[SPDF_FORM_PAGE_SET_CAP];
    int count;
} spdf_form_page_set;

void spdf_form_page_set_add(spdf_form_page_set* set, int page);

/* The field a widget belongs to: itself when it carries /T, else the nearest ancestor that does. */
pdf_obj* spdf_form_field_of_widget(fz_context* ctx, pdf_obj* widget);

/* Every widget under `node`: its page joins `set`; han tags it zh-Hans so its new appearance gets a Chinese font. */
void spdf_form_visit_field_widgets(fz_context* ctx, pdf_document* pdf, pdf_obj* node, int depth, int han,
                                   spdf_form_page_set* set);

/* Called by the setters before a field's value changes: the first time, keeps what it held (spdf_form_original.c). */
void spdf_form_note_original(fz_context* ctx, pdf_document* pdf, pdf_obj* field);
