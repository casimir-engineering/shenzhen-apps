/* A stub <unistd.h> for the watcher differential: portable/linux/gtk4/
 * spdf_watcher_logic.c includes it for W_OK, which its probing half hands to
 * g_access(). MSVC has no such header; the probing functions compile against
 * this and are not compared (see glib_shim_watcher/glib.h). */
#ifndef SPDF_GLIB_SHIM_WATCHER_UNISTD_H
#define SPDF_GLIB_SHIM_WATCHER_UNISTD_H
#include <io.h>
#ifndef W_OK
#define W_OK 2
#endif
#endif
