/* Shenzhen Friends GTK views: the dropdown's root page, the Friends and Nearby tabs, the footer under both, and what
 * every page shares (internal to gtk/; mirrors mac/SZFriendsListPage.h, SZFriendsNearbyPane.m, SZFriendsFooterView.m
 * and SZFriendsContext.m).
 *
 * The list page: the search field (the header's title widget), Friends / Nearby, then above the rows "Send 2 files
 * to…" or the drop hint, the banner and the name field while no name is chosen, the rows sorted by the helper, and
 * the footer: the name friends see (edited in place), Your ID with Copy, the note while the ID is unreserved, and Add
 * by ID. Only the visible tab is subscribed, and only while the page is on screen. */

#ifndef SZFRIENDS_GTK_LIST_PAGE_H
#define SZFRIENDS_GTK_LIST_PAGE_H

#include "gtk/szfriends_gtk_actions.h"
#include "gtk/szfriends_gtk_dropdown.h"
#include "gtk/szfriends_gtk_row.h"

G_BEGIN_DECLS

/* The builder pages_builtin.c registers for SZFRIENDS_GTK_PAGE_LIST. */
extern const SZFriendsGtkPageClass szfriends_gtk_list_page_class;

/* ---- Shared by every page (szfriends_gtk_list_support.c) ------------------------------------------ */

/* What leaves the views: the clipboard, URIs (System Settings), Settings' confirmation dialog and the image chooser.
 * One table for every page; the suites replace it, so no test writes the person's clipboard or opens a window or a
 * dialog. NULL members, or a NULL table, mean the system's own. */
typedef void (*SZFriendsGtkRun)(gpointer data);
typedef void (*SZFriendsGtkChosen)(const char *path, gpointer data); /* path NULL: cancelled */
typedef struct {
    void (*copy_text)(GtkWidget *source, const char *text, gpointer data);
    void (*open_uri)(GtkWidget *source, const char *uri, gpointer data);
    /* Outside a dropdown (Settings): ask, then call run(run_data) only on the confirm button; run_destroy once. */
    void (*confirm)(GtkWidget *source, const SZFriendsGtkConfirm *confirm, gboolean destructive, SZFriendsGtkRun run,
                    gpointer run_data, GDestroyNotify run_destroy, gpointer data);
    void (*choose_image)(GtkWidget *source, const char *title, SZFriendsGtkChosen chosen, gpointer chosen_data,
                         gpointer data);
    gpointer data;
    /* Settings' Change… for where received files go: a folder, starting at `start` (may be NULL). */
    void (*choose_folder)(GtkWidget *source, const char *start, SZFriendsGtkChosen chosen, gpointer chosen_data,
                          gpointer data);
} SZFriendsGtkSeams;
void szfriends_gtk_set_seams(const SZFriendsGtkSeams *seams);
void szfriends_gtk_copy_text(GtkWidget *source, const char *text);
void szfriends_gtk_open_uri(GtkWidget *source, const char *uri);
/* Asks for an image file (the system's open dialog, titled `title`); chosen(path or NULL, data) runs once. */
void szfriends_gtk_choose_image(GtkWidget *source, const char *title, SZFriendsGtkChosen chosen, gpointer data);
/* Asks for a folder (the system's folder dialog, opened at `start`, which may make a new folder); chosen runs once. */
void szfriends_gtk_choose_folder(GtkWidget *source, const char *start, SZFriendsGtkChosen chosen, gpointer data);
/* The pages' stylesheet, once per display, beside the views' own (its rules use the same @szfriends_* tokens). */
void szfriends_gtk_list_style_ensure(GtkWidget *widget);

/* The one confirmation: asks `confirm` and calls run(run_data) only on its confirm button; run_destroy(run_data)
 * runs once whatever the answer. In a dropdown, a card over its pages; elsewhere (Settings), the seam's or the
 * system's dialog. Destructive when `destructive` or the question says so: a red confirm button, and keyboard focus
 * resting on Cancel. */
void szfriends_gtk_confirm(SZFriendsGtkDropdown *dropdown, GtkWidget *source, const SZFriendsGtkConfirm *confirm,
                           gboolean destructive, SZFriendsGtkRun run, gpointer run_data, GDestroyNotify run_destroy);
/* Runs a PROTOCOL.md action, for every page: an unknown one does nothing; open_settings opens System Settings;
 * open_file and show_file go to the host; any other sends its intent with `ids`, after szfriends_gtk_confirm when it
 * carries `confirm`. `done` runs with the reply (or NULL, NULL when nothing was sent). `dropdown` is NULL in
 * Settings. */
void szfriends_gtk_perform(SZFriendsGtkLink *link, SZFriendsGtkDropdown *dropdown, GtkWidget *source,
                           const SZFriendsGtkAction *action, const SZFriendsGtkActionIds *ids,
                           SZFriendsGtkReplyFunc done, gpointer done_data);
