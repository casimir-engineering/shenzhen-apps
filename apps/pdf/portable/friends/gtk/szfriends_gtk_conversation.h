/* Shenzhen Friends GTK views: the conversation page and its parts (internal to gtk/; mirrors
 * mac/SZFriendsConversationPage.h, SZFriendsMessageItemView, SZFriendsComposerView).
 *
 * One friend's history and composer, or the request card while a request is pending (PROTOCOL.md § Views,
 * conversation):
 *   - szfriends_gtk_conversation_page.c: the page, its header (name and route centred, a click opens details) and the
 *     search under it; szfriends_gtk_conversation_history.c: the history in a GtkListView (oldest to newest, Show
 *     earlier messages) and drops on it; szfriends_gtk_conversation_state.c: shared state, popovers, the stylesheet;
 *   - szfriends_gtk_message.c, szfriends_gtk_message_links.c, szfriends_gtk_message_keys.c: day separators, events
 *     and bubbles drawn from the segments as text with a PangoAttrList; links open only through a menu that shows
 *     where they go, a mention acts by its kind (§ Mentions), and both are reached by keyboard too;
 *   - szfriends_gtk_transfer.c: transfer cards with the helper's preview (§ Thumbnails) or the type's icon;
 *   - szfriends_gtk_composer.c, szfriends_gtk_composer_chips.c, szfriends_gtk_composer_pickers.c (and
 *     szfriends_gtk_composer_private.h): Return sends, Shift+Return breaks the line, `#` attaches the host's items, `@`
 *     mentions a friend, drops become chips, and the draft stays with the window;
 *   - szfriends_gtk_mention_card.c, szfriends_gtk_mention_card_request.c: action buttons (Block armed), a stranger's
 *     mention card that follows new snapshots, the request card; szfriends_gtk_mention_card_text.c and
 *     szfriends_gtk_mention_card_tables.c: the card's name shown literally (characters that draw nothing as code
 *     points, the rule of mac/SZFriendsLiteralText.m and friends/fixtures/text/invisible-cases.json).
 * Files hosts have no Markdown renderer and no assistant: messages are plain text with links, and there is no `/`.
 * Display-free functions are marked so; the suite calls them without a window server. */

#ifndef SZFRIENDS_GTK_CONVERSATION_H
#define SZFRIENDS_GTK_CONVERSATION_H

#include "gtk/szfriends_gtk_actions.h"
#include "gtk/szfriends_gtk_dropdown.h"
#include "gtk/szfriends_gtk_drops.h"

#include <adwaita.h>

G_BEGIN_DECLS

/* The page's builder, registered by szfriends_gtk_pages_builtin.c. */
extern const SZFriendsGtkPageClass szfriends_gtk_conversation_page_class;

/* ---- What a click on a message's words does (display-free) ------------------------------------------- */

typedef enum {
    SZFRIENDS_GTK_HIT_NONE,   /* plain words, the reader's own mention, or a destination that may not open */
    SZFRIENDS_GTK_HIT_WEB,    /* http or https: the link menu, then the browser */
    SZFRIENDS_GTK_HIT_EMAIL,  /* mailto: the link menu, then a new email */
    SZFRIENDS_GTK_HIT_FRIEND, /* a friend's mention: their conversation */
    SZFRIENDS_GTK_HIT_CARD    /* a stranger's mention: their card */
} SZFriendsGtkHitKind;

typedef struct {
    SZFriendsGtkHitKind kind;
    const char *url;                    /* WEB, EMAIL: the segment's destination */
    const SZFriendsGtkMention *mention; /* FRIEND, CARD: the mentions[] entry whose url the destination equals */
} SZFriendsGtkHit;

/* A segment's destination is its url, or mentions[n].url for a segment with `mention` n. A destination equal to a
 * mentions[] url acts by that mention's kind; otherwise only http, https and mailto open (PROTOCOL.md § Mentions:
 * views compare the url, never parse it, and open no other szfriends: link). */
SZFriendsGtkHit szfriends_gtk_link_hit(const SZFriendsGtkConversationItem *item, gsize segment);
gboolean szfriends_gtk_link_may_open(const char *url);
/* What the link's words show as an address when the link goes elsewhere ("www.apple.com" over a link to another
 * site), or NULL: the AppKit link menu's rule (mac/SZFriendsLinkMenu.m). */
