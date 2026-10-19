/*
 * nautilus-launcher.c — tiny exec wrapper, the CFBundleExecutable of
 * Nautilus.app (PLAN.md §5 Phase 5 task 1).
 *
 * Resolves its own location inside the bundle at runtime, exports the GLib /
 * GTK runtime environment relative to Contents/Resources (mirroring the dev
 * run-nautilus.sh, but fully self-contained — no Homebrew paths), then execs
 * the real binary Contents/MacOS/nautilus.  Compiled (not a shell script) so
 * it works under `env -i` (no $PATH needed) and codesigns cleanly as the
 * bundle's main executable.
 */
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void
set_rel (const char *var, const char *base, const char *rel)
{
    char buf[PATH_MAX];

    snprintf (buf, sizeof buf, "%s/%s", base, rel);
    setenv (var, buf, 1);
}

int
main (int argc, char **argv)
{
    (void) argc;

    char raw[PATH_MAX];
    uint32_t size = sizeof raw;
    if (_NSGetExecutablePath (raw, &size) != 0)
    {
        fprintf (stderr, "nautilus-launcher: executable path too long\n");
        return 1;
    }

    char self[PATH_MAX];
    if (realpath (raw, self) == NULL)
    {
        perror ("nautilus-launcher: realpath");
        return 1;
    }

    /* self = <bundle>/Contents/MacOS/nautilus-launcher */
    char *slash = strrchr (self, '/');
    if (slash == NULL)
    {
        return 1;
    }
    *slash = '\0'; /* self = <bundle>/Contents/MacOS */

    char contents[PATH_MAX];
    slash = strrchr (self, '/');
    if (slash == NULL)
    {
        return 1;
    }
    snprintf (contents, sizeof contents, "%.*s", (int) (slash - self), self);

    char res[PATH_MAX];
    snprintf (res, sizeof res, "%s/Resources", contents);

    /* Data + schema search paths: bundle share only — self-contained. */
    set_rel ("XDG_DATA_DIRS", res, "share");
    set_rel ("GSETTINGS_SCHEMA_DIR", res, "share/glib-2.0/schemas");

    /* Nautilus data dir (tag-manager ontology for starring). The compile-time
     * NAUTILUS_DATADIR points at the build machine's install prefix; the
     * binary honors this override on darwin. */
    set_rel ("NAUTILUS_DATADIR", res, "share/nautilus");

    /* gdk-pixbuf loaders: the cache is written with paths relative to its own
     * directory (supported since gdk-pixbuf 2.40), so it survives relocation. */
    set_rel ("GDK_PIXBUF_MODULE_FILE", res, "lib/gdk-pixbuf-2.0/2.10.0/loaders.cache");
    set_rel ("GDK_PIXBUF_MODULEDIR", res, "lib/gdk-pixbuf-2.0/2.10.0/loaders");

    /* GIO modules (TLS backend). giomodule.cache stores basenames only. */
    set_rel ("GIO_MODULE_DIR", res, "lib/gio/modules");

    /* Homebrew pango links pangoft2 → fontconfig.  GTK4 on macOS uses the
     * CoreText fontmap so fontconfig is normally never initialized, but if
     * anything (e.g. librsvg rendering SVG <text>) does initialize it, point
     * it at our minimal bundled config instead of /opt/homebrew/etc/fonts. */
    set_rel ("FONTCONFIG_FILE", res, "etc/fonts/fonts.conf");

    /* Under env -i / Finder launch there is no locale; GLib then treats
     * filenames as US-ASCII and warns.  Default to UTF-8. */
    if (getenv ("LANG") == NULL)
    {
        setenv ("LANG", "en_US.UTF-8", 1);
    }

    char bin[PATH_MAX];
    snprintf (bin, sizeof bin, "%s/nautilus", self);

    argv[0] = bin;
    execv (bin, argv);
    perror ("nautilus-launcher: execv nautilus");
    return 127;
}
