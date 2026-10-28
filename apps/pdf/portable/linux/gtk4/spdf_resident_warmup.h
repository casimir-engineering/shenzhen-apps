// spdf_resident_warmup.h -- the --resident login start's warmup (spdf_resident_warmup.c): an idle callback taking a
// reference to the SpdfApp, scheduled from the command-line handler.
#pragma once

#include <glib.h>

gboolean spdf_resident_warmup_idle(gpointer app);
