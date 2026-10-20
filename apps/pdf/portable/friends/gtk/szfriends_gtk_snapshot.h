/* Shenzhen Friends GTK views: every PROTOCOL.md view and frame as plain C structs (display-free).
 *
 * The helper decides and the views render (PROTOCOL.md § Principles), so a view needs the snapshot's fields and
 * nothing else. These structs mirror the § Schemas blocks field for field, under the same names, so a page reads
 * `row->title` where the AppKit views read SZFStr(row, @"title"). Parsing needs json-glib only, no display, so the
 * suite checks every fixture without a window server.
 *
 * Conventions, so a malformed snapshot draws less instead of crashing:
 *   - a required string is never NULL ("" when the helper left it out); a `string|null` field is NULL for null;
 *   - a required object is embedded (zeroed when missing); an `@x|null` object is a pointer, NULL for null;
 *   - an enum is 0 for an unknown, absent or null value, so a view hides an action or style it does not know;
 *   - an array is a pointer and a count (`rows`, `n_rows`), elements stored contiguously;
 *   - `present` has bit i set when field i of the struct's schema (szfriends_gtk_schema.h) was in the JSON.
 * Strings are plain text from other people: set them with gtk_label_set_text, never as Pango markup. */

#ifndef SZFRIENDS_GTK_SNAPSHOT_H
#define SZFRIENDS_GTK_SNAPSHOT_H

#include <glib.h>
#include <json-glib/json-glib.h>

G_BEGIN_DECLS

typedef guint64 SZFriendsGtkPresence;

/* ---- Enums (0 = unknown, absent or null) ------------------------------------------------------------- */

