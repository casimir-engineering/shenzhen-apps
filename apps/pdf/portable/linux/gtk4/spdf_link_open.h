// spdf_link_open.h -- szpdf: links on Linux (docs/szpdf-links.md): the desktop entry registers
// x-scheme-handler/szpdf, so a link clicked in a browser reaches the command line as an argument.
//
// The link is read by the shared core (core/spdf_link.h): a refused one gets a short notice and nothing is fetched.
// An accepted one is kept under $XDG_DATA_HOME/shenzhenpdf/links/, so the same link comes back to the same file and
// opens offline once it has downloaded. Here the document downloads whole (curl, as the updater uses) and then opens
// at the page the link names; reading pages while they download is the macOS reader's.
#pragma once

#include "spdf_window.h"

gboolean spdf_link_open_is_link(const char* argument);
void spdf_link_open(SpdfWindow* win, const char* link);