char *szfriends_gtk_link_shown_elsewhere(const char *words, const char *url);
/* The destination as the menu shows it: whole up to about 80 characters, then cut in the path, never in the host. */
char *szfriends_gtk_link_address_title(const char *url);
/* The link menu's lines from the catalog's words (link_elsewhere, link_open or link_open_email): a warning first
 * when the words show another place (NULL otherwise), the address, and the open item's words ("" when the catalog
 * has none: the address itself then opens the link). */
typedef struct {
    char *warning, *address, *open_label;
    gboolean email;
} SZFriendsGtkLinkMenuText;
SZFriendsGtkLinkMenuText *szfriends_gtk_link_menu_text(const char *url, const char *words, const char *elsewhere,
                                                       const char *open_web, const char *open_email);
void szfriends_gtk_link_menu_text_free(SZFriendsGtkLinkMenuText *text);
/* Replaces {key} placeholders in one pass over `format`, so text put in is never read as a placeholder. */
char *szfriends_gtk_fill(const char *format, const char *const *keys, const char *const *values, gsize count);

/* The byte offset at which a long plain message is cut until the person presses Show all, or -1 when the whole of
 * it shows (mac/SZFriendsMessageBody.m: 4,096 characters, preferring a space in the last 256). Display-free. */
gssize szfriends_gtk_plain_cut(const char *text);

/* Whether an item shows `action`: known, asking nothing first (conversation actions carry no confirm), and Cancel on
 * a queued message only from a helper that announces messages.cancel. Display-free. */
gboolean szfriends_gtk_item_shows_action(const SZFriendsGtkAction *action, gboolean helper_cancels_messages);

/* ---- Previews and type icons (display-free) ---------------------------------------------------------- */

/* The helper's preview at `path`, decoded, or NULL with a developer-facing reason. Only a regular PNG file directly in
 * <state_dir>/thumbnails/, at most 1 MiB, whose header gives exactly the snapshot's `width` and `height` (1 to 192
 * pixels a side), is decoded: views load nothing else, and a missing or unreadable file, or one of another size,
 * reads as no preview, as in AppKit. Thread-safe. */
GdkTexture *szfriends_gtk_thumbnail_load(const char *path, const char *state_dir, gint64 width, gint64 height,
                                         GError **error);
/* The type's icon for `extension` (file_info.extension) through GIO content types, by name only; anything that is not
 * a short lowercase extension gets the generic document. */
GIcon *szfriends_gtk_file_type_icon(const char *extension);
/* The widget a card draws its preview with (szfriends_gtk_transfer.c), and whether its picture has loaded. */
gboolean szfriends_gtk_is_preview(GtkWidget *widget);
gboolean szfriends_gtk_preview_is_loaded(GtkWidget *widget);
/* Both apps draw a preview at most this many points on its longer side (PROTOCOL.md § Thumbnails). */
#define SZFRIENDS_GTK_PREVIEW_LIMIT 64
/* The box a preview is drawn in, from the snapshot's pixel size before the file loads: at most `limit` points on the
 * longer side and never more than one point per pixel, as mac/SZFriendsFilePreview.m lays it out. */
void szfriends_gtk_thumbnail_box(gint64 width, gint64 height, int limit, int *box_width, int *box_height);

/* ---- The composer's message (display-free) ----------------------------------------------------------- */

/* One run of the composer's text: words, or an @ chip naming a friend by conversation id. */
typedef struct {
    const char *text;       /* words; any U+FFFC in them is dropped, since it would count as a mention */
    const char *mention_id; /* a chip: U+FFFC in the text and its conversation id in `mentions` */
} SZFriendsGtkComposerPiece;
#define SZFRIENDS_GTK_MAX_MENTIONS 20
/* send_message with the pieces' text, `items` (SZFriendsGtkHostItem *) as attachments and one mentions entry per
 * chip in order (szfriends_intent_with_mentions); NULL when there is nothing to send or more than 20 chips. */
szfriends_intent *szfriends_gtk_composer_intent(const char *conversation_id, const SZFriendsGtkComposerPiece *pieces,
                                                gsize count, GPtrArray *items, const char *token);

/* ---- The page's shared state ---------------------------------------------------------------------- */