typedef enum {
    SZFRIENDS_GTK_AVATAR_UNKNOWN, SZFRIENDS_GTK_AVATAR_ANIMAL, SZFRIENDS_GTK_AVATAR_IMAGE,
    SZFRIENDS_GTK_AVATAR_PLACEHOLDER
} SZFriendsGtkAvatarKind;
typedef enum {
    SZFRIENDS_GTK_ROUTE_UNKNOWN, SZFRIENDS_GTK_ROUTE_LOCAL, SZFRIENDS_GTK_ROUTE_ONLINE, SZFRIENDS_GTK_ROUTE_OFFLINE,
    SZFRIENDS_GTK_ROUTE_NONE,
    SZFRIENDS_GTK_ROUTE_CONNECTING /* an online attempt runs: the globe, in the offline colour */
} SZFriendsGtkRouteKind;
typedef enum {
    SZFRIENDS_GTK_METHOD_UNSET, SZFRIENDS_GTK_METHOD_LAN, SZFRIENDS_GTK_METHOD_P2P_WIFI, SZFRIENDS_GTK_METHOD_BLUETOOTH,
    SZFRIENDS_GTK_METHOD_INTERNET, SZFRIENDS_GTK_METHOD_RELAY
} SZFriendsGtkRouteMethod;
typedef enum {
    SZFRIENDS_GTK_ACTION_UNKNOWN, SZFRIENDS_GTK_ACTION_ACCEPT_REQUEST, SZFRIENDS_GTK_ACTION_DECLINE_REQUEST,
    SZFRIENDS_GTK_ACTION_CANCEL_REQUEST, SZFRIENDS_GTK_ACTION_BLOCK, SZFRIENDS_GTK_ACTION_UNBLOCK,
    SZFRIENDS_GTK_ACTION_REMOVE_FRIEND, SZFRIENDS_GTK_ACTION_SEND_REQUEST, SZFRIENDS_GTK_ACTION_ADD_FROM_MENTION,
    SZFRIENDS_GTK_ACTION_ACCEPT_OFFER, SZFRIENDS_GTK_ACTION_DECLINE_OFFER, SZFRIENDS_GTK_ACTION_CANCEL_TRANSFER,
    SZFRIENDS_GTK_ACTION_CANCEL_MESSAGE,
    SZFRIENDS_GTK_ACTION_RETRY_ITEM, SZFRIENDS_GTK_ACTION_MARK_VERIFIED, SZFRIENDS_GTK_ACTION_ACCEPT_KEY_CHANGE,
    SZFRIENDS_GTK_ACTION_DISMISS_BANNER, SZFRIENDS_GTK_ACTION_START_VISIBILITY, SZFRIENDS_GTK_ACTION_STOP_VISIBILITY,
    SZFRIENDS_GTK_ACTION_RESET_FRIENDS, SZFRIENDS_GTK_ACTION_DELETE_HISTORY, SZFRIENDS_GTK_ACTION_OPEN_FILE,
    SZFRIENDS_GTK_ACTION_SHOW_FILE, SZFRIENDS_GTK_ACTION_OPEN_SETTINGS,
    /* Links (PROTOCOL.md § Links) */
    SZFRIENDS_GTK_ACTION_ADD_FROM_LINK, SZFRIENDS_GTK_ACTION_RECEIVE_LINK, SZFRIENDS_GTK_ACTION_RESET_FRIEND_LINK,
    SZFRIENDS_GTK_ACTION_REVOKE_LINK, /* Several computers (PROTOCOL.md § Devices, § Joining): */
    SZFRIENDS_GTK_ACTION_REVOKE_DEVICE, SZFRIENDS_GTK_ACTION_FETCH_FROM_DEVICE, SZFRIENDS_GTK_ACTION_JOIN_PROFILE,
    SZFRIENDS_GTK_ACTION_CANCEL_JOIN, SZFRIENDS_GTK_ACTION_APPROVE_JOIN, SZFRIENDS_GTK_ACTION_DENY_JOIN,
    /* Nearby's Allow and Try Again (PROTOCOL.md § nearby) */
    SZFRIENDS_GTK_ACTION_ACTIVATE,
    /* Settings' Change… for where received files go: the folder dialog, then set_received_folder */
    SZFRIENDS_GTK_ACTION_CHOOSE_RECEIVED_FOLDER
} SZFriendsGtkActionKind;
typedef enum {
    SZFRIENDS_GTK_STYLE_UNKNOWN, SZFRIENDS_GTK_STYLE_PRIMARY, SZFRIENDS_GTK_STYLE_SECONDARY, SZFRIENDS_GTK_STYLE_LINK,
    SZFRIENDS_GTK_STYLE_DESTRUCTIVE
} SZFriendsGtkActionStyle;
typedef enum {
    SZFRIENDS_GTK_SETTINGS_UNSET, SZFRIENDS_GTK_SETTINGS_LOCAL_NETWORK_PRIVACY,
    SZFRIENDS_GTK_SETTINGS_BLUETOOTH_PRIVACY, SZFRIENDS_GTK_SETTINGS_BLUETOOTH, SZFRIENDS_GTK_SETTINGS_WIFI
} SZFriendsGtkSettingsTarget;
typedef enum {
    SZFRIENDS_GTK_EMPTY_UNSET, SZFRIENDS_GTK_EMPTY_SEARCHING, SZFRIENDS_GTK_EMPTY_NOBODY,
    SZFRIENDS_GTK_EMPTY_UNAVAILABLE, SZFRIENDS_GTK_EMPTY_NO_MATCH
} SZFriendsGtkEmptyKind;
typedef enum {
    SZFRIENDS_GTK_BANNER_UNKNOWN, SZFRIENDS_GTK_BANNER_ID_CHANGED, SZFRIENDS_GTK_BANNER_IDENTITY_UNAVAILABLE,
    SZFRIENDS_GTK_BANNER_UPDATE_REQUIRED
} SZFriendsGtkBannerKind;
typedef enum { SZFRIENDS_GTK_ROW_NORMAL, SZFRIENDS_GTK_ROW_MUTED } SZFriendsGtkRowStyle; /* unknown draws as normal */
typedef enum {
    SZFRIENDS_GTK_ICON_UNKNOWN, SZFRIENDS_GTK_ICON_ACCEPT, SZFRIENDS_GTK_ICON_DECLINE, SZFRIENDS_GTK_ICON_BLOCK
} SZFriendsGtkRowIcon;
typedef enum {
    SZFRIENDS_GTK_WAITING_UNKNOWN, SZFRIENDS_GTK_WAITING_REQUEST, SZFRIENDS_GTK_WAITING_OFFER,
    SZFRIENDS_GTK_WAITING_KEY_CHANGE
} SZFriendsGtkWaitingKind;
typedef enum {
    SZFRIENDS_GTK_VISIBILITY_UNKNOWN, SZFRIENDS_GTK_VISIBILITY_HIDDEN, SZFRIENDS_GTK_VISIBILITY_VISIBLE,
    SZFRIENDS_GTK_VISIBILITY_UNAVAILABLE
} SZFriendsGtkVisibilityState;
typedef enum {
    SZFRIENDS_GTK_NEARBY_METHOD_UNKNOWN, SZFRIENDS_GTK_NEARBY_METHOD_NETWORK, SZFRIENDS_GTK_NEARBY_METHOD_BLUETOOTH
} SZFriendsGtkNearbyMethod;
typedef enum {
    SZFRIENDS_GTK_METHOD_STATE_UNKNOWN, SZFRIENDS_GTK_METHOD_STATE_NOT_ASKED, SZFRIENDS_GTK_METHOD_STATE_STARTING,
    SZFRIENDS_GTK_METHOD_STATE_WORKING, SZFRIENDS_GTK_METHOD_STATE_DENIED, SZFRIENDS_GTK_METHOD_STATE_RADIO_OFF,
    SZFRIENDS_GTK_METHOD_STATE_UNAVAILABLE
} SZFriendsGtkMethodState;
typedef enum { SZFRIENDS_GTK_STATUS_UNKNOWN, SZFRIENDS_GTK_STATUS_SEARCHING } SZFriendsGtkStatusKind;
typedef enum {
    SZFRIENDS_GTK_ITEM_UNKNOWN, SZFRIENDS_GTK_ITEM_DAY, SZFRIENDS_GTK_ITEM_MESSAGE, SZFRIENDS_GTK_ITEM_TRANSFER,
    SZFRIENDS_GTK_ITEM_EVENT
} SZFriendsGtkItemKind;
typedef enum {
    SZFRIENDS_GTK_DIRECTION_UNSET, SZFRIENDS_GTK_DIRECTION_IN, SZFRIENDS_GTK_DIRECTION_OUT
} SZFriendsGtkDirection;
typedef enum {
    SZFRIENDS_GTK_TEXT_PLAIN, SZFRIENDS_GTK_TEXT_MARKDOWN
} SZFriendsGtkTextFormat; /* unknown shows as plain text */
typedef enum {
    SZFRIENDS_GTK_MESSAGE_UNKNOWN, SZFRIENDS_GTK_MESSAGE_QUEUED, SZFRIENDS_GTK_MESSAGE_CONNECTING,
    SZFRIENDS_GTK_MESSAGE_SENDING, SZFRIENDS_GTK_MESSAGE_DELIVERED, SZFRIENDS_GTK_MESSAGE_FAILED,
    SZFRIENDS_GTK_MESSAGE_CANCELLED
} SZFriendsGtkMessageState;
typedef enum {
    SZFRIENDS_GTK_TRANSFER_UNKNOWN, SZFRIENDS_GTK_TRANSFER_QUEUED, SZFRIENDS_GTK_TRANSFER_OFFERED,
    SZFRIENDS_GTK_TRANSFER_WAITING_FOR_YOU, SZFRIENDS_GTK_TRANSFER_SENDING, SZFRIENDS_GTK_TRANSFER_RECEIVING,
    SZFRIENDS_GTK_TRANSFER_DELIVERED, SZFRIENDS_GTK_TRANSFER_RECEIVED, SZFRIENDS_GTK_TRANSFER_DECLINED,
    SZFRIENDS_GTK_TRANSFER_CANCELLED, SZFRIENDS_GTK_TRANSFER_FAILED,
    SZFRIENDS_GTK_TRANSFER_ON_DEVICE, SZFRIENDS_GTK_TRANSFER_FETCHING /* held by another of the person's computers */
} SZFriendsGtkTransferState;
typedef enum {
    SZFRIENDS_GTK_REQUEST_UNSET, SZFRIENDS_GTK_REQUEST_INCOMING, SZFRIENDS_GTK_REQUEST_OUTGOING
} SZFriendsGtkRequestDirection;
typedef enum {
    SZFRIENDS_GTK_VERIFICATION_UNKNOWN, SZFRIENDS_GTK_VERIFIED, SZFRIENDS_GTK_UNVERIFIED
} SZFriendsGtkVerificationState;
typedef enum {
    SZFRIENDS_GTK_ID_UNKNOWN, SZFRIENDS_GTK_ID_UNRESERVED, SZFRIENDS_GTK_ID_RESERVED, SZFRIENDS_GTK_ID_CHANGED,
    SZFRIENDS_GTK_ID_UNAVAILABLE
} SZFriendsGtkIdState;
typedef enum {
    SZFRIENDS_GTK_GOODBYE_UNKNOWN, SZFRIENDS_GTK_GOODBYE_HANDOVER, SZFRIENDS_GTK_GOODBYE_SHUTDOWN,
    SZFRIENDS_GTK_GOODBYE_PROTOCOL_ERROR, SZFRIENDS_GTK_GOODBYE_RESET, SZFRIENDS_GTK_GOODBYE_TOO_MANY_CLIENTS
} SZFriendsGtkGoodbyeReason;
typedef enum {
    SZFRIENDS_GTK_HANDOVER_UNKNOWN, SZFRIENDS_GTK_HANDOVER_NONE, SZFRIENDS_GTK_HANDOVER_SCHEDULED
} SZFriendsGtkHandover;
typedef enum {
    SZFRIENDS_GTK_MENTION_UNKNOWN, SZFRIENDS_GTK_MENTION_FRIEND, SZFRIENDS_GTK_MENTION_YOU,
    SZFRIENDS_GTK_MENTION_STRANGER
} SZFriendsGtkMentionKind;
typedef enum {
    SZFRIENDS_GTK_THUMBNAIL_UNKNOWN, SZFRIENDS_GTK_THUMBNAIL_SENDER, SZFRIENDS_GTK_THUMBNAIL_LOCAL
} SZFriendsGtkThumbnailSource;
/* How a received file came (PROTOCOL.md § Views, received). */
typedef enum {
    SZFRIENDS_GTK_RECEIVED_SOURCE_UNKNOWN, SZFRIENDS_GTK_RECEIVED_SOURCE_FRIEND, SZFRIENDS_GTK_RECEIVED_SOURCE_LINK,
    SZFRIENDS_GTK_RECEIVED_SOURCE_DEVICE
} SZFriendsGtkReceivedSource;

