/* spdf_destination.h -- a PDF's named destinations: the ids a web page links into a document with
 * (#nameddest=<id>, or section=<id> in an szpdf: link, docs/szpdf-links.md). */
#ifndef SPDF_DESTINATION_H
#define SPDF_DESTINATION_H

#include "shenzhen_pdf_core.h"

#ifdef __cplusplus
extern "C" {
#endif

/* The 0-based page the destination named `name` points at, or -1 (no such destination, or not a PDF). */
int spdf_named_destination_page(spdf_document* doc, const char* name);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_DESTINATION_H */
