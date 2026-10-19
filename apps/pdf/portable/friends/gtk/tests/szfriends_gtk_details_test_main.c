/* friends-gtk-details-check, display-free part: the crop square and which photos the views decode, the arming rule,
 * the intents built from what was typed, and the QR encoder against libqrencode's symbols.
 *
 * Usage: SZFriendsGtkDetailsTests <fixtures dir> */

#include "szfriends_gtk_details_probe.h"

#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <fixtures>\n", argv[0]);
        return 2;
    }
    char *fixtures = realpath(argv[1], NULL);
    if (!fixtures) return 2;
    szfg_fixtures = fixtures;
    szfg_watch_logs();
    szfg_run_details_tests();
    szfg_run_qr_tests();
    free(fixtures);
    EXPECT(szfg_unexpected_warnings() == 0, "no GLib or GTK warnings (%d)", szfg_unexpected_warnings());
    if (szfg_failures) {
        fprintf(stderr, "SZFriendsGtkDetailsTests: %d failure(s)\n", szfg_failures);
        return 1;
    }
    printf("SZFriendsGtkDetailsTests passed\n");
    return 0;
}