/* ---- Shared objects (PROTOCOL.md § Shared objects) --------------------------------------------------- */

typedef struct { SZFriendsGtkPresence present; SZFriendsGtkAvatarKind kind; char *initials, *color; gint64 set, index;
                 char *path; } SZFriendsGtkAvatar;
typedef struct { SZFriendsGtkPresence present; SZFriendsGtkRouteKind kind; SZFriendsGtkRouteMethod method;
                 char *label; } SZFriendsGtkRoute;
/* The one checkbox a question can carry, unticked at first: ticked, the intent also carries `field`: true. */
typedef enum { SZFRIENDS_GTK_CONFIRM_FIELD_UNKNOWN, SZFRIENDS_GTK_CONFIRM_FIELD_DELETE_HISTORY } SZFriendsGtkConfirmField;
typedef struct { SZFriendsGtkPresence present; char *label; SZFriendsGtkConfirmField field; } SZFriendsGtkConfirmOption;
typedef struct { SZFriendsGtkPresence present; char *title, *body, *confirm_label, *cancel_label;
                 gboolean destructive; SZFriendsGtkConfirmOption *option; } SZFriendsGtkConfirm;
typedef struct { SZFriendsGtkPresence present; char *label, *accessibility_label; gint64 seconds; } SZFriendsGtkArm;
/* How someone nearby was found (clients that declared nearby.found): the methods seeing them now ("lan", "p2p_wifi",
 * "bluetooth", in that order), drawn with the route icons, and the words for them ("Local network and Bluetooth"). */
