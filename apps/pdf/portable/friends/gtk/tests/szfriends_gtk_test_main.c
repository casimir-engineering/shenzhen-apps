/* friends-gtk-check, display-free part: every snapshot and frame parsed, the structs against PROTOCOL.md, intents
 * from snapshots, drop classification, the animal set, and the link against the fake helper on the main loop.
 *
 * Usage: SZFriendsGtkTests <fixtures dir> <PROTOCOL.md> <szfriends-fake-helper> <animals manifest.json> */

#include "szfriends_gtk_support.h"

#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: %s <fixtures> <PROTOCOL.md> <fake helper> <manifest.json>\n", argv[0]);
        return 2;
    }
    /* Absolute, so a helper the tests spawn finds the fixtures whatever its working directory. */
    char *fixtures = realpath(argv[1], NULL), *fake = realpath(argv[3], NULL);
    if (!fixtures || !fake) {
        fprintf(stderr, "SZFriendsGtkTests: missing %s\n", fixtures ? argv[3] : argv[1]);
        return 2;
    }
    szfg_fixtures = fixtures;
    szfg_watch_logs();
    /* Tests choose every Friends variable themselves; none may come from the shell that ran make. */
    g_unsetenv("SZFRIENDS_AVATARS_MANIFEST");
    g_unsetenv(SZFRIENDS_ENV_KEY_STORE);
    szfg_run_snapshot_tests();
    szfg_run_protocol_coverage_tests(argv[2]);
    szfg_run_action_tests();
    szfg_run_drop_tests();
    szfg_run_avatar_data_tests(argv[4]);
    szfg_run_link_tests();
    szfg_run_reconnect_tests(fake);
    g_unsetenv(SZFRIENDS_ENV_STATE_DIR);
    free(fixtures);
    free(fake);
    EXPECT(szfg_unexpected_warnings() == 0, "no GLib or GTK warnings (%d)", szfg_unexpected_warnings());
    if (szfg_failures) {
        fprintf(stderr, "SZFriendsGtkTests: %d failure(s)\n", szfg_failures);
        return 1;
    }
    printf("SZFriendsGtkTests passed\n");
    return 0;
}