typedef struct _SZFriendsGtkConversation SZFriendsGtkConversation;
typedef struct _SZFriendsGtkComposerView SZFriendsGtkComposerView;

struct _SZFriendsGtkConversation {
    SZFriendsGtkPage *page; /* NULL once the page went: late replies and loads then change nothing */
    SZFriendsGtkLink *link; /* the page holds it; nothing reaches it after the page went */
    SZFriendsGtkDropdown *dropdown;
    char *conversation_id;
    GtkWidget *content;       /* the overlay over the history: search results, pickers and drop marks sit on it */
    GtkWidget *color_probe;   /* resolves @szfriends_accent for the Pango attributes of mentions */
    GtkWidget *warning_probe; /* resolves @szfriends_warning for the marks in a card's literal name */
    GHashTable *expanded;     /* item ids shown whole after Show all */
    GHashTable *thumbnails;   /* path -> SZFriendsGtkThumbnailEntry (szfriends_gtk_transfer.c) */
    GCancellable *cancellable;
    char *state_dir;
    GtkWidget *popover;       /* the open link menu or mention card, at most one */
    GtkWidget *popover_owner;
    SZFriendsGtkComposerView *composer;
    GPtrArray *armed;         /* GtkWidget *: buttons showing their "Block?" pill (weak) */
};

SZFriendsGtkConversation *szfriends_gtk_conversation_new(SZFriendsGtkPage *page);
SZFriendsGtkConversation *szfriends_gtk_conversation_ref(SZFriendsGtkConversation *conversation);
void szfriends_gtk_conversation_unref(SZFriendsGtkConversation *conversation);
/* The page went: closes its popover, cancels preview loads, and makes late replies change nothing. */
void szfriends_gtk_conversation_detach(SZFriendsGtkConversation *conversation);
gboolean szfriends_gtk_conversation_helper_cancels(SZFriendsGtkConversation *conversation);
/* Opens `uri` with the system (GtkUriLauncher); tests replace it so nothing leaves the process. */
typedef void (*SZFriendsGtkUriOpener)(const char *uri, gpointer data);
void szfriends_gtk_conversation_set_uri_opener(SZFriendsGtkUriOpener opener, gpointer data);
void szfriends_gtk_conversation_open_uri(SZFriendsGtkConversation *conversation, const char *uri);
/* Shows `popover` (a GtkPopover) pointing at `rect` in `owner`, closing the one open before; it goes with `owner`. */
void szfriends_gtk_conversation_show_popover(SZFriendsGtkConversation *conversation, GtkWidget *owner,
                                             GtkWidget *popover, const GdkRectangle *rect);
gboolean szfriends_gtk_conversation_close_popover(SZFriendsGtkConversation *conversation);
/* How a popover is shown: gtk_popover_popup in the app; tests record instead, so no surface reaches the screen. */
void szfriends_gtk_conversation_set_popup(void (*popup)(GtkPopover *popover));
/* Installs the conversation's stylesheet once per display (its rules use the views' @szfriends_* tokens). */
void szfriends_gtk_conversation_style_ensure(GdkDisplay *display);
/* @szfriends_accent and @szfriends_warning as the page resolves them now, for colours drawn as Pango attributes;
 * FALSE before the page is in a window. Never kept: after a light or dark switch the page reads them again once the
 * new stylesheet is in (szfriends_gtk_conversation_page.c). */
gboolean szfriends_gtk_conversation_accent(SZFriendsGtkConversation *conversation, GdkRGBA *rgba);
gboolean szfriends_gtk_conversation_warning(SZFriendsGtkConversation *conversation, GdkRGBA *rgba);

/* For the suite: a page's state, its history and its parts by name (title, search, results, stack, request,
 * composer). */
typedef struct _SZFriendsGtkHistory SZFriendsGtkHistory;
SZFriendsGtkConversation *szfriends_gtk_conversation_page_state(SZFriendsGtkPage *page);
SZFriendsGtkHistory *szfriends_gtk_conversation_page_history(SZFriendsGtkPage *page);
GtkWidget *szfriends_gtk_conversation_page_part(SZFriendsGtkPage *page, const char *name);

/* ---- The history (szfriends_gtk_conversation_history.c) ----------------------------------------------- */