typedef struct { SZFriendsGtkPresence present; char **methods; char *label; } SZFriendsGtkFound;
typedef struct {
    SZFriendsGtkPresence present;
    SZFriendsGtkActionKind action;
    char *label;
    SZFriendsGtkActionStyle style;
    char *note;                 /* NULL: nothing under the button */
    SZFriendsGtkConfirm *confirm; /* ask first */
    SZFriendsGtkArm *arm;       /* second click first */
    char *path;                 /* open_file, show_file */
    SZFriendsGtkSettingsTarget settings_target;
    char *friends_id, *identity_key, *name; /* add_from_mention: the intent's own fields, sent as they are */
    char *payload, *link_id; /* add_from_link and receive_link, revoke_link: the same, for links */
    char *device_id, *join_id; /* revoke_device; approve_join and deny_join (join_profile carries friends_id) */
} SZFriendsGtkAction;
typedef struct { SZFriendsGtkPresence present; gboolean set; gint64 value; } SZFriendsGtkOptInt; /* integer|null */
/* Rich text (PROTOCOL.md § Shared objects); `mention` indexes the message item's `mentions` when set. */
typedef struct { SZFriendsGtkPresence present; char *text, *url; gboolean emphasis, match;
                 SZFriendsGtkOptInt mention; } SZFriendsGtkSegment;
typedef struct { SZFriendsGtkPresence present; gint64 badge_count;
                 char *badge_label, *accessibility_label; } SZFriendsGtkBack;
typedef struct { SZFriendsGtkPresence present; SZFriendsGtkAvatar avatar; char *name, *name_placeholder, *id_label,
                 *id_note, *friends_id, *add_label; } SZFriendsGtkFooter;
typedef struct { SZFriendsGtkPresence present; SZFriendsGtkEmptyKind kind; char *title, *body; } SZFriendsGtkEmpty;

#include "gtk/szfriends_gtk_snapshot_devices.h"

/* ---- Views (PROTOCOL.md § Views); each struct is a snapshot's `data` ---------------------------------- */

typedef struct { SZFriendsGtkPresence present; gint64 count;
                 char *label, *accessibility_label; } SZFriendsGtkBadgeSnapshot;

typedef struct { SZFriendsGtkPresence present; SZFriendsGtkBannerKind kind; char *text;
                 SZFriendsGtkAction *action; } SZFriendsGtkBanner;
typedef struct { SZFriendsGtkPresence present; char *title, *placeholder, *note;
                 char *join_label; /* opens the join view; NULL without `devices` */ } SZFriendsGtkNamePrompt;
typedef struct { SZFriendsGtkPresence present; SZFriendsGtkActionKind action; SZFriendsGtkRowIcon icon;
                 char *title; /* the word the button shows; NULL: the icon alone */
                 char *label; SZFriendsGtkArm *arm; } SZFriendsGtkRowAction;
