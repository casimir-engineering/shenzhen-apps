/* A clock the probes move by hand (szfriends_gtk_row.h's clock seam), shared by the list, conversation and details
 * probes, so every Block in the views is checked on one clock: a double-click time or an arm's expiry passes when the
 * probe says so, never by waiting real time. Timers are recorded and fired on demand, never by the main loop. */

#ifndef SZFRIENDS_GTK_LIST_PROBE_CLOCK_H
#define SZFRIENDS_GTK_LIST_PROBE_CLOCK_H

#include <glib.h>

typedef struct {
    gint64 now;
    GArray *timers; /* SZFGTimer */
    guint next_id;
} SZFGClock;
typedef struct {
    guint id, milliseconds;
    GSourceFunc func;
    gpointer data;
    gboolean cancelled, fired;
} SZFGTimer;
extern SZFGClock szfg_clock;
void szfg_clock_install(void);
void szfg_clock_uninstall(void); /* the main loop's clock again, and the record freed */
void szfg_clock_advance_ms(gint64 milliseconds);
/* The newest live timer scheduled for exactly `milliseconds`, fired; FALSE when there is none. */
gboolean szfg_clock_fire(guint milliseconds);
guint szfg_clock_live(guint milliseconds); /* live timers of that length */

#endif /* SZFRIENDS_GTK_LIST_PROBE_CLOCK_H */
