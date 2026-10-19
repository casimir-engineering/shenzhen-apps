/* friends-gtk-list-check, display-free part: what each list row shows in every drag and fade state, from the
 * fixtures, and the arm-then-confirm rule on a clock the suite moves by hand.
 *
 * Usage: SZFriendsGtkListTests <fixtures dir> */

#include "szfriends_gtk_support.h"

#include "gtk/szfriends_gtk_row.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* ---- A clock moved by hand ----------------------------------------------------------------------- */

typedef struct {
    guint id, milliseconds;
    GSourceFunc func;
    gpointer data;
    gboolean cancelled, fired;
} SZFGTimer;

static gint64 now_us;
static GArray *timers;

static gint64 clock_now(gpointer data) {
    (void)data;
    return now_us;
}

static guint clock_schedule(guint milliseconds, GSourceFunc func, gpointer func_data, gpointer data) {
    (void)data;
    SZFGTimer timer = {timers->len + 1, milliseconds, func, func_data, FALSE, FALSE};
    g_array_append_val(timers, timer);
    return timer.id;
}

static void clock_cancel(guint id, gpointer data) {
    (void)data;
    if (id && id <= timers->len) g_array_index(timers, SZFGTimer, id - 1).cancelled = TRUE;
}

static SZFGTimer *last_timer(void) {
    return timers->len ? &g_array_index(timers, SZFGTimer, timers->len - 1) : NULL;
}

/* Runs a timer as the main loop would, unless it was cancelled: what a cancelled timer would have done is the bug. */
static void fire(SZFGTimer *timer) {
    if (!timer || timer->cancelled || timer->fired) return;
    timer->fired = TRUE;
    timer->func(timer->data);
}

/* ---- Fixtures ------------------------------------------------------------------------------------ */

static SZFriendsGtkListSnapshot *list_fixture(const char *name) {
    JsonObject *frame = szfg_fixture(name);
    SZFriendsGtkListSnapshot *list = frame ? szfriends_gtk_list_snapshot_parse(json_object_get_object_member(frame,
                                                                                                         "data"))
                                           : NULL;
    if (frame) json_object_unref(frame);
    return list;
}

static const SZFriendsGtkListRow *row(const SZFriendsGtkListSnapshot *list, const char *conversation_id) {
    for (gsize i = 0; list && i < list->n_rows; i++)
        if (!strcmp(list->rows[i].conversation_id, conversation_id)) return &list->rows[i];
    EXPECT(FALSE, "fixture row %s", conversation_id);
    return NULL;
}

static char *welcome_string(const char *key) {
    JsonObject *frame = szfg_fixture("frames/welcome.json");
    SZFriendsGtkWelcome *welcome = frame ? szfriends_gtk_welcome_parse(frame) : NULL;
    char *value = welcome && welcome->strings ? g_strdup(g_hash_table_lookup(welcome->strings, key)) : NULL;
    if (welcome) szfriends_gtk_welcome_free(welcome);
    if (frame) json_object_unref(frame);
    return value;
}

/* ---- What rows show ------------------------------------------------------------------------------ */

#define LOOK(id, drop, dimmed, hovered) szfriends_gtk_row_look(row(list, id), drop, dimmed, hovered, folders)
#define NO_DROP SZFRIENDS_GTK_ROW_DROP_NONE
#define ACCEPT SZFRIENDS_GTK_ROW_DROP_ACCEPT
#define REFUSE SZFRIENDS_GTK_ROW_DROP_REFUSE