/* One history item as the list's model holds it: the parsed item, its key and its JSON, so an unchanged item keeps
 * its row across snapshots. */
GObject *szfriends_gtk_history_holder_new(JsonObject *item_json);
const SZFriendsGtkConversationItem *szfriends_gtk_history_item(GObject *holder);
SZFriendsGtkHistory *szfriends_gtk_history_new(SZFriendsGtkConversation *conversation);
GtkWidget *szfriends_gtk_history_widget(SZFriendsGtkHistory *history);
GtkWidget *szfriends_gtk_history_list_view(SZFriendsGtkHistory *history);
GListModel *szfriends_gtk_history_model(SZFriendsGtkHistory *history); /* holders, after Show earlier messages */
void szfriends_gtk_history_apply(SZFriendsGtkHistory *history, JsonObject *data,
                                 const SZFriendsGtkConversationSnapshot *snapshot, guint subscription);
void szfriends_gtk_history_forget_highlight(SZFriendsGtkHistory *history);
/* Binds every row again, after the light or dark appearance changed the colours drawn into the words. */
void szfriends_gtk_history_restyle(SZFriendsGtkHistory *history);
/* What its drop target calls, open to the suite: files hovering (NULL when they leave), and the drop. */
void szfriends_gtk_history_drag_value(SZFriendsGtkHistory *history, const GValue *value);
gboolean szfriends_gtk_history_drop(SZFriendsGtkHistory *history, const GValue *value);
void szfriends_gtk_history_free(SZFriendsGtkHistory *history);

/* ---- Rows (szfriends_gtk_message.c, szfriends_gtk_transfer.c) ---------------------------------------- */

/* The widget for one history item; it keeps a reference to `conversation` (and a bubble to `holder`, for clicks). */
GtkWidget *szfriends_gtk_message_row_new(SZFriendsGtkConversation *conversation, GObject *holder,
                                         const SZFriendsGtkConversationItem *item);
GtkWidget *szfriends_gtk_transfer_row_new(SZFriendsGtkConversation *conversation,
                                          const SZFriendsGtkConversationItem *item);
GtkWidget *szfriends_gtk_simple_row_new(const SZFriendsGtkConversationItem *item); /* day separators and events */
/* "Via the assistant" with the assistant's spark, leading the time line under a bubble or a card. */
GtkWidget *szfriends_gtk_assistant_label_new(const char *text);
/* The message label's segment under a point in its own coordinates, or -1 (for clicks and tooltips). */
gssize szfriends_gtk_message_segment_at(GtkWidget *label, double x, double y);
/* What a click on segment `segment` of `item`, drawn in `label`, does: opens a friend's conversation, shows a
 * stranger's card or the link menu, or nothing (PROTOCOL.md § Mentions). Returns what it did. */
SZFriendsGtkHitKind szfriends_gtk_message_activate(SZFriendsGtkConversation *conversation,
                                                    const SZFriendsGtkConversationItem *item, gsize segment,
                                                    GtkWidget *label);
GtkWidget *szfriends_gtk_link_menu_new(SZFriendsGtkConversation *conversation, const char *url, const char *words);

/* The keyboard path to a bubble's links and mentions (szfriends_gtk_message_keys.c), for a `label` drawing `item`
 * whose segments lie at `ranges` (guint start and end byte pairs) with the look `attributes`; both are kept. Focus
 * reaching the words marks the first segment that acts, Tab and the arrow keys step through those segments (Tab past
 * the last one leaves the bubble), and Return or Space acts on the marked one as a click would. */
void szfriends_gtk_message_keys_attach(SZFriendsGtkConversation *conversation, GObject *holder,
                                       const SZFriendsGtkConversationItem *item, GtkWidget *label, GArray *ranges,
                                       PangoAttrList *attributes);
/* The marked segment, or -1; and the key handling, open to the suite (TRUE when the key was the bubble's). */
gssize szfriends_gtk_message_focused_segment(GtkWidget *label);
gboolean szfriends_gtk_message_key(GtkWidget *label, guint keyval, GdkModifierType state);
/* Focus reached the words from the keyboard (GTK selected them all) or left them. */
void szfriends_gtk_message_focus_changed(GtkWidget *label, gboolean focused);

/* ---- A name shown literally (szfriends_gtk_mention_card_text.c; display-free) ------------------------- */

