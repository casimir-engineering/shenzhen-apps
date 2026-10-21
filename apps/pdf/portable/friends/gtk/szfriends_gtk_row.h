/* Shenzhen Friends GTK views: a person's row in the list, Nearby and the send picker, its own Accept, Decline and
 * Block buttons, and the arm-then-confirm rule those buttons share with every Block in the dropdown (internal to
 * gtk/; mirrors mac/SZFriendsRowView.h, SZFriendsRowActions.m and SZFriendsArming.h).
 *
 * The row is one button and one drop target, so no part of it is a dead zone: avatar, name, the preview, the time
 * and the route icon (or the waiting pill) are drawn inside it; only its own buttons (Request in Nearby; Accept,
 * Decline and Block on a request) are separate targets. Strings come from snapshots and are set as plain text. */

#ifndef SZFRIENDS_GTK_ROW_H
#define SZFRIENDS_GTK_ROW_H

#include "gtk/szfriends_gtk_drops.h"

G_BEGIN_DECLS

/* ---- Time, for arming and the views' short-lived states -------------------------------------------- */

/* The main loop by default; tests install one they drive, so a 4 s pill is checked without waiting 4 s. */
typedef struct {
    gint64 (*now_us)(gpointer data);
    guint (*schedule)(guint milliseconds, GSourceFunc func, gpointer func_data, gpointer data);
    void (*cancel)(guint id, gpointer data);
    gpointer data;
} SZFriendsGtkClock;
void szfriends_gtk_set_clock(const SZFriendsGtkClock *clock); /* NULL: the main loop's again */
gint64 szfriends_gtk_clock_now(void);
guint szfriends_gtk_clock_schedule(guint milliseconds, GSourceFunc func, gpointer data);
void szfriends_gtk_clock_cancel(guint id);

/* ---- Arming (PROTOCOL.md action and row_action `arm`) ---------------------------------------------- */

/* Whether a press may confirm what was armed: never the second click of a double-click (n_press > 1) and never
 * within the double-click time of arming, which catches a fast double-click reported as two single clicks. WHY so
 * strict: Block cannot be undone from this Mac, and a habitual double-click must not arm and confirm at once. */
gboolean szfriends_gtk_arm_accepts_confirm(gint64 armed_at_us, gint64 pressed_at_us, int n_press,
                                           gint64 double_click_us);

typedef struct _SZFriendsGtkArming SZFriendsGtkArming;
SZFriendsGtkArming *szfriends_gtk_arming_new(void);
void szfriends_gtk_arming_free(SZFriendsGtkArming *arming);
gboolean szfriends_gtk_arming_is_armed(const SZFriendsGtkArming *arming);
/* The first press: armed for `seconds`, kept between 1 and 60 so a snapshot without a usable time, or an absurd one,
 * cannot arm for good; `expired` runs once if that passes unconfirmed. Only the latest arming's timer counts. Every
 * Block in the views arms through this, on this clock, so a double-click never confirms anywhere. */
void szfriends_gtk_arming_arm(SZFriendsGtkArming *arming, double seconds, void (*expired)(gpointer data),
                              gpointer data);
/* A later press: TRUE when it confirms. One that does not (half a double-click) leaves it armed. */
gboolean szfriends_gtk_arming_press_confirms(SZFriendsGtkArming *arming, int n_press, gint64 double_click_us);
gboolean szfriends_gtk_arming_disarm(SZFriendsGtkArming *arming); /* TRUE when it was armed */
/* The person's double-click time from the widget's GtkSettings, in microseconds; 400 ms without settings. */
gint64 szfriends_gtk_double_click_us(GtkWidget *widget);

/* ---- A request row's buttons (PROTOCOL.md list_row actions) ---------------------------------------- */

/* Known action and known icon: anything else is hidden (PROTOCOL.md § Principles). */
gboolean szfriends_gtk_row_action_known(const SZFriendsGtkRowAction *action);

typedef void (*SZFriendsGtkRowActionFunc)(GtkWidget *actions, SZFriendsGtkActionKind action, gpointer data);
GtkWidget *szfriends_gtk_row_actions_new(void);
/* Keeps the buttons, and an armed pill, when the actions are unchanged; otherwise rebuilds them. FALSE when none
 * remain. */