static void test_looks(void) {
    SZFriendsGtkListSnapshot *list = list_fixture("snapshots/list.json");
    char *folders = welcome_string("drop_folders_refused");
    EXPECT(folders && *folders, "the welcome names why folders are refused");
    if (!list || !folders) return;
    SZFriendsGtkRowLook look = LOOK("c_lena", NO_DROP, FALSE, FALSE);
    EXPECT(look.right == SZFRIENDS_GTK_ROW_RIGHT_ACTIONS && look.waiting_bar && !look.waiting_pill &&
               !look.route_icon, "a request answers from the row, in place of its time, with the waiting bar");
    look = LOOK("c_lena", REFUSE, FALSE, FALSE);
    EXPECT(look.right == SZFRIENDS_GTK_ROW_RIGHT_PILL && look.pill_warning && !g_strcmp0(look.pill,
           "Lena isn’t your friend yet") && !look.waiting_bar, "files over a request: why not (%s)", look.pill);
    look = LOOK("c_lena", NO_DROP, TRUE, TRUE);
    EXPECT(look.right == SZFRIENDS_GTK_ROW_RIGHT_PILL && !g_strcmp0(look.pill, "Lena isn’t your friend yet"),
           "faded under the pointer while files wait: the same reason");
    look = LOOK("c_lena", NO_DROP, TRUE, FALSE);
    EXPECT(look.right == SZFRIENDS_GTK_ROW_RIGHT_ACTIONS, "faded without the pointer: only faded");
    look = LOOK("c_mei", NO_DROP, FALSE, FALSE);
    EXPECT(look.right == SZFRIENDS_GTK_ROW_RIGHT_TIME && look.unread_dot && look.route_icon && !look.waiting_pill &&
               !look.waiting_bar && !look.muted, "an unread friend: time, route icon, the dot");
    look = LOOK("c_mei", ACCEPT, FALSE, FALSE);
    EXPECT(look.right == SZFRIENDS_GTK_ROW_RIGHT_PILL && !look.pill_warning && !g_strcmp0(look.pill, "Send to Mei"),
           "files over a friend: %s", look.pill);
    look = LOOK("c_mei", REFUSE, FALSE, FALSE);
    EXPECT(look.right == SZFRIENDS_GTK_ROW_RIGHT_PILL && look.pill_warning && !g_strcmp0(look.pill, folders),
           "a folder over a friend: the helper's refusal (%s)", look.pill);
    look = szfriends_gtk_row_look(row(list, "c_mei"), REFUSE, FALSE, FALSE, "");
    EXPECT(look.right == SZFRIENDS_GTK_ROW_RIGHT_NOTHING && !look.pill, "no words from the helper: no invented ones");
    /* The list's header already says why (lead decision after wave 6c): the row's refuse style alone, never the
     * sentence twice; files it takes and a request's own reason are unchanged. */
    SZFriendsGtkRowFacts above = szfriends_gtk_row_facts(row(list, "c_mei"));
    above.refusal_above = TRUE;
    look = szfriends_gtk_row_look_for(&above, REFUSE, FALSE, FALSE, folders);
    EXPECT(look.right == SZFRIENDS_GTK_ROW_RIGHT_NOTHING && !look.pill && !look.waiting_bar,
           "refused under a header that says why: no pill (%s)", look.pill);
    look = szfriends_gtk_row_look_for(&above, ACCEPT, FALSE, FALSE, folders);
    EXPECT(!g_strcmp0(look.pill, "Send to Mei"), "files it takes still say where they go");
    above = szfriends_gtk_row_facts(row(list, "c_lena"));
    above.refusal_above = TRUE;
    look = szfriends_gtk_row_look_for(&above, REFUSE, FALSE, FALSE, folders);
    EXPECT(!g_strcmp0(look.pill, "Lena isn’t your friend yet"), "a request still says its own reason");
    look = LOOK("c_mei", NO_DROP, TRUE, TRUE);
    EXPECT(look.right == SZFRIENDS_GTK_ROW_RIGHT_TIME, "a friend who takes files never shows a refusal");
    look = LOOK("c_kenji", NO_DROP, FALSE, FALSE);
    EXPECT(look.right == SZFRIENDS_GTK_ROW_RIGHT_TIME && look.waiting_pill && look.waiting_bar && !look.route_icon,
           "an offer waiting: the pill in place of the route icon, and the bar");
    look = LOOK("c_kenji", ACCEPT, FALSE, FALSE);
    EXPECT(!look.waiting_bar, "the bar steps aside while files hover");
    look = LOOK("c_tulip", NO_DROP, FALSE, FALSE);
    EXPECT(look.id_check && look.route_icon, "an ID the Friends server confirmed carries the check");
    look = LOOK("c_jonas", NO_DROP, FALSE, FALSE);
    EXPECT(look.muted && !look.route_icon && look.right == SZFRIENDS_GTK_ROW_RIGHT_TIME,
           "someone blocked: muted, no route icon for route kind none");
    look = LOOK("c_jonas", REFUSE, FALSE, FALSE);
    EXPECT(look.right == SZFRIENDS_GTK_ROW_RIGHT_PILL && !g_strcmp0(look.pill, "You blocked Jonas"), "and says so");
    EXPECT(!LOOK("c_daniel", NO_DROP, FALSE, FALSE).muted, "a normal row is not muted");

    /* The badge counts rows waiting for an answer: exactly the rows drawing the waiting bar. */
    JsonObject *frame = szfg_fixture("snapshots/badge.json");
    SZFriendsGtkBadgeSnapshot *badge = szfriends_gtk_badge_snapshot_parse(json_object_get_object_member(frame, "data"));
    gint64 waiting = 0;
    for (gsize i = 0; i < list->n_rows; i++)
        waiting += szfriends_gtk_row_look(&list->rows[i], NO_DROP, FALSE, FALSE, folders).waiting_bar;
    EXPECT(waiting == badge->count, "waiting markers %" G_GINT64_FORMAT ", badge %" G_GINT64_FORMAT, waiting,
           badge->count);
    szfriends_gtk_badge_snapshot_free(badge);
    json_object_unref(frame);

    /* An action or icon this view does not know is hidden, and the row falls back to its time; a style it does not
     * know draws as normal. */
    JsonObject *odd = szfriends_gtk_json_object_from_text(
        "{\"rows\":[{\"conversation_id\":\"c_x\",\"title\":\"X\",\"style\":\"glowing\",\"route\":{\"kind\":\"local\","
        "\"method\":\"lan\",\"label\":\"Nearby\"},\"actions\":[{\"action\":\"poke\",\"icon\":\"accept\","
        "\"label\":\"Poke\",\"arm\":null},{\"action\":\"accept_request\",\"icon\":\"sparkle\",\"label\":\"Accept\","
        "\"arm\":null}]}]}", -1);
    SZFriendsGtkListSnapshot *strange = szfriends_gtk_list_snapshot_parse(odd);
    look = szfriends_gtk_row_look(&strange->rows[0], NO_DROP, FALSE, FALSE, folders);
    EXPECT(look.right == SZFRIENDS_GTK_ROW_RIGHT_TIME && !look.muted, "unknown actions, icons and styles hidden");
    szfriends_gtk_list_snapshot_free(strange);
    json_object_unref(odd);
    for (gsize i = 0; i < list->n_rows; i++)
        for (gsize j = 0; j < list->rows[i].n_actions; j++)
            EXPECT(szfriends_gtk_row_action_known(&list->rows[i].actions[j]), "the fixture's own actions are known");
    g_free(folders);
    szfriends_gtk_list_snapshot_free(list);
}

