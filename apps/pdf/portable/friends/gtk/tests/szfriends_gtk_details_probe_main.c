/* friends-gtk-details-check, widget probes: a friend's details, your profile with the crop step and the QR, and the
 * Settings section, built by the real Friends button, dropdown and section against the fake helper, driven through
 * their handlers and rendered offscreen in light and dark. Needs a logged-in session for GDK's display; never maps a
 * window, never touches the clipboard or opens a dialog (szfg_outside stands in), and never launches either app.
 *
 * Usage: SZFriendsGtkDetailsProbes <fixtures dir> <animals manifest.json> <renders dir> */

#include "szfriends_gtk_details_probe.h"

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
        fprintf(stderr, "SZFriendsGtkDetailsProbes: the interposer is not active; not opening a display\n");
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
    /* Tests choose every Friends variable themselves: the animal set comes through the host's member. */
    g_unsetenv("SZFRIENDS_AVATARS_MANIFEST");
    if (!gtk_init_check()) {
        fprintf(stderr, "SZFriendsGtkDetailsProbes: no display; the widget probes need a logged-in session\n");
        return 1;
    }
    adw_init();
    szfg_set_dark(FALSE);
    szfg_clock_install(); /* arming and its expiry on the list's hand-moved clock, never real time */
    szfg_run_details_probes();
    szfg_run_profile_probes();
    szfg_run_settings_probes();
    szfg_run_title_probes();
    szfg_run_link_probes();
    szfg_run_device_probes();
    szfg_clock_uninstall();
    g_unsetenv(SZFRIENDS_ENV_STATE_DIR);
    EXPECT(szfg_unexpected_warnings() == 0, "no GLib, GTK or libadwaita warnings (%d)", szfg_unexpected_warnings());
    free(fixtures);
    free(manifest);
    if (szfg_failures) {
        fprintf(stderr, "SZFriendsGtkDetailsProbes: %d failure(s)\n", szfg_failures);
        return 1;
    }
    printf("SZFriendsGtkDetailsProbes passed\n");
    return 0;
}
