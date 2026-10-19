/* Shenzhen Friends GTK views: each window's dropdown and the pages in it (internal to gtk/; the pages' API).
 *
 * The shell mirrors mac/SZFriendsDropdownController.h (brief § Interface):
 *   - one dropdown per window, behind that window's button, in a GtkPopover with autohide off: it stays open while
 *     files are dragged in from Finder or another app, and closes on Escape, on a click on the button or on a click
 *     elsewhere in the window, which the shell handles itself;
 *   - an AdwNavigationView of pages: list -> conversation -> details, list -> profile or list -> join. Every page
 *     below the list has a back arrow at the top left (Cmd+[ too) carrying the waiting count, and its title centred;
 *   - Escape closes the innermost thing a page opened (a picker, an armed pill, an overlay) first, then the
 *     dropdown; it never navigates back;
 *   - per window: the page stack, drafts and scroll positions survive closing and reopening.
 * Pages are filled by builders registered per link (szfriends_gtk_register_page); the shell owns placement,
 * navigation, Escape and lifetimes. */

#ifndef SZFRIENDS_GTK_DROPDOWN_H
#define SZFRIENDS_GTK_DROPDOWN_H

#include "gtk/szfriends_gtk_link.h"

G_BEGIN_DECLS

typedef struct _SZFriendsGtkDropdown SZFriendsGtkDropdown;
typedef struct _SZFriendsGtkPage SZFriendsGtkPage;

typedef enum {
    SZFRIENDS_GTK_PAGE_LIST,         /* the root: Friends and Nearby tabs, footer */
    SZFRIENDS_GTK_PAGE_CONVERSATION, /* argument: conversation id */
    SZFRIENDS_GTK_PAGE_DETAILS,      /* argument: conversation id */
    SZFRIENDS_GTK_PAGE_PROFILE,
    SZFRIENDS_GTK_PAGE_SETTINGS,     /* the host's Settings section (szfriends_gtk_settings_section_new) */
    SZFRIENDS_GTK_PAGE_LINK,         /* argument: a link's payload (PROTOCOL.md § Links) */
    SZFRIENDS_GTK_PAGE_JOIN,         /* a new computer joining the person's profile (PROTOCOL.md § Joining) */
    SZFRIENDS_GTK_PAGE_KIND_COUNT
} SZFriendsGtkPageKind;

typedef struct {
    /* Fills the page once, when it is created: content, bars, title. */
    void (*build)(SZFriendsGtkPage *page, gpointer user_data);
    /* On screen or not (the dropdown open with this page on top, or the Settings section mapped). Subscribe here
     * and release here: open_conversation is held only while the conversation is on screen. Optional. */
    void (*presented)(SZFriendsGtkPage *page, gboolean presented, gpointer user_data);
    /* Escape with this page on top: TRUE when the page closed something of its own. Optional. */
    gboolean (*escape)(SZFriendsGtkPage *page, gpointer user_data);
    /* The page is going away. Optional. */
    void (*dispose)(SZFriendsGtkPage *page, gpointer user_data);
} SZFriendsGtkPageClass;

/* Registers the builder of every page of `kind` this link creates from now on, replacing the previous one. */
void szfriends_gtk_register_page(SZFriendsGtkLink *link, SZFriendsGtkPageKind kind,
                                 const SZFriendsGtkPageClass *page_class, gpointer user_data);

SZFriendsGtkPageKind szfriends_gtk_page_get_kind(SZFriendsGtkPage *page);
const char *szfriends_gtk_page_get_argument(SZFriendsGtkPage *page);   /* conversation id, or NULL */
const char *szfriends_gtk_page_get_message_id(SZFriendsGtkPage *page); /* message to highlight, or NULL */
SZFriendsGtkLink *szfriends_gtk_page_get_link(SZFriendsGtkPage *page);
SZFriendsGtkDropdown *szfriends_gtk_page_get_dropdown(SZFriendsGtkPage *page); /* NULL for SETTINGS */
GtkWidget *szfriends_gtk_page_get_widget(SZFriendsGtkPage *page); /* the AdwNavigationPage, or the section */
gboolean szfriends_gtk_page_is_presented(SZFriendsGtkPage *page);
void szfriends_gtk_page_set_content(SZFriendsGtkPage *page, GtkWidget *content);
void szfriends_gtk_page_add_top_bar(SZFriendsGtkPage *page, GtkWidget *bar);    /* below the header */
void szfriends_gtk_page_add_bottom_bar(SZFriendsGtkPage *page, GtkWidget *bar); /* composer, footer */
/* The centred title, plain text; a subtitle under it (the route line), NULL for none. */
void szfriends_gtk_page_set_title(SZFriendsGtkPage *page, const char *title, const char *subtitle);
/* The page's name for the navigation view and assistive technology (also set by set_title); NULL or "" names it
 * after the Friends button, or the connection line while no helper has answered, so it is never empty. */
void szfriends_gtk_page_set_name(SZFriendsGtkPage *page, const char *name);
/* Replaces the centred title with a widget (a clickable name, the list's search field). */
void szfriends_gtk_page_set_title_widget(SZFriendsGtkPage *page, GtkWidget *widget);
/* The back arrow's waiting count and accessible name (PROTOCOL.md type.back); NULL clears the count. */
void szfriends_gtk_page_set_back(SZFriendsGtkPage *page, const SZFriendsGtkBack *back);
GtkWidget *szfriends_gtk_page_get_back_button(SZFriendsGtkPage *page); /* NULL on the list and Settings */
void szfriends_gtk_page_set_data(SZFriendsGtkPage *page, gpointer data, GDestroyNotify destroy);
gpointer szfriends_gtk_page_get_data(SZFriendsGtkPage *page);

