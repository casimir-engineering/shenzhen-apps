/* friends-gtk-check, widget probes: the icon, the button (badge, drop highlight, spring-loading, "Send 2 files
 * to…"), the dropdown shell and avatars, rendered offscreen to PNGs. Needs a logged-in session for GDK's display;
 * never maps a window and never launches either app.
 *
 * Usage: SZFriendsGtkProbes <fixtures dir> <animals manifest.json> <renders dir> */

#include "szfriends_gtk_probe.h"

#include <stdlib.h>
#ifdef __APPLE__
#include <ApplicationServices/ApplicationServices.h>
int szfriends_gtk_quiet_transform_calls(void); /* tests/szfriends_gtk_quiet.c */
#endif

/* Before GDK opens the display: prove the interposer will stop it from making this process a foreground app. */
static gboolean quiet_before_display(void) {
#ifdef __APPLE__
    int before = szfriends_gtk_quiet_transform_calls();
    TransformProcessType(NULL, 0); /* the real one refuses NULL and changes nothing */
    if (szfriends_gtk_quiet_transform_calls() != before + 1) {
        fprintf(stderr, "SZFriendsGtkProbes: the interposer is not active; not opening a display that would take "
                        "focus\n");
        return FALSE;
    }
#endif
    return TRUE;
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s <fixtures> <manifest.json> <renders>\n", argv[0]);
        return 2;
    }
    char *fixtures = realpath(argv[1], NULL), *manifest = realpath(argv[2], NULL);
    if (!fixtures || !manifest || !quiet_before_display()) return 2;
    szfg_fixtures = fixtures;
    szfg_manifest = manifest;
    szfg_renders = argv[3];
    g_mkdir_with_parents(szfg_renders, 0755);
    szfg_watch_logs();
    g_unsetenv("SZFRIENDS_AVATARS_MANIFEST");
    if (!gtk_init_check()) {
        fprintf(stderr, "SZFriendsGtkProbes: no display; the widget probes need a logged-in session\n");
        return 1;
    }
    adw_init();
#ifdef __APPLE__
    EXPECT(szfriends_gtk_quiet_transform_calls() >= 2, "GDK's own TransformProcessType was intercepted");
#endif
    szfg_run_icon_probes();
    szfg_run_button_probes();
    szfg_run_dropdown_probes();
    szfg_run_avatar_probes();
    szfg_run_route_probes();
    g_unsetenv(SZFRIENDS_ENV_STATE_DIR);
    EXPECT(szfg_unexpected_warnings() == 0, "no GLib, GTK or libadwaita warnings (%d)", szfg_unexpected_warnings());
    free(fixtures);
    free(manifest);
    if (szfg_failures) {
        fprintf(stderr, "SZFriendsGtkProbes: %d failure(s)\n", szfg_failures);
        return 1;
    }
    printf("SZFriendsGtkProbes passed\n");
    return 0;
}
