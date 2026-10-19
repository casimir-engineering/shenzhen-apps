/* The hand-moved clock the list, conversation and details probes share (szfriends_gtk_list_probe_clock.h). */

#include "szfriends_gtk_list_probe_clock.h"

#include "gtk/szfriends_gtk_row.h"

SZFGClock szfg_clock;

static gint64 clock_now(gpointer data) {
    (void)data;
    return szfg_clock.now;
}

static guint clock_schedule(guint milliseconds, GSourceFunc func, gpointer func_data, gpointer data) {
    (void)data;
    SZFGTimer timer = {++szfg_clock.next_id, milliseconds, func, func_data, FALSE, FALSE};
    g_array_append_val(szfg_clock.timers, timer);
    return timer.id;
}

static void clock_cancel(guint id, gpointer data) {
    (void)data;
    for (guint i = 0; i < szfg_clock.timers->len; i++)
        if (g_array_index(szfg_clock.timers, SZFGTimer, i).id == id)
            g_array_index(szfg_clock.timers, SZFGTimer, i).cancelled = TRUE;
}

void szfg_clock_install(void) {
    if (!szfg_clock.timers) szfg_clock.timers = g_array_new(FALSE, TRUE, sizeof(SZFGTimer));
    szfg_clock.now = 1000 * G_USEC_PER_SEC;
    static const SZFriendsGtkClock clock = {clock_now, clock_schedule, clock_cancel, NULL};
    szfriends_gtk_set_clock(&clock);
}

void szfg_clock_uninstall(void) {
    szfriends_gtk_set_clock(NULL);
    g_clear_pointer(&szfg_clock.timers, g_array_unref);
}

void szfg_clock_advance_ms(gint64 milliseconds) {
    szfg_clock.now += milliseconds * 1000;
}

guint szfg_clock_live(guint milliseconds) {
    guint live = 0;
    for (guint i = 0; i < szfg_clock.timers->len; i++) {
        SZFGTimer *timer = &g_array_index(szfg_clock.timers, SZFGTimer, i);
        if (!timer->cancelled && !timer->fired && timer->milliseconds == milliseconds) live++;
    }
    return live;
}

gboolean szfg_clock_fire(guint milliseconds) {
    for (guint i = szfg_clock.timers->len; i > 0; i--) {
        SZFGTimer *timer = &g_array_index(szfg_clock.timers, SZFGTimer, i - 1);
        if (timer->cancelled || timer->fired || timer->milliseconds != milliseconds) continue;
        timer->fired = TRUE;
        GSourceFunc func = timer->func;
        gpointer data = timer->data;
        szfg_clock.now += (gint64)milliseconds * 1000;
        func(data); /* may schedule more, moving the array */
        return TRUE;
    }
    return FALSE;
}