/* ---- The dropdown --------------------------------------------------------------------------------- */

SZFriendsGtkDropdown *szfriends_gtk_dropdown_for_button(GtkWidget *button);
SZFriendsGtkLink *szfriends_gtk_dropdown_get_link(SZFriendsGtkDropdown *dropdown);
GtkWindow *szfriends_gtk_dropdown_get_window(SZFriendsGtkDropdown *dropdown);
/* The shell inside the popover: created on first open, never at install, so launch pays for one button. */
GtkWidget *szfriends_gtk_dropdown_get_content(SZFriendsGtkDropdown *dropdown);
gboolean szfriends_gtk_dropdown_is_open(SZFriendsGtkDropdown *dropdown);
void szfriends_gtk_dropdown_open(SZFriendsGtkDropdown *dropdown);
void szfriends_gtk_dropdown_close(SZFriendsGtkDropdown *dropdown);
void szfriends_gtk_dropdown_toggle(SZFriendsGtkDropdown *dropdown);
/* Escape as the shell handles it: an overlay first, then the top page's own, then closing. */
void szfriends_gtk_dropdown_escape(SZFriendsGtkDropdown *dropdown);

/* Navigation. Opening a conversation resets the stack to the list and it, so the back arrow always leads to the
 * list; the same conversation on top only highlights `message_id`. */
void szfriends_gtk_dropdown_open_conversation(SZFriendsGtkDropdown *dropdown, const char *conversation_id,
                                              const char *message_id);
void szfriends_gtk_dropdown_open_details(SZFriendsGtkDropdown *dropdown, const char *conversation_id);
void szfriends_gtk_dropdown_open_profile(SZFriendsGtkDropdown *dropdown);
/* The link page on top of the list, for a payload the host checked (szfriends_gtk.h § Links). */
void szfriends_gtk_dropdown_open_link(SZFriendsGtkDropdown *dropdown, const char *payload);
/* The join page on top of the list (the name prompt's "Use my existing profile"). */
void szfriends_gtk_dropdown_open_join(SZFriendsGtkDropdown *dropdown);
void szfriends_gtk_dropdown_go_back(SZFriendsGtkDropdown *dropdown);
void szfriends_gtk_dropdown_pop_to_list(SZFriendsGtkDropdown *dropdown);
SZFriendsGtkPage *szfriends_gtk_dropdown_get_top_page(SZFriendsGtkDropdown *dropdown);
guint szfriends_gtk_dropdown_get_depth(SZFriendsGtkDropdown *dropdown); /* 1 on the list */

/* Per-window state kept across closing and reopening. */
typedef struct {
    char *text;
    GPtrArray *items; /* SZFriendsGtkHostItem *: attachment chips */
} SZFriendsGtkDraft;
SZFriendsGtkDraft *szfriends_gtk_dropdown_get_draft(SZFriendsGtkDropdown *dropdown, const char *conversation_id);
double szfriends_gtk_dropdown_get_scroll(SZFriendsGtkDropdown *dropdown, const char *key);
void szfriends_gtk_dropdown_set_scroll(SZFriendsGtkDropdown *dropdown, const char *key, double value);

/* "Send 2 files to…": files released on the button wait for the friend clicked next; Escape or closing cancels. */
void szfriends_gtk_dropdown_begin_send_picker(SZFriendsGtkDropdown *dropdown, GPtrArray *items);
GPtrArray *szfriends_gtk_dropdown_get_send_items(SZFriendsGtkDropdown *dropdown); /* NULL when not picking */
const char *szfriends_gtk_dropdown_get_send_title(SZFriendsGtkDropdown *dropdown);
void szfriends_gtk_dropdown_finish_send_picker(SZFriendsGtkDropdown *dropdown);
/* While files hover over the button: drop_hint, or the folder refusal. NULL clears it. */
void szfriends_gtk_dropdown_set_drop_hint(SZFriendsGtkDropdown *dropdown, const char *hint);
const char *szfriends_gtk_dropdown_get_drop_hint(SZFriendsGtkDropdown *dropdown);
/* Runs `func` after the send picker or the drop hint changed, so the list can show them. */
guint szfriends_gtk_dropdown_add_watch(SZFriendsGtkDropdown *dropdown, GCallback func, gpointer user_data);
void szfriends_gtk_dropdown_remove_watch(SZFriendsGtkDropdown *dropdown, guint watch);

/* A card over the pages (a confirmation); Escape or a new overlay removes it first. NULL removes the current. */
void szfriends_gtk_dropdown_set_overlay(SZFriendsGtkDropdown *dropdown, GtkWidget *overlay);
GtkWidget *szfriends_gtk_dropdown_get_overlay(SZFriendsGtkDropdown *dropdown);

/* How the dropdown appears: the button's popover in the app; tests record instead, so nothing reaches the screen.
 * `dismiss` must end with szfriends_gtk_dropdown_presenter_closed(). */
typedef struct {
    void (*present)(SZFriendsGtkDropdown *dropdown, gpointer data);
    void (*dismiss)(SZFriendsGtkDropdown *dropdown, gpointer data);
} SZFriendsGtkPresenter;
void szfriends_gtk_dropdown_set_presenter(SZFriendsGtkDropdown *dropdown, const SZFriendsGtkPresenter *presenter,
                                          gpointer data);
void szfriends_gtk_dropdown_presenter_closed(SZFriendsGtkDropdown *dropdown);

/* The dropdown's height for the space below the button: it fits the window, at least 280, at most `max_height`. */
int szfriends_gtk_dropdown_height(int space_below_button, int max_height);

G_END_DECLS

#endif /* SZFRIENDS_GTK_DROPDOWN_H */