/* The code points of `length` bytes of UTF-8 `text` (-1: up to its NUL), composed (NFC), that a card shows as markers,
 * in order, one per occurrence: characters that draw nothing or change how their neighbours draw (outside the few
 * places where they draw something), and a combining mark its letter already carries, that would be a fifth on it
 * (counting the marks a precomposed letter is made of), or that does not fit it (szfriends_gtk_mark_fits_letter). */
GArray *szfriends_gtk_literal_marked(const char *text, gssize length);
/* `text` composed, as a card shows it: each run of marked characters becomes one marker (" U+200B ×3 ") in a
 * monospace face, coloured `mark` on a faint fill of it when given; returns the text and sets `attributes` (never
 * markup). */
char *szfriends_gtk_literal_text(const char *text, gssize length, const GdkRGBA *mark, PangoAttrList **attributes);
/* The Unicode properties the rule needs, the same tables as mac/SZFriendsEmojiTables.m
 * (szfriends_gtk_mention_card_tables.c; the suite compares them range for range). */
gboolean szfriends_gtk_is_emoji_variation_base(gunichar c);
gboolean szfriends_gtk_is_extended_pictographic(gunichar c);
gboolean szfriends_gtk_is_dual_joining(gunichar c);
gboolean szfriends_gtk_is_right_joining(gunichar c);
gboolean szfriends_gtk_is_indic_consonant(gunichar c);
gboolean szfriends_gtk_virama_block(gunichar c, gunichar *low, gunichar *high);
/* Whether a combining mark is drawn on a letter of its own script: the mark's Script_Extensions (else its Script)
 * share a script with the letter's, or the mark belongs to no script in particular (Inherited, no extensions). */
gboolean szfriends_gtk_mark_fits_letter(gunichar mark, gunichar letter);
/* A table by its name in mac/SZFriendsEmojiTables.m, as its values in order (start and end pairs; virama, block
 * start and block end triples; script starts as start and script pairs; extensions as start, end, first and count;
 * the script sets one by one), for the suite. */
const gunichar *szfriends_gtk_literal_table(const char *name, gsize *n_values);

/* ---- Actions and cards (szfriends_gtk_mention_card*.c) ----------------------------------------------- */

/* A button for `action` with the ids it takes; Block arms first ("Block?", a second click within arm.seconds).
 * `done` runs with the reply (NULL error on success), or at once for a client-side action. */
typedef void (*SZFriendsGtkActionDone)(SZFriendsGtkConversation *conversation, const SZFriendsGtkAction *action,
                                       JsonObject *result, const SZFriendsGtkError *error, gpointer data);
GtkWidget *szfriends_gtk_action_button_new(SZFriendsGtkConversation *conversation, const SZFriendsGtkAction *action,
                                           const SZFriendsGtkActionIds *ids, SZFriendsGtkActionDone done,
                                           gpointer data, GDestroyNotify destroy);
gboolean szfriends_gtk_action_button_is_armed(GtkWidget *button);
/* The action a button was made for (its own copy), or NULL. */
const SZFriendsGtkAction *szfriends_gtk_action_button_action(GtkWidget *button);
/* Escape: turns every armed pill back; TRUE when one was armed. */
gboolean szfriends_gtk_conversation_disarm(SZFriendsGtkConversation *conversation);
/* Puts buttons for the shown `actions` in order, keeping the button of each unchanged action (same kind, style, label
 * and arm), so an armed "Block?" survives a snapshot that changed something else. `keys` maps each button to its
 * action's key and is kept up to date; a button no longer wanted leaves its parent. Returns the buttons in order,
 * each referenced and out of any parent, for the caller to place. */
GPtrArray *szfriends_gtk_action_buttons_update(SZFriendsGtkConversation *conversation, GHashTable *keys,
                                               const SZFriendsGtkAction *actions, gsize n_actions,
                                               const SZFriendsGtkActionIds *ids, SZFriendsGtkActionDone done,
                                               gpointer data);
/* The content of a stranger's card (title shown literally, id_label, status_label and its actions) for the mention
 * `mention` of `item`, for a popover. */
GtkWidget *szfriends_gtk_mention_card_new(SZFriendsGtkConversation *conversation,
                                          const SZFriendsGtkConversationItem *item,
                                          const SZFriendsGtkMention *mention);