gboolean szfriends_gtk_row_actions_apply(GtkWidget *actions, const SZFriendsGtkRowAction *list, gsize count);
void szfriends_gtk_row_actions_set_handler(GtkWidget *actions, SZFriendsGtkRowActionFunc func, gpointer data);
gboolean szfriends_gtk_row_actions_is_armed(GtkWidget *actions);
gboolean szfriends_gtk_row_actions_disarm(GtkWidget *actions); /* TRUE when a pill turned back */
/* Sent and not yet answered: clicks do nothing, so a double click sends one answer. */
void szfriends_gtk_row_actions_set_busy(GtkWidget *actions, gboolean busy);
/* The row is faded (the send picker): no answers, and an armed pill turns back. */
void szfriends_gtk_row_actions_set_inactive(GtkWidget *actions, gboolean inactive);
/* For the suite: the button drawn with `icon`, and a click on it counted as the n_press-th of a run. */
GtkWidget *szfriends_gtk_row_actions_button(GtkWidget *actions, SZFriendsGtkRowIcon icon);
void szfriends_gtk_row_actions_click(GtkWidget *button, int n_press);

/* ---- The row ------------------------------------------------------------------------------------- */

typedef enum {
    SZFRIENDS_GTK_ROW_DROP_NONE,
    SZFRIENDS_GTK_ROW_DROP_ACCEPT, /* files over a row that takes them: "Send to Mei" */
    SZFRIENDS_GTK_ROW_DROP_REFUSE  /* a folder, a link or a special file, or files over a row that takes none */
} SZFriendsGtkRowDrop;

typedef enum {
    SZFRIENDS_GTK_ROW_RIGHT_NOTHING,
    SZFRIENDS_GTK_ROW_RIGHT_TIME,      /* time over the route icon or the waiting pill */
    SZFRIENDS_GTK_ROW_RIGHT_ACTIONS,   /* Accept, Decline, Block in place of the time */
    SZFRIENDS_GTK_ROW_RIGHT_ACCESSORY, /* Nearby: Request */
    SZFRIENDS_GTK_ROW_RIGHT_STATUS,    /* Nearby: "Friend", "Request sent" */
    SZFRIENDS_GTK_ROW_RIGHT_PILL       /* while dragging: "Send to Mei", or why not */
} SZFriendsGtkRowRight;

/* What a list row shows in a drag and fade state, decided without a display so the suite checks it from the
 * fixtures (szfriends_gtk_row_look.c). `refusal` is what a row that takes files says of the refused ones:
 * szfriends_gtk_drop_refusal (drop_folders_refused, or drop_not_a_file for links and special files). */
typedef struct {
    SZFriendsGtkRowRight right;
    gboolean waiting_bar, waiting_pill, unread_dot, route_icon, id_check, muted;
    const char *pill;        /* RIGHT_PILL: the text */
    gboolean pill_warning;   /* the warning colour: a refusal */
} SZFriendsGtkRowLook;
SZFriendsGtkRowLook szfriends_gtk_row_look(const SZFriendsGtkListRow *row, SZFriendsGtkRowDrop drop, gboolean dimmed,
                                           gboolean hovered, const char *refusal);
/* What the look depends on, kept by the row widget so a drag or a fade redraws without the snapshot. */
typedef struct {
    gboolean list_row, waiting, unread, id_confirmed, muted, has_actions, has_accessory, has_status;
    SZFriendsGtkRouteKind route;
    SZFriendsGtkRouteMethod route_method; /* picks the icon: szfriends_gtk_route_glyph */
    gboolean route_label;
    const char *drop_label, *drop_refusal; /* borrowed */
    gboolean refusal_above; /* the list's header already says why the files over the row are refused */
} SZFriendsGtkRowFacts;
SZFriendsGtkRowFacts szfriends_gtk_row_facts(const SZFriendsGtkListRow *row);
SZFriendsGtkRowLook szfriends_gtk_row_look_for(const SZFriendsGtkRowFacts *facts, SZFriendsGtkRowDrop drop,
                                               gboolean dimmed, gboolean hovered, const char *refusal);

typedef struct {
    void (*activated)(GtkWidget *row, gpointer data);                     /* a click or Return on the row */
    void (*action)(GtkWidget *row, SZFriendsGtkActionKind action, gpointer data); /* Accept, Decline, Block */
    void (*dropped)(GtkWidget *row, GPtrArray *items, gpointer data);     /* SZFriendsGtkHostItem *, borrowed */
    void (*accessory)(GtkWidget *row, gpointer data);                     /* Nearby's Request */
    /* An item of the row's menu was chosen: `index` into the list row's `menu` (PROTOCOL.md list_row). */
    void (*menu_chosen)(GtkWidget *row, guint index, gpointer data);
} SZFriendsGtkRowHandlers;

