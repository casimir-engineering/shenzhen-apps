/* spdf_annot.c includes <unistd.h> for W_OK / X_OK; MSVC has no such header.
 * The two constants, so the g_access stub in glib.h has something to be
 * passed. For the annotations differential only. */
#ifndef SPDF_GLIB_SHIM_ANNOT_UNISTD_H
#define SPDF_GLIB_SHIM_ANNOT_UNISTD_H
#define W_OK 2
#define X_OK 1
#endif
