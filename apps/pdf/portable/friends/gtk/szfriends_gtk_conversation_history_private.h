/* Shenzhen Friends GTK views: the history's state, shared by szfriends_gtk_conversation_history.c (rows, snapshots,
 * following the end) and szfriends_gtk_conversation_history_input.c (the person's presses, scrolling and drops).
 * Internal to the conversation's files. */

#ifndef SZFRIENDS_GTK_CONVERSATION_HISTORY_PRIVATE_H
#define SZFRIENDS_GTK_CONVERSATION_HISTORY_PRIVATE_H

#include "gtk/szfriends_gtk_conversation.h"

G_BEGIN_DECLS

struct _SZFriendsGtkHistory {
    SZFriendsGtkConversation *conversation;
    GtkWidget *root, *scroller, *list_view, *drop_mark, *drop_words;
    GListStore *store;
    guint subscription;
    gboolean has_earlier, loading_earlier, accepts_drops;
    gboolean following;      /* at the end and staying there, as items arrive and as rows are measured */
    gboolean scrollbar_held; /* the person's own moves: wheel and trackpad up, the scrollbar, keys */
    gint64 keyed_at;
    double last_value;
    char *scrolled_highlight;
    SZFriendsGtkDropVerdict verdict;
    GtkWidget *pill;       /* "3 new messages ↓" over the bottom */
    char *newest_id;       /* the newest item of the last snapshot */
    char *first_unseen;    /* the first of the friend's items that arrived below while scrolled up */
    guint unseen;
    /* While a mouse button or a finger is down on the history, a changed item keeps its row: rebuilding it under the
     * press (a transfer's progress ticks several times a second) took the button away before the release, so Cancel
     * was lost. The rows held back are brought up to date from the latest items as soon as the press ends. */
    gboolean pressed;
    JsonObject *held_data; /* the latest snapshot's data while rows are held back */
    guint held_flush, press_limit;
};

/* Adds the controllers that watch the person's hands: presses on the rows, their own scrolling, drops. */
void szfriends_gtk_history_watch(SZFriendsGtkHistory *history);
/* A key down in the history in the last half second (Page Up, Tab to a row above), or the scrollbar held: the list
 * view moving now is the person's doing. Wheel and trackpad moves up stop following as they come. */
gboolean szfriends_gtk_history_person_moving(SZFriendsGtkHistory *history);

G_END_DECLS

#endif
