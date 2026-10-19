/* A stub <glib/gstdio.h> for the watcher differential: g_stat and g_access over
 * the CRT, plus the S_ISREG MSVC's <sys/stat.h> lacks. Serves the probing half
 * of spdf_watcher_logic.c, which compiles and is not compared. */
#ifndef SPDF_GLIB_SHIM_WATCHER_GSTDIO_H
#define SPDF_GLIB_SHIM_WATCHER_GSTDIO_H
#include <io.h>
#include <sys/stat.h>
#include <sys/types.h>
typedef struct _stat64 GStatBuf;
#define g_stat(path, buf) _stat64((path), (buf))
#define g_access(path, mode) _access((path), (mode))
#ifndef S_ISREG
#define S_ISREG(m) (((m) & _S_IFMT) == _S_IFREG)
#endif
#endif