typedef struct { SZFriendsGtkPresence present; SZFriendsGtkWaitingKind kind; char *label; } SZFriendsGtkWaiting;
typedef struct {
    SZFriendsGtkPresence present;
    char *conversation_id;
    SZFriendsGtkAvatar avatar;
    char *title, *subtitle, *time_label;
    SZFriendsGtkRoute route;
    gboolean unread;
    SZFriendsGtkWaiting *waiting;
    gboolean blocked, id_confirmed;
    char *id_confirmed_label;
    SZFriendsGtkRowStyle style;
    char *drop_label, *drop_refusal, *accessibility_label;
    SZFriendsGtkRowAction *actions;
    gsize n_actions;
    gboolean mentionable; /* clients that declared mentions: the @ picker offers this person */
    SZFriendsGtkRowKind kind; /* `you` for the You conversation */
    SZFriendsGtkAction *menu; /* clients that declared list.menu: right-click, long-press, Shift+F10, Delete */
    gsize n_menu;
    SZFriendsGtkFound *found; /* clients that declared nearby.found; NULL while the person is not nearby */
} SZFriendsGtkListRow;
typedef struct {
    SZFriendsGtkPresence present;
    char *query;
    SZFriendsGtkBanner *banner;
    SZFriendsGtkNamePrompt *name_prompt;
    SZFriendsGtkListRow *rows;
    gsize n_rows;
    SZFriendsGtkEmpty *empty;
    SZFriendsGtkFooter footer;
    SZFriendsGtkListState state;    /* device_removed: this computer was removed from the profile */
    SZFriendsGtkDeviceRemoved *removed;
    SZFriendsGtkJoinRequest *join_requests;
    gsize n_join_requests;
} SZFriendsGtkListSnapshot;

typedef struct { SZFriendsGtkPresence present; SZFriendsGtkVisibilityState state; char *title, *body, *remaining_label,
                 *remaining_accessibility_label, *deadline; SZFriendsGtkAction *action; } SZFriendsGtkVisibility;
typedef struct { SZFriendsGtkPresence present; SZFriendsGtkNearbyMethod method; SZFriendsGtkMethodState state;
                 char *label; } SZFriendsGtkMethodStatus;
typedef struct { SZFriendsGtkPresence present; char *title, *body; SZFriendsGtkAction *action; } SZFriendsGtkAlert;
typedef struct { SZFriendsGtkPresence present; char *text; SZFriendsGtkAction *action; } SZFriendsGtkNote;
typedef struct { SZFriendsGtkPresence present; SZFriendsGtkStatusKind kind; char *label; } SZFriendsGtkStatus;
typedef struct { SZFriendsGtkPresence present; char *nearby_id, *conversation_id; SZFriendsGtkAvatar avatar;
                 char *title, *subtitle, *status_label; SZFriendsGtkAction *action;
                 char *accessibility_label;
                 SZFriendsGtkFound *found; /* clients that declared nearby.found */ } SZFriendsGtkNearbyPerson;
typedef struct {
    SZFriendsGtkPresence present;
    char *query;
    SZFriendsGtkVisibility visibility;
    SZFriendsGtkMethodStatus *methods;
    gsize n_methods;
    SZFriendsGtkAlert *alert;
    SZFriendsGtkNote *note;
    SZFriendsGtkStatus *status;
    SZFriendsGtkNearbyPerson *people;
    gsize n_people;
    SZFriendsGtkEmpty *empty;
    SZFriendsGtkFooter footer;
} SZFriendsGtkNearbySnapshot;

typedef struct { SZFriendsGtkPresence present; char *title, *subtitle; SZFriendsGtkRoute route;
                 SZFriendsGtkAvatar avatar; gboolean details_available; char *accessibility_label; } SZFriendsGtkHeader;
typedef struct { SZFriendsGtkPresence present; SZFriendsGtkMessageState state; char *label; } SZFriendsGtkMessageStatus;
typedef struct { SZFriendsGtkPresence present; char *name, *kind_label, *size_label; gint64 size_bytes;
                 char *path, *type_identifier, *extension; } SZFriendsGtkFileInfo;
/* A file's preview (PROTOCOL.md § Thumbnails): a PNG in the helper's cache, the only file views load. */
typedef struct { SZFriendsGtkPresence present; char *path; gint64 width, height;
                 SZFriendsGtkThumbnailSource source; } SZFriendsGtkThumbnail;
/* PROTOCOL.md § Mentions: what a stranger's mention shows when clicked, and who a mention link names. */
typedef struct { SZFriendsGtkPresence present; char *title, *id_label, *status_label, *conversation_id;
                 SZFriendsGtkAction *actions; gsize n_actions; } SZFriendsGtkMentionCard;
