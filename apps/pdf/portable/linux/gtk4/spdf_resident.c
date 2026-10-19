// spdf_resident.c — login autostart entry for resident instant-launch mode
// (Wave D). Contract, provenance and the pure/live split in spdf_resident.h.

#include "spdf_resident.h"

#include <glib/gstdio.h>
#include <string.h>

/* ---------------------------------------------------------------------------
 * Pure logic (glib only). */

char* spdf_resident_autostart_exec(const char* self_path, const char* path_resolved) {
    const char* p;

    if (!self_path || !*self_path) return g_strdup(SPDF_RESIDENT_BINARY_NAME);
    /* The PATH-resolved name is preferred only when it IS this binary —
     * otherwise "shenzhenpdf" in PATH could be a different install and the
     * entry would silently launch the wrong one. */
    if (path_resolved && strcmp(path_resolved, self_path) == 0) return g_strdup(SPDF_RESIDENT_BINARY_NAME);
    /* Quote only when the path needs it (Exec values parse with shell-style
     * word splitting; plain absolute paths stay readable unquoted). */
    for (p = self_path; *p; ++p)
        if (!g_ascii_isalnum(*p) && !strchr("/_.+-", *p)) return g_shell_quote(self_path);
    return g_strdup(self_path);
}

char* spdf_resident_autostart_content(const char* exec_value) {
    if (!exec_value || !*exec_value) return NULL;
    return g_strdup_printf(
        "[Desktop Entry]\n"
        "Type=Application\n"
        "Name=Shenzhen PDF (Instant Launch)\n"
        "Comment=Starts Shenzhen PDF in the background so opening documents is instant\n"
        "Exec=%s --resident\n"
        "Terminal=false\n"
        "Hidden=false\n"
        "X-GNOME-Autostart-enabled=true\n",
        exec_value);
}

gboolean spdf_resident_autostart_stale(const char* existing_content, const char* exec_value) {
    char* expected;
    const char* pos;
    gboolean current = FALSE;

    if (!exec_value || !*exec_value) return FALSE; /* nothing sane to write */
    if (!existing_content || !*existing_content) return TRUE;
    expected = g_strdup_printf("%s --resident", exec_value);
    for (pos = existing_content; *pos && !current;) {
        const char* eol = strchr(pos, '\n');
        gsize len = eol ? (gsize)(eol - pos) : strlen(pos);
        if (len > 5 && strncmp(pos, "Exec=", 5) == 0) {
            char* value = g_strndup(pos + 5, len - 5);
            g_strchomp(value); /* tolerate trailing spaces / CR */
            current = strcmp(value, expected) == 0;
            g_free(value);
        }
        pos = eol ? eol + 1 : pos + len;
    }
    g_free(expected);
    return !current;
}

#ifndef SPDF_RESIDENT_TESTING

/* ---------------------------------------------------------------------------
 * Live half: the autostart file itself. */

static char* resident_autostart_path(void) {
    return g_build_filename(g_get_user_config_dir(), "autostart", SPDF_RESIDENT_AUTOSTART_FILE, NULL);
}

static char* resident_exec_value(void) {
    char* self_path = g_file_read_link("/proc/self/exe", NULL);
    char* path_resolved = g_find_program_in_path(SPDF_RESIDENT_BINARY_NAME);
    char* exec_value = spdf_resident_autostart_exec(self_path, path_resolved);

    g_free(path_resolved);
    g_free(self_path);
    return exec_value;
}

void spdf_resident_sync_autostart(gboolean enabled) {
    char* file_path;

    /* Inside Flatpak the sandboxed ~/.config/autostart is not the host's —
     * a file written there never runs at login, and the Exec value (a
     * sandbox path or bare binary name) would be wrong on the host anyway.
     * No-op entirely; wiring login autostart through the XDG Background
     * portal (org.freedesktop.portal.Background RequestBackground) is the
     * correct future implementation. */
    if (spdf_running_in_flatpak()) return;

    file_path = resident_autostart_path();

    if (!enabled) {
        if (g_file_test(file_path, G_FILE_TEST_EXISTS)) g_unlink(file_path);
    } else {
        char* exec_value = resident_exec_value();
        char* existing = NULL;

        g_file_get_contents(file_path, &existing, NULL, NULL); /* missing => NULL */
        if (spdf_resident_autostart_stale(existing, exec_value)) {
            char* dir = g_path_get_dirname(file_path);
            char* content = spdf_resident_autostart_content(exec_value);
            GError* error = NULL;

            g_mkdir_with_parents(dir, 0755);
            if (content && !g_file_set_contents(file_path, content, -1, &error)) {
                g_warning("shenzhenpdf: could not write %s: %s", file_path,
                          error ? error->message : "unknown error");
            }
            g_clear_error(&error);
            g_free(content);
            g_free(dir);
        }
        g_free(existing);
        g_free(exec_value);
    }
    g_free(file_path);
}

#endif /* SPDF_RESIDENT_TESTING */