/* ---- Arming -------------------------------------------------------------------------------------- */

static int expirations;

static void expired(gpointer data) {
    (void)data;
    expirations++;
}

static void test_arming(void) {
    timers = g_array_new(FALSE, TRUE, sizeof(SZFGTimer));
    static const SZFriendsGtkClock clock = {clock_now, clock_schedule, clock_cancel, NULL};
    szfriends_gtk_set_clock(&clock);
    const gint64 ms = 1000, double_click = 400 * ms;
    EXPECT(szfriends_gtk_arm_accepts_confirm(0, 400 * ms, 1, double_click), "a single click after the interval");
    EXPECT(!szfriends_gtk_arm_accepts_confirm(0, 399 * ms, 1, double_click), "never within the double-click time");
    EXPECT(!szfriends_gtk_arm_accepts_confirm(0, 900 * ms, 2, double_click), "never the second click of a run");

    now_us = 100 * G_USEC_PER_SEC;
    SZFriendsGtkArming *arming = szfriends_gtk_arming_new();
    szfriends_gtk_arming_arm(arming, 4, expired, NULL);
    EXPECT(szfriends_gtk_arming_is_armed(arming) && last_timer() && last_timer()->milliseconds == 4000,
           "armed for the snapshot's 4 seconds");
    now_us += 100 * ms;
    EXPECT(!szfriends_gtk_arming_press_confirms(arming, 1, double_click) && szfriends_gtk_arming_is_armed(arming),
           "a press 100 ms later is half a double-click: still armed");
    now_us += 400 * ms;
    EXPECT(!szfriends_gtk_arming_press_confirms(arming, 2, double_click), "a second click of a run confirms nothing");
    EXPECT(szfriends_gtk_arming_press_confirms(arming, 1, double_click), "a deliberate second click confirms");
    EXPECT(szfriends_gtk_arming_disarm(arming) && last_timer()->cancelled && !szfriends_gtk_arming_disarm(arming),
           "disarming cancels the timer, once");

    szfriends_gtk_arming_arm(arming, 4, expired, NULL);
    fire(last_timer());
    EXPECT(expirations == 1 && !szfriends_gtk_arming_is_armed(arming), "the time passing turns the pill back");
    EXPECT(!szfriends_gtk_arming_press_confirms(arming, 1, double_click), "and a later click confirms nothing");

    szfriends_gtk_arming_arm(arming, 4, expired, NULL);
    SZFGTimer *first = last_timer();
    guint first_id = first->id;
    szfriends_gtk_arming_disarm(arming);
    szfriends_gtk_arming_arm(arming, 4, expired, NULL);
    EXPECT(g_array_index(timers, SZFGTimer, first_id - 1).cancelled, "an earlier arming's timer is cancelled");
    fire(&g_array_index(timers, SZFGTimer, first_id - 1));
    EXPECT(szfriends_gtk_arming_is_armed(arming) && expirations == 1, "so it changes nothing");
    fire(last_timer());
    EXPECT(!szfriends_gtk_arming_is_armed(arming) && expirations == 2, "the current one does");

    szfriends_gtk_arming_arm(arming, 0, expired, NULL);
    EXPECT(last_timer()->milliseconds == 1000, "a snapshot without a usable time still times out");
    szfriends_gtk_arming_arm(arming, -3, expired, NULL);
    EXPECT(last_timer()->milliseconds == 1000 && g_array_index(timers, SZFGTimer, timers->len - 2).cancelled,
           "arming again replaces the timer");
    szfriends_gtk_arming_arm(arming, 3600, expired, NULL);
    EXPECT(last_timer()->milliseconds == 60000, "an absurd time arms for a minute at most");
    szfriends_gtk_arming_arm(arming, NAN, expired, NULL);
    EXPECT(last_timer()->milliseconds == 1000, "no number at all arms for a second");
    szfriends_gtk_arming_arm(arming, 2.5, expired, NULL);
    EXPECT(last_timer()->milliseconds == 2500, "fractions of a second are kept");
    SZFGTimer *live = last_timer();
    szfriends_gtk_arming_free(arming);
    EXPECT(live->cancelled, "freeing an armed button cancels its timer");
    EXPECT(!szfriends_gtk_arming_is_armed(NULL) && !szfriends_gtk_arming_disarm(NULL), "NULL is never armed");
    szfriends_gtk_set_clock(NULL);
    g_array_unref(timers);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <fixtures>\n", argv[0]);
        return 2;
    }
    char *fixtures = realpath(argv[1], NULL);
    if (!fixtures) {
        fprintf(stderr, "SZFriendsGtkListTests: missing %s\n", argv[1]);
        return 2;
    }
    szfg_fixtures = fixtures;
    szfg_watch_logs();
    test_looks();
    test_arming();
    free(fixtures);
    EXPECT(szfg_unexpected_warnings() == 0, "no GLib or GTK warnings (%d)", szfg_unexpected_warnings());
    if (szfg_failures) {
        fprintf(stderr, "SZFriendsGtkListTests: %d failure(s)\n", szfg_failures);
        return 1;
    }
    printf("SZFriendsGtkListTests passed\n");
    return 0;
}