typedef struct { SZFriendsGtkPresence present; char *url; SZFriendsGtkMentionKind kind; char *label, *tooltip,
                 *conversation_id; SZFriendsGtkMentionCard *card; } SZFriendsGtkMention;
typedef struct { SZFriendsGtkPresence present; double fraction; gboolean determinate;
                 char *accessibility_label; } SZFriendsGtkProgress;
/* One history item. Which fields apply depends on `kind` (PROTOCOL.md type.item); the rest stay empty. */
typedef struct {
    SZFriendsGtkPresence present;
    SZFriendsGtkItemKind kind;
    char *item_id;
    char *label;                /* day */
    char *time_label;           /* NULL for a message within 5 minutes of the one before */
    SZFriendsGtkDirection direction;
    char *text;                 /* message, event */
    SZFriendsGtkTextFormat text_format;
    SZFriendsGtkSegment *segments;
    gsize n_segments;
    SZFriendsGtkMessageStatus *status;
    char *assistant_label;
    char *transfer_id;
    SZFriendsGtkFileInfo file;
    char *meta_label;
    SZFriendsGtkTransferState state;
    char *status_label, *route_note;
    SZFriendsGtkProgress *progress;
    SZFriendsGtkThumbnail *thumbnail; /* transfer: NULL draws the type's icon */
    SZFriendsGtkAction *actions;
    gsize n_actions;
    SZFriendsGtkMention *mentions;    /* message: the mention links in `text`, by index */
    gsize n_mentions;
    gboolean highlighted;
    char *accessibility_label;
} SZFriendsGtkConversationItem;
typedef struct {
    SZFriendsGtkPresence present;
    SZFriendsGtkRequestDirection direction;
    SZFriendsGtkAvatar avatar;
    char *title, *subtitle, *code_prompt, *comparison_code, *comparison_code_accessibility_label;
    SZFriendsGtkAction *actions;
    gsize n_actions;
    char *footnote;
} SZFriendsGtkRequestCard;
typedef struct {
    SZFriendsGtkPresence present;
    gboolean visible, enabled;
    char *placeholder;
    SZFriendsGtkSegment *hint;
    gsize n_hint;
    char *send_label, *note;
    gboolean accepts_drops;
    gint64 max_text_bytes;
    char *mention_note; /* clients that declared mentions: the line under the @ picker */
} SZFriendsGtkComposer;
typedef struct {
    SZFriendsGtkPresence present;
    char *conversation_id;
    SZFriendsGtkHeader header;
    SZFriendsGtkBack back;
    char *search_placeholder;
    gboolean has_earlier;
    SZFriendsGtkConversationItem *items;
    gsize n_items;
    char *highlight_item_id;
    SZFriendsGtkRequestCard *request;
    SZFriendsGtkComposer composer;
} SZFriendsGtkConversationSnapshot;

typedef struct { SZFriendsGtkPresence present; SZFriendsGtkVerificationState state; char *label, *body,
                 *comparison_code; SZFriendsGtkAction *action; } SZFriendsGtkVerification;
typedef struct { SZFriendsGtkPresence present; gboolean available, enabled;
                 char *title, *body; } SZFriendsGtkAutoAccept;
typedef struct { SZFriendsGtkPresence present; char *label;
                 gint64 count; SZFriendsGtkAction *action; } SZFriendsGtkReceived;
typedef struct { SZFriendsGtkPresence present; char *title, *body; SZFriendsGtkAction *actions;
                 gsize n_actions; } SZFriendsGtkKeyChange;
typedef struct {
    SZFriendsGtkPresence present;
    char *conversation_id, *title;
    SZFriendsGtkBack back;
    SZFriendsGtkAvatar avatar;
    SZFriendsGtkRoute route;
    char *friends_id, *id_label;
    gboolean id_confirmed;
    char *id_confirmed_label, *copy_id_accessibility_label;
    SZFriendsGtkVerification verification;
    SZFriendsGtkAutoAccept auto_accept;
    SZFriendsGtkReceived *received;
    SZFriendsGtkKeyChange *key_change;
    SZFriendsGtkAction *actions;
    gsize n_actions;
} SZFriendsGtkDetailsSnapshot;

typedef struct { SZFriendsGtkPresence present; char *label, *value, *placeholder;
                 gint64 max_length; } SZFriendsGtkProfileName;
typedef struct { SZFriendsGtkPresence present; SZFriendsGtkAvatar avatar; char *choose_label, *own_picture_label;
                 gint64 animal_set; SZFriendsGtkOptInt selected_index; } SZFriendsGtkProfilePicture;
typedef struct { SZFriendsGtkPresence present; char *label, *friends_id; SZFriendsGtkIdState state; char *note,
                 *copy_label, *qr_label, *qr_payload; } SZFriendsGtkProfileId;
typedef struct { SZFriendsGtkPresence present; char *label, *placeholder, *button_label, *hint;
                  } SZFriendsGtkProfileAdd;
