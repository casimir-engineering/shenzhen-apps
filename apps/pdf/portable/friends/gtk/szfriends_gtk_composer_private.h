/* Shenzhen Friends GTK views: the composer's state, shared by szfriends_gtk_composer.c (typing, sending, building)
 * and szfriends_gtk_composer_chips.c (chips, drafts, drops). Internal to the conversation's files. */

#ifndef SZFRIENDS_GTK_COMPOSER_PRIVATE_H
#define SZFRIENDS_GTK_COMPOSER_PRIVATE_H

#include "gtk/szfriends_gtk_conversation.h"

G_BEGIN_DECLS

struct _SZFriendsGtkComposerView {
    SZFriendsGtkConversation *conversation;
    GtkWidget *root; /* weak: replies arriving after it went change nothing */
    GtkWidget *note, *error, *chips, *input_box, *text_view, *placeholder, *hint, *send, *picker;
    GtkWidget *attach; /* Attach files: the paperclip beside Send */
    GtkTextBuffer *buffer;
    SZFriendsGtkDraft *draft, *own_draft;
    gboolean enabled, accepts_drops, sending, preedit, restoring;
    char *mention_note;
    SZFriendsGtkDropVerdict verdict;
};

/* U+FFFC, where an @ chip sits in the text (PROTOCOL.md § Mentions). */
#define SZFRIENDS_GTK_FFFC "\xEF\xBF\xBC"

void szfriends_gtk_composer_set_error(SZFriendsGtkComposerView *composer, const char *message);
/* The draft is the window's (szfriends_gtk_dropdown.h): text with U+FFFC per chip, the chips beside it. */
void szfriends_gtk_composer_save_draft(SZFriendsGtkComposerView *composer);
void szfriends_gtk_composer_restore_draft(SZFriendsGtkComposerView *composer);
/* The buffer as words and chips, for sending; `strings` keeps the words. */
GArray *szfriends_gtk_composer_pieces(SZFriendsGtkComposerView *composer, GPtrArray *strings);
/* The drop target that turns dropped files into chips. */
void szfriends_gtk_composer_add_drop_target(SZFriendsGtkComposerView *composer, GtkWidget *widget);

G_END_DECLS

#endif /* SZFRIENDS_GTK_COMPOSER_PRIVATE_H */
