/* friends-gtk-list-check, widget probes: the list and Nearby pages built by the real button and dropdown against the
 * fake helper, driven through their own handlers and rendered offscreen. Shares the core suite's helpers
 * (szfriends_gtk_probe.h); never maps a window, never writes the clipboard, never opens System Settings. */

#ifndef SZFRIENDS_GTK_LIST_PROBE_H
#define SZFRIENDS_GTK_LIST_PROBE_H

#include "szfriends_gtk_list_probe_clock.h"
#include "szfriends_gtk_probe.h"

#include "gtk/szfriends_gtk_list_page.h"

/* What left through the seams: the last copied text and opened address. */
extern char *szfg_copied, *szfg_opened;

/* One window's Friends button and its dropdown, recorded instead of shown, opened on the list with its rows in. */
typedef struct {
    SZFGHarness *harness;
    GtkWidget *window, *anchor;
    SZFriendsGtkDropdown *dropdown;
    SZFriendsGtkPage *page;
    const SZFriendsGtkListParts *parts;
} SZFGList;
SZFGList *szfg_list_open(SZFGHarness *harness);
void szfg_list_close(SZFGList *list);
gboolean szfg_list_wait_rows(SZFGList *list, guint rows);
/* Waits for a list snapshot after the `seen` ones (list->parts->list_snapshots read before scripting it). */
gboolean szfg_list_wait_snapshot(SZFGList *list, guint seen);
GtkWidget *szfg_list_row(SZFGList *list, const char *conversation_id);
/* Client frames of `type` the fake received so far, from every connection. */
guint szfg_frames(SZFGHarness *harness, const char *type);
/* The newest frame of `type`: its fields' `key` as a string, owned by the caller; NULL when none. */
char *szfg_last_field(SZFGHarness *harness, const char *type, const char *key);
/* Waits until the fake has received `count` frames of `type`. */
gboolean szfg_wait_frames(SZFGHarness *harness, const char *type, guint count);
/* Whether `widget`'s accessible label is `label` (GTK's test accessor). */
gboolean szfg_accessible_label_is(GtkWidget *widget, const char *label);

void szfg_run_list_row_probes(SZFGHarness *harness);
void szfg_run_list_page_probes(SZFGHarness *harness);
void szfg_run_list_nearby_probes(SZFGHarness *harness);
void szfg_run_list_renders(SZFGHarness *harness);
void szfg_run_list_reorder_probes(SZFGHarness *harness);
void szfg_run_list_live_probes(SZFGHarness *harness);
void szfg_run_list_route_probes(SZFGHarness *harness); /* szfriends_gtk_list_probe_routes.c */

#endif /* SZFRIENDS_GTK_LIST_PROBE_H */