/* Your links (PROTOCOL.md § Links), present while the helper announces `links`. */
typedef struct { SZFriendsGtkPresence present; char *label, *url, *note, *copy_label;
                 SZFriendsGtkAction reset; } SZFriendsGtkFriendLink;
typedef struct { SZFriendsGtkPresence present; char *link_id, *file_name, *downloads_label, *expires_label;
                 SZFriendsGtkAction revoke; } SZFriendsGtkDownloadLink;
typedef struct { SZFriendsGtkPresence present; char *title; SZFriendsGtkFriendLink friend_link; char *downloads_label,
                 *downloads_empty; SZFriendsGtkDownloadLink *downloads; gsize n_downloads; } SZFriendsGtkProfileLinks;
typedef struct {
    SZFriendsGtkPresence present;
    char *title;
    SZFriendsGtkBack back;
    SZFriendsGtkProfileName name;
    SZFriendsGtkProfilePicture picture;
    SZFriendsGtkProfileId id;
    SZFriendsGtkProfileAdd add;
    SZFriendsGtkProfileLinks *links; /* NULL without `links` */
    SZFriendsGtkProfileDevices *devices; /* NULL without `devices` */
} SZFriendsGtkProfileSnapshot;

typedef struct { SZFriendsGtkPresence present; char *label, *note, *value, *placeholder; } SZFriendsGtkSettingsName;
typedef struct { SZFriendsGtkPresence present; char *label, *note, *friends_id, *copy_label; } SZFriendsGtkSettingsId;
/* Where received files go (PROTOCOL.md § settings): `value`, `path` and `change` with the helper's received.folder. */
typedef struct { SZFriendsGtkPresence present; char *label, *value, *note, *path;
                 SZFriendsGtkAction *action, *change; } SZFriendsGtkSettingsReceived;
typedef struct { SZFriendsGtkPresence present; char *conversation_id, *title; SZFriendsGtkAvatar avatar;
                 gboolean enabled; } SZFriendsGtkSettingsFriend;
typedef struct { SZFriendsGtkPresence present; char *label, *note, *action_label; SZFriendsGtkSettingsFriend *friends;
                 gsize n_friends; } SZFriendsGtkSettingsAutoAccept;
typedef struct { SZFriendsGtkPresence present; char *label, *note, *action_label;
                 SZFriendsGtkConfirm confirm; } SZFriendsGtkSettingsConfirmed;
/* The helper's Nearby line (PROTOCOL.md § settings): what Nearby can do, and the one button that fixes it. */
typedef struct { SZFriendsGtkPresence present; char *label, *note;
                 SZFriendsGtkAction *action; } SZFriendsGtkSettingsNearby;
typedef struct {
    SZFriendsGtkPresence present;
    SZFriendsGtkSettingsName name;
    SZFriendsGtkSettingsId id;
    SZFriendsGtkSettingsReceived received;
    SZFriendsGtkSettingsAutoAccept auto_accept;
    SZFriendsGtkSettingsConfirmed history, reset;
    SZFriendsGtkSettingsNearby *nearby; /* NULL without `nearby` */
} SZFriendsGtkSettingsSnapshot;

typedef struct { SZFriendsGtkPresence present; char *message_id;
                 SZFriendsGtkMessageStatus status; } SZFriendsGtkMessageEntry;
typedef struct { SZFriendsGtkPresence present; SZFriendsGtkMessageEntry *messages;
                 gsize n_messages; } SZFriendsGtkMessageStatusSnapshot;

/* Files this computer received, newest first, for a host's own list (PROTOCOL.md § Views, received). */
typedef struct { SZFriendsGtkPresence present; char *transfer_id, *path, *file_name; gint64 received_at;
                 SZFriendsGtkReceivedSource source; } SZFriendsGtkReceivedFile;
typedef struct { SZFriendsGtkPresence present; SZFriendsGtkReceivedFile *files; gsize n_files; }
    SZFriendsGtkReceivedSnapshot;

/* ---- Frames and results the views read (PROTOCOL.md § Frames, § Results) ------------------------------ */

#include "gtk/szfriends_gtk_snapshot_frames.h"

/* ---- Parsing ----------------------------------------------------------------------------------------- */

typedef struct _SZFriendsGtkType SZFriendsGtkType; /* a schema (szfriends_gtk_schema.h) */

/* Parses `object` (a snapshot's data, a frame, a reply's result) into a new struct of `type`; never NULL for a
 * non-NULL object: missing fields stay empty. Free with szfriends_gtk_value_free(). */
gpointer szfriends_gtk_value_parse(const SZFriendsGtkType *type, JsonObject *object);
void szfriends_gtk_value_free(const SZFriendsGtkType *type, gpointer value);
/* Parses one frame line as the helper sent it; NULL when it is not a JSON object. */
JsonObject *szfriends_gtk_json_object_from_text(const char *text, gssize length);

