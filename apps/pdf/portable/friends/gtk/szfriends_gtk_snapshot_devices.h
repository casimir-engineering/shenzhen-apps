/* Shenzhen Friends GTK views: one profile on several computers as plain C structs (PROTOCOL.md § Devices, § Joining).
 *
 * Internal; included by szfriends_gtk_snapshot.h after the shared objects, under the same conventions (a `string|null`
 * field is NULL for null, an enum is 0 when unknown, arrays carry their count). Present only while the helper
 * announces `devices`; without it the pointers stay NULL and the arrays empty. */

#ifndef SZFRIENDS_GTK_SNAPSHOT_DEVICES_H
#define SZFRIENDS_GTK_SNAPSHOT_DEVICES_H

typedef enum { SZFRIENDS_GTK_LIST_STATE_UNSET, SZFRIENDS_GTK_LIST_NORMAL, SZFRIENDS_GTK_LIST_DEVICE_REMOVED
} SZFriendsGtkListState;
typedef enum { SZFRIENDS_GTK_ROW_KIND_UNSET, SZFRIENDS_GTK_ROW_PERSON, SZFRIENDS_GTK_ROW_YOU } SZFriendsGtkRowKind;
typedef enum {
    SZFRIENDS_GTK_DEVICE_UNKNOWN, SZFRIENDS_GTK_DEVICE_CONNECTED, SZFRIENDS_GTK_DEVICE_NOT_CONNECTED,
    SZFRIENDS_GTK_DEVICE_NEVER_CONNECTED
} SZFriendsGtkDeviceState;
typedef enum {
    SZFRIENDS_GTK_JOIN_REQUEST_UNKNOWN, SZFRIENDS_GTK_JOIN_REQUEST_WAITING, SZFRIENDS_GTK_JOIN_REQUEST_APPROVED
} SZFriendsGtkJoinRequestState;
typedef enum {
    SZFRIENDS_GTK_JOIN_UNKNOWN, SZFRIENDS_GTK_JOIN_IDLE, SZFRIENDS_GTK_JOIN_WAITING, SZFRIENDS_GTK_JOIN_CHECKING,
    SZFRIENDS_GTK_JOIN_WRONG_CODE, SZFRIENDS_GTK_JOIN_NOT_REACHED, SZFRIENDS_GTK_JOIN_DENIED,
    SZFRIENDS_GTK_JOIN_EXPIRED, SZFRIENDS_GTK_JOIN_TOO_MANY_ATTEMPTS, SZFRIENDS_GTK_JOIN_JOINED,
    SZFRIENDS_GTK_JOIN_UNAVAILABLE
} SZFriendsGtkJoinState;

/* The profile's "Your computers": this computer first, then the others by when they joined. */
typedef struct { SZFriendsGtkPresence present; char *label, *placeholder, *button_label;
                 gint64 max_bytes; } SZFriendsGtkDeviceRename;
typedef struct {
    SZFriendsGtkPresence present;
    char *device_id, *name, *system, *last_connected, *detail;
    gboolean this_computer;
    SZFriendsGtkDeviceState state;
    char *accessibility_label;
    SZFriendsGtkDeviceRename *rename; /* this computer's row only */
    SZFriendsGtkAction *remove;       /* revoke_device with its confirm; NULL on this computer's row */
} SZFriendsGtkDeviceRow;
/* How to add another computer or phone: steps in order, one naming the ID; NULL on a removed computer. */
typedef struct { SZFriendsGtkPresence present; char *title; char **steps; char *friends_id; } SZFriendsGtkDeviceAdd;
typedef struct { SZFriendsGtkPresence present; char *title; SZFriendsGtkDeviceAdd *add; SZFriendsGtkDeviceRow *rows;
                 gsize n_rows; } SZFriendsGtkProfileDevices;
/* The list's offer to use the person's existing profile here: what it does, and its button. */
typedef struct { SZFriendsGtkPresence present; char *note; SZFriendsGtkAction action; } SZFriendsGtkJoinOffer;
/* Settings' row for it (PROTOCOL.md § settings `join`): its heading, what it does, and the button. */
typedef struct { SZFriendsGtkPresence present; char *label, *note; SZFriendsGtkAction action; } SZFriendsGtkSettingsJoin;

/* Above the list: this computer was removed (with Start Over), and the requests to join waiting here. */
typedef struct { SZFriendsGtkPresence present; char *title, *body;
                 SZFriendsGtkAction action; } SZFriendsGtkDeviceRemoved;
typedef struct {
    SZFriendsGtkPresence present;
    char *join_id;
    SZFriendsGtkJoinRequestState state;
    char *title, *subtitle, *code, *code_accessibility_label, *code_note;
    SZFriendsGtkAction *actions;
    gsize n_actions;
    char *accessibility_label;
} SZFriendsGtkJoinRequest;

/* The new computer's side: snapshot.join. */
typedef struct { SZFriendsGtkPresence present; char *placeholder, *button; } SZFriendsGtkJoinIdField;
typedef struct { SZFriendsGtkPresence present; gint64 length; char *placeholder, *button;
                 gboolean enabled; } SZFriendsGtkJoinCodeField;
typedef struct {
    SZFriendsGtkPresence present;
    SZFriendsGtkJoinState state;
    char *title, *message, *friends_id;
    SZFriendsGtkJoinIdField *id_field;
    SZFriendsGtkJoinCodeField *code_field;
    char *error;
    SZFriendsGtkAction *actions;
    gsize n_actions;
} SZFriendsGtkJoinSnapshot;

#endif /* SZFRIENDS_GTK_SNAPSHOT_DEVICES_H */