/* The open card follows `snapshot`: the same item's mention with the same url and words updates the card in place
 * while it is still a stranger's (Request sent, Blocked); otherwise the card closes. */
void szfriends_gtk_mention_card_follow(SZFriendsGtkConversation *conversation,
                                       const SZFriendsGtkConversationSnapshot *snapshot);
/* The pending request: avatar, title, the comparison code both screens show, Accept, Decline and Block. */
GtkWidget *szfriends_gtk_request_card_new(SZFriendsGtkConversation *conversation);
void szfriends_gtk_request_card_apply(GtkWidget *card, const SZFriendsGtkRequestCard *request);

/* ---- The composer (szfriends_gtk_composer.c, szfriends_gtk_composer_pickers.c) ----------------------- */

GtkWidget *szfriends_gtk_composer_new(SZFriendsGtkConversation *conversation);
SZFriendsGtkComposerView *szfriends_gtk_composer_from_widget(GtkWidget *widget);
void szfriends_gtk_composer_apply(SZFriendsGtkComposerView *composer, const SZFriendsGtkComposer *snapshot);
GtkWidget *szfriends_gtk_composer_get_text_view(SZFriendsGtkComposerView *composer);
GtkWidget *szfriends_gtk_composer_get_send_button(SZFriendsGtkComposerView *composer);
GtkWidget *szfriends_gtk_composer_get_error_label(SZFriendsGtkComposerView *composer);
GtkWidget *szfriends_gtk_composer_get_chips(SZFriendsGtkComposerView *composer);
void szfriends_gtk_composer_send(SZFriendsGtkComposerView *composer);
void szfriends_gtk_composer_add_items(SZFriendsGtkComposerView *composer, GPtrArray *items); /* NULL: redraw */
/* A `#` item chosen: the `#` typed before the cursor becomes its chip. */
void szfriends_gtk_composer_attach(SZFriendsGtkComposerView *composer, const SZFriendsGtkHostItem *item);
/* What its drop target calls, open to the suite: files hovering (NULL when they leave), and the drop (chips). */
void szfriends_gtk_composer_drag_value(SZFriendsGtkComposerView *composer, const GValue *value);
gboolean szfriends_gtk_composer_drop(SZFriendsGtkComposerView *composer, const GValue *value);
SZFriendsGtkConversation *szfriends_gtk_composer_conversation(SZFriendsGtkComposerView *composer);
const char *szfriends_gtk_composer_mention_note(SZFriendsGtkComposerView *composer);
/* Inserts an @ chip at the cursor in place of the `@` typed before it. */
void szfriends_gtk_composer_insert_mention(SZFriendsGtkComposerView *composer, const char *conversation_id,
                                           const char *label);
guint szfriends_gtk_composer_mention_count(SZFriendsGtkComposerView *composer);
/* Escape: closes an open picker; TRUE when one was open. */
gboolean szfriends_gtk_composer_escape(SZFriendsGtkComposerView *composer);
/* The pickers: `#` lists the host's items (attachable_items), `@` the friends a list subscription filtered by what
 * is typed says may be mentioned. Each sits over the history above the composer and closes on Escape. */
void szfriends_gtk_composer_open_attach_picker(SZFriendsGtkComposerView *composer);
void szfriends_gtk_composer_open_mention_picker(SZFriendsGtkComposerView *composer);
GtkWidget *szfriends_gtk_composer_get_picker(SZFriendsGtkComposerView *composer); /* NULL when none is open */
void szfriends_gtk_composer_set_picker(SZFriendsGtkComposerView *composer, GtkWidget *picker);
void szfriends_gtk_composer_close_picker(SZFriendsGtkComposerView *composer);
/* szfriends_gtk_composer_pickers.c builds the panel; the composer owns it. Keys are Up, Down and Return. */
GtkWidget *szfriends_gtk_picker_new(SZFriendsGtkComposerView *composer, gboolean mentions);
void szfriends_gtk_picker_free_state(GtkWidget *picker);
gboolean szfriends_gtk_picker_key(GtkWidget *picker, guint keyval);
guint szfriends_gtk_picker_row_count(GtkWidget *picker);

G_END_DECLS

#endif /* SZFRIENDS_GTK_CONVERSATION_H */