/* The schema of a view's data by its name ("list"), or NULL for a view this build does not know. */
const SZFriendsGtkType *szfriends_gtk_view_type(const char *view);

extern const SZFriendsGtkType szfriends_gtk_type_badge_snapshot, szfriends_gtk_type_list_snapshot,
    szfriends_gtk_type_nearby_snapshot, szfriends_gtk_type_conversation_snapshot, szfriends_gtk_type_details_snapshot,
    szfriends_gtk_type_profile_snapshot, szfriends_gtk_type_settings_snapshot,
    szfriends_gtk_type_message_status_snapshot, szfriends_gtk_type_welcome, szfriends_gtk_type_reply,
    szfriends_gtk_type_goodbye, szfriends_gtk_type_snapshot_frame, szfriends_gtk_type_error,
    szfriends_gtk_type_subscribe_result, szfriends_gtk_type_send_result, szfriends_gtk_type_add_by_id_result,
    szfriends_gtk_type_visibility_result, szfriends_gtk_type_search_result, szfriends_gtk_type_open_link_result,
    szfriends_gtk_type_download_link_result, szfriends_gtk_type_join_snapshot, szfriends_gtk_type_received_snapshot;

/* Typed shorthands: szfriends_gtk_list_snapshot_parse(data), szfriends_gtk_list_snapshot_free(snapshot). */
#define SZFRIENDS_GTK_DECLARE_PARSE(name, Type)                                                                  \
    static inline Type *szfriends_gtk_##name##_parse(JsonObject *object) {                                       \
        return (Type *)szfriends_gtk_value_parse(&szfriends_gtk_type_##name, object);                           \
    }                                                                                                            \
    static inline void szfriends_gtk_##name##_free(Type *value) {                                                \
        szfriends_gtk_value_free(&szfriends_gtk_type_##name, value);                                            \
    }
SZFRIENDS_GTK_DECLARE_PARSE(badge_snapshot, SZFriendsGtkBadgeSnapshot)
SZFRIENDS_GTK_DECLARE_PARSE(list_snapshot, SZFriendsGtkListSnapshot)
SZFRIENDS_GTK_DECLARE_PARSE(nearby_snapshot, SZFriendsGtkNearbySnapshot)
SZFRIENDS_GTK_DECLARE_PARSE(conversation_snapshot, SZFriendsGtkConversationSnapshot)
SZFRIENDS_GTK_DECLARE_PARSE(details_snapshot, SZFriendsGtkDetailsSnapshot)
SZFRIENDS_GTK_DECLARE_PARSE(profile_snapshot, SZFriendsGtkProfileSnapshot)
SZFRIENDS_GTK_DECLARE_PARSE(settings_snapshot, SZFriendsGtkSettingsSnapshot)
SZFRIENDS_GTK_DECLARE_PARSE(message_status_snapshot, SZFriendsGtkMessageStatusSnapshot)
SZFRIENDS_GTK_DECLARE_PARSE(join_snapshot, SZFriendsGtkJoinSnapshot)
SZFRIENDS_GTK_DECLARE_PARSE(received_snapshot, SZFriendsGtkReceivedSnapshot)
SZFRIENDS_GTK_DECLARE_PARSE(welcome, SZFriendsGtkWelcome)
SZFRIENDS_GTK_DECLARE_PARSE(reply, SZFriendsGtkReply)
SZFRIENDS_GTK_DECLARE_PARSE(goodbye, SZFriendsGtkGoodbye)
SZFRIENDS_GTK_DECLARE_PARSE(snapshot_frame, SZFriendsGtkSnapshotFrame)
SZFRIENDS_GTK_DECLARE_PARSE(subscribe_result, SZFriendsGtkSubscribeResult)
SZFRIENDS_GTK_DECLARE_PARSE(send_result, SZFriendsGtkSendResult)
SZFRIENDS_GTK_DECLARE_PARSE(add_by_id_result, SZFriendsGtkAddByIdResult)
SZFRIENDS_GTK_DECLARE_PARSE(visibility_result, SZFriendsGtkVisibilityResult)
SZFRIENDS_GTK_DECLARE_PARSE(search_result, SZFriendsGtkSearchResult)
SZFRIENDS_GTK_DECLARE_PARSE(open_link_result, SZFriendsGtkOpenLinkResult)
SZFRIENDS_GTK_DECLARE_PARSE(download_link_result, SZFriendsGtkDownloadLinkResult)

/* Enum names as the protocol spells them ("accept_offer"), NULL for 0 or out of range: an intent's type. */
const char *szfriends_gtk_action_name(SZFriendsGtkActionKind action);

G_END_DECLS

#endif /* SZFRIENDS_GTK_SNAPSHOT_H */
