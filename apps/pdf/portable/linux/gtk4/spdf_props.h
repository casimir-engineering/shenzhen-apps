// spdf_props.c — the document-properties panel (Ctrl+I), port of the Mac
// SPDFMacPropertiesPanel: a grouped read-only AdwDialog with a File group
// (location, size, format, dates), a Document group (metadata + security
// summary) and a Statistics group (page count, current-page size in
// pt/mm/in, outline + annotation counts). The value-formatting rules
// (PDF-date parsing, byte sizes, page-size strings, security summaries) are
// pure glib functions in spdf_props_internal.h, mirrored from
// SPDFMacPropertiesFormat.mm and unit-tested by tests/props_format_test.c.
//
// The Mac panel's Fonts group has no Linux counterpart: the portable core
// (shenzhen_pdf_core.h) exposes no font enumeration, so it is skipped.
#pragma once

#include "spdf_internal.h"
#include "spdf_window.h"

G_BEGIN_DECLS

// Registers win.properties on the window action map (replaces the Wave A
// stub). Called from spdf_window_init.
void spdf_props_install(SpdfWindow* win);

G_END_DECLS