GtkWidget *szfriends_gtk_row_new(SZFriendsGtkLink *link);
void szfriends_gtk_row_set_handlers(GtkWidget *row, const SZFriendsGtkRowHandlers *handlers, gpointer data);
void szfriends_gtk_row_set_list_row(GtkWidget *row, const SZFriendsGtkListRow *list_row);
/* `action` is the person's Request (PROTOCOL.md nearby_person action), shown only when known. */
void szfriends_gtk_row_set_nearby_person(GtkWidget *row, const SZFriendsGtkNearbyPerson *person);
const char *szfriends_gtk_row_get_conversation_id(GtkWidget *row);
const char *szfriends_gtk_row_get_nearby_id(GtkWidget *row);
const char *szfriends_gtk_row_get_drop_label(GtkWidget *row); /* NULL: the row refuses drops */
/* Faded: the send picker's or a drag's rows that cannot receive files. */
void szfriends_gtk_row_set_dimmed(GtkWidget *row, gboolean dimmed);
/* The list's header shows a drop refusal (drop_folders_refused, drop_not_a_file): a row that takes files then shows
 * refused files with its refuse style alone, never the same sentence again. */
void szfriends_gtk_row_set_refusal_above(GtkWidget *row, gboolean refusal_above);
GtkWidget *szfriends_gtk_row_get_actions(GtkWidget *row);   /* NULL without row actions */
GtkWidget *szfriends_gtk_row_get_accessory(GtkWidget *row); /* NULL without Request */
SZFriendsGtkRowLook szfriends_gtk_row_get_look(GtkWidget *row);
/* The row's own labels and marks, for the suite: what they say and carry as tooltips. */
typedef enum {
    SZFRIENDS_GTK_ROW_PART_TITLE, SZFRIENDS_GTK_ROW_PART_SUBTITLE, SZFRIENDS_GTK_ROW_PART_TIME,
    SZFRIENDS_GTK_ROW_PART_WAITING, SZFRIENDS_GTK_ROW_PART_ROUTE, SZFRIENDS_GTK_ROW_PART_CHECK,
    SZFRIENDS_GTK_ROW_PART_STATUS, SZFRIENDS_GTK_ROW_PART_PILL,
    SZFRIENDS_GTK_ROW_PART_FOUND,      /* how someone nearby was found: its words ("Local network") */
    SZFRIENDS_GTK_ROW_PART_FOUND_ICONS /* and a box of route glyphs, one shown per method */
} SZFriendsGtkRowPart;
GtkWidget *szfriends_gtk_row_get_part(GtkWidget *row, SZFriendsGtkRowPart part);
/* The pointer left the row: an armed pill turns back, so "Block?" never waits under a pointer that went away. */
void szfriends_gtk_row_pointer_left(GtkWidget *row);
/* What the click gesture calls, open to the suite: a release activates the row only for the person who held it at
 * the press. Rows are reused by position, so a snapshot can move someone else under a held mouse button. */
void szfriends_gtk_row_press(GtkWidget *row);
void szfriends_gtk_row_release(GtkWidget *row, gboolean inside);
/* What the drop target calls, open to the suite so it can drive a drag without one. A drag belongs to the person
 * under it when it entered: once someone else holds the row, its highlight goes and the drop is refused. */
void szfriends_gtk_row_drag_enter(GtkWidget *row);
void szfriends_gtk_row_drag_value(GtkWidget *row, const GValue *value);
void szfriends_gtk_row_drag_leave(GtkWidget *row);
gboolean szfriends_gtk_row_drop(GtkWidget *row, const GValue *value);
SZFriendsGtkRowDrop szfriends_gtk_row_get_drop(GtkWidget *row);
void szfriends_gtk_row_activate(GtkWidget *row);
/* The row's menu (PROTOCOL.md list_row menu), opened by a right-click, a long press on a touch screen, the Menu key
 * or Shift+F10, pointing at (x, y) in the row, or at the whole row for negative x. FALSE when the row has no menu. */
gboolean szfriends_gtk_row_open_menu(GtkWidget *row, double x, double y);
GtkWidget *szfriends_gtk_row_get_menu(GtkWidget *row); /* the open menu's popover; NULL when none is open */
/* A key on the focused row, as its key controller sees it: Return and Space open, the Menu key and Shift+F10 open the
 * menu, and Delete chooses the menu's first item. TRUE when the key did something. */
gboolean szfriends_gtk_row_key(GtkWidget *row, guint keyval, GdkModifierType state);

G_END_DECLS

#endif /* SZFRIENDS_GTK_ROW_H */