/* A button showing one action slot (the visibility action, an alert's, a note's, the banner's), reused across
 * snapshots so a countdown ticking every second never takes its hover or focus. Hidden for no or an unknown action. */
GtkWidget *szfriends_gtk_list_action_button_new(void);
gboolean szfriends_gtk_list_action_button_set(GtkWidget *button, const SZFriendsGtkAction *action);
/* A label for text from a snapshot: plain text, wrapped, left-aligned, with `css_class`. */
GtkWidget *szfriends_gtk_list_label(const char *css_class);
/* Sets a label's text and hides it when there is none, so an absent field leaves no gap. */
void szfriends_gtk_list_label_set(GtkWidget *label, const char *text);

/* ---- The footer (szfriends_gtk_list_footer.c) ------------------------------------------------------ */

GtkWidget *szfriends_gtk_footer_new(SZFriendsGtkLink *link, SZFriendsGtkDropdown *dropdown);
void szfriends_gtk_footer_apply(GtkWidget *footer, const SZFriendsGtkFooter *data);
void szfriends_gtk_footer_begin_edit(GtkWidget *footer);
gboolean szfriends_gtk_footer_cancel_edit(GtkWidget *footer); /* TRUE when an edit was open */
void szfriends_gtk_footer_commit_edit(GtkWidget *footer);      /* what Return and Save do */
gboolean szfriends_gtk_footer_is_editing(GtkWidget *footer);
typedef struct {
    GtkWidget *avatar, *name_button, *name_label, *editor, *save_button, *cancel_button, *id_label, *copy_button,
        *copy_label, *add_button, *note;
} SZFriendsGtkFooterParts;
const SZFriendsGtkFooterParts *szfriends_gtk_footer_parts(GtkWidget *footer);

/* ---- The Nearby tab (szfriends_gtk_nearby_page.c) -------------------------------------------------- */

GtkWidget *szfriends_gtk_nearby_pane_new(SZFriendsGtkLink *link, SZFriendsGtkDropdown *dropdown);
/* Takes `snapshot` (freed with the next one or the pane); the footer is the page's to show. */
void szfriends_gtk_nearby_pane_apply(GtkWidget *pane, SZFriendsGtkNearbySnapshot *snapshot);
const SZFriendsGtkNearbySnapshot *szfriends_gtk_nearby_pane_snapshot(GtkWidget *pane); /* NULL before the first */
typedef struct {
    GtkWidget *visibility, *visibility_title, *visibility_body, *countdown, *visibility_button;
    GtkWidget *alert, *alert_title, *alert_body, *alert_button;
    GtkWidget *note, *note_text, *note_button;
    GtkWidget *people_label, *status, *status_label;
    GPtrArray *rows; /* SZFriendsGtkRow widgets, one per person */
    GtkWidget *empty, *empty_glyph, *empty_title, *empty_body;
} SZFriendsGtkNearbyParts;
const SZFriendsGtkNearbyParts *szfriends_gtk_nearby_pane_parts(GtkWidget *pane);

/* ---- The page (szfriends_gtk_list_page.c) ---------------------------------------------------------- */

typedef struct {
    /* The title and its Beta tag (welcome.strings button_label, beta) beside the search field. */
    GtkWidget *title, *beta;
    GtkWidget *search, *tabs, *stack;
    GtkWidget *send_notice, *send_text, *send_cancel;
    GtkWidget *banner, *banner_text, *banner_button;
    GtkWidget *prompt, *prompt_title, *prompt_entry, *prompt_save, *prompt_note;
    GtkWidget *prompt_beta; /* the card shows on first run, so it says Friends is a beta (beta_note) */
    /* Several computers (szfriends_gtk_list_devices.c): the removed notice with Start Over in its slot, the join
     * requests, and the name prompt's "Use my existing profile". */
    GtkWidget *devices, *removed, *removed_title, *removed_body, *removed_slot, *join_requests, *prompt_join;
    gboolean device_removed;
    GtkWidget *empty_title, *empty_body;
    GPtrArray *rows; /* SZFriendsGtkRow widgets in the helper's order */
    GtkWidget *nearby, *footer;
    gboolean showing_nearby;
    guint list_token, nearby_token; /* the subscriptions held now; 0 for none */
    guint list_snapshots, nearby_snapshots; /* applied so far, so the suite knows a scripted one arrived */
} SZFriendsGtkListParts;
/* NULL for any other page. */
const SZFriendsGtkListParts *szfriends_gtk_list_page_parts(SZFriendsGtkPage *page);
void szfriends_gtk_list_page_show_nearby(SZFriendsGtkPage *page, gboolean nearby);
/* What Return in the name field does. */
void szfriends_gtk_list_page_submit_name(SZFriendsGtkPage *page);

G_END_DECLS

#endif /* SZFRIENDS_GTK_LIST_PAGE_H */
