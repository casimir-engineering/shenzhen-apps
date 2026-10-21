/* Shenzhen Friends client library: the one way an app talks to the Friends helper.
 *
 * C99 and libc only (plus the vendored cJSON inside the implementation), so the AppKit views in
 * ShenzhenPDF and the GTK4 views in Shenzhen Files link the same framing, socket rules, reconnection and
 * version negotiation instead of each reimplementing them. The wire contract is portable/friends/PROTOCOL.md;
 * this header is its C binding. Nothing here draws or decides what to show: helper frames reach the host as
 * JSON text, and the host's toolkit parses them (NSJSONSerialization, json-glib).
 *
 * Threading: the library never calls the host from a thread of its own. A client is driven from one thread at a
 * time (normally the host's main loop): watch szfriends_client_fd() for readability and call
 * szfriends_client_on_readable(), and call szfriends_client_tick() no later than szfriends_client_next_tick_ms()
 * says. WHY: GTK and AppKit both integrate file descriptors into their run loops natively (GSource, dispatch
 * sources), and a library thread calling back into views would force every host to hop threads on every frame.
 * The one thread it does start is a detached reaper per spawned helper (ADR 0002), which only waits for that
 * child and touches no client state.
 *
 * Launch: the one function meant for a background queue at app launch is szfriends_spawn_helper(). It never
 * blocks on the helper; the reader's first window must not wait for Friends (brief § Product contract). */

#ifndef SZFRIENDS_CLIENT_H
#define SZFRIENDS_CLIENT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Protocol version this library speaks, and the oldest major it still accepts (one major back). */
#define SZFRIENDS_PROTOCOL_MAJOR 1
#define SZFRIENDS_PROTOCOL_MINOR 0
#define SZFRIENDS_PROTOCOL_MIN_MAJOR 1

/* A frame is one JSON object plus "\n". The cap excludes the newline. Same cap as the Collection pipe,
 * which has carried 8 MB frames without trouble; a picture upload (5 MiB, base64) is the largest intent. */
#define SZFRIENDS_MAX_FRAME_BYTES ((size_t)8 * 1024 * 1024)

/* Hello limits the helper enforces (PROTOCOL.md § Handshake): app strings and each listed item are at most 128
 * characters; `open_formats` lists every extension the app opens in place, about 130 for ShenzhenPDF (documents
 * and source files), so it allows a few times that. A hello over a limit is refused, and the app never connects. */
#define SZFRIENDS_MAX_HELLO_STRING 128
#define SZFRIENDS_MAX_OPEN_FORMATS 512

/* sockaddr_un.sun_path is 104 bytes on macOS including the terminating NUL. */
#define SZFRIENDS_SUN_PATH_MAX 104

/* Large enough for any state directory path this library accepts (PATH_MAX on macOS). */
#define SZFRIENDS_PATH_CAP 1024

/* Environment overrides. SZFRIENDS_STATE_DIR moves all Friends state (tests and probes); when it is set the
 * helper defaults to a file key store and never touches the Keychain unless SZFRIENDS_KEY_STORE=keychain. Builds
 * signed with a team ignore both, in the helper and in this library (szfriends_set_signing_policy()). */
#define SZFRIENDS_ENV_STATE_DIR "SZFRIENDS_STATE_DIR"
#define SZFRIENDS_ENV_KEY_STORE "SZFRIENDS_KEY_STORE"
/* Where received files go when no folder was chosen (tests; PROTOCOL.md § Views, settings). Ignored, like the two
 * above, by team-signed builds. */
#define SZFRIENDS_ENV_DOWNLOADS_DIR "SZFRIENDS_DOWNLOADS_DIR"

typedef enum szfriends_status {
    SZFRIENDS_OK = 0,
    SZFRIENDS_ERR_INVALID_ARGUMENT, /* NULL, empty, or malformed input from the caller */
    SZFRIENDS_ERR_PATH_TOO_LONG,    /* even the fallback socket path does not fit sun_path */
    SZFRIENDS_ERR_UNSAFE_DIRECTORY, /* socket directory not owned by us, not 0700, or a symlink */
    SZFRIENDS_ERR_NO_HELPER,        /* nothing listening (ENOENT / ECONNREFUSED) */
    SZFRIENDS_ERR_PEER_UID,         /* the listening process belongs to another user */
    SZFRIENDS_ERR_PROTOCOL,         /* malformed frame, or a frame that breaks PROTOCOL.md */
    SZFRIENDS_ERR_FRAME_TOO_LARGE,  /* a frame over SZFRIENDS_MAX_FRAME_BYTES, either direction */
    SZFRIENDS_ERR_VERSION,          /* no protocol major in common with the running helper */
    SZFRIENDS_ERR_NOT_READY,        /* send attempted before the welcome arrived, or while reconnecting */
    SZFRIENDS_ERR_CLOSED,           /* the client was stopped */
    SZFRIENDS_ERR_IO,               /* any other system call failure; errno is preserved */
    SZFRIENDS_ERR_NO_MEMORY,
    SZFRIENDS_ERR_PEER_SIGNATURE    /* team-signed app: the listening process is not signed by the same team */
} szfriends_status;

/* Stable, English, developer-facing name for logs ("no_helper"). Never shown to users. */
const char *szfriends_status_name(szfriends_status status);

/* ---- Paths (PROTOCOL.md § Transport) ------------------------------------------------------------- */

/* Writes the Friends state directory: $SZFRIENDS_STATE_DIR when set and absolute and this build honours overrides
 * (szfriends_environment_overrides_allowed()), otherwise "$HOME/Library/Application Support/Shenzhen Friends".
 * Does not create it. */
szfriends_status szfriends_default_state_dir(char *out, size_t out_cap);

/* ---- Signing policy (ADR 0002 § Peer checks) ------------------------------------------------------ */

/* Asks whether the process behind `audit_token` (the helper's LOCAL_PEERTOKEN: `token_length` bytes, an
 * audit_token_t on macOS) satisfies the code requirement `requirement`. Return false on any failure. This library
 * is libc only and cannot read code signatures, so the host supplies the check, built on Security.framework:
 * SecCodeCopyGuestWithAttributes with kSecGuestAttributeAudit, then SecCodeCheckValidity against
 * SecRequirementCreateWithString(requirement). Called on whichever thread connects or spawns. */
typedef bool (*szfriends_peer_verifier)(void *context, const void *audit_token, size_t token_length,
                                        const char *requirement);

/* Tells the library the Team ID in this app's own code signature (SecCodeCopySelf, kSecCodeInfoTeamIdentifier),
 * once at launch, before any other call; NULL or "" for ad-hoc, test and unsigned builds, which keep the uid check
 * and honour SZFRIENDS_STATE_DIR. With a team set, the library
 *   - ignores SZFRIENDS_STATE_DIR: another process running as the person could set it for the next launch
 *     (launchctl setenv) and point the app at a socket of its own, which would then receive every message, file
 *     path and picture. The signed helper ignores it too, so honouring it would only find nobody;
 *   - accepts a helper only when `verifier` says its audit token satisfies
 *     anchor apple generic and certificate leaf[subject.OU] = "<team>"
 *     the requirement the helper applies to its clients, so both apps of one team pass and nothing else does.
 *     A malformed team (anything but 10 capitals and digits), a missing token or a missing verifier refuses every
 *     helper (SZFRIENDS_ERR_PEER_SIGNATURE): a signed app never falls back to the uid check.
 * A malformed team still counts as signed and returns SZFRIENDS_ERR_INVALID_ARGUMENT. Process-wide, because
 * spawning and the default directory have no client to hang it on; thread-safe; a later call replaces the policy
 * (tests). Explicit config.state_dir and szfriends_spawn_helper(state_dir) are the host's own choice and still
 * apply. */
szfriends_status szfriends_set_signing_policy(const char *team_identifier, szfriends_peer_verifier verifier,
                                              void *context);

/* Whether this process honours SZFRIENDS_* environment overrides: only while no team is set. The C form of the
 * identity area's SZFriendsEnvironmentOverridesAllowed(), which the helper applies to itself. */
bool szfriends_environment_overrides_allowed(void);

/* 64-bit FNV-1a, used only to name the short fallback socket directory. Not a security boundary: the
 * fallback directory is owner-checked and 0700. Test vector in PROTOCOL.md. */
uint64_t szfriends_fnv1a64(const void *bytes, size_t length);

/* Writes the socket path for a state directory, byte-identical in helper and clients:
 *   primary  "<canonical state dir>/ipc/helper.sock"           when it fits sun_path;
 *   fallback "<per-user temp dir>/szfriends-<16 hex>/helper.sock" otherwise (deep test directories).
 * The state directory is canonicalized by resolving its deepest existing ancestor with realpath() and
 * appending the missing components, so a client that runs before the helper has created the directory
 * still agrees with it (/var is a symlink to /private/var). Creates nothing. Reports which form was chosen. */
szfriends_status szfriends_socket_path(const char *state_dir, char *out, size_t out_cap, bool *used_fallback);

/* Checks the directory that holds socket_path, creating it 0700 first when `create` is true (the helper):
 * it must be a real directory (lstat, never a symlink), owned by this uid, with no group or world permission.
 * SZFRIENDS_ERR_UNSAFE_DIRECTORY otherwise. The helper calls it before binding and clients before connecting,
 * so both apply exactly one rule (PROTOCOL.md § Transport, directory safety). An existing directory is never
 * chmod-ed into shape: a wrong mode means someone else may have made it. With `create` false, a directory that
 * does not exist yet is SZFRIENDS_ERR_NO_HELPER (nothing can be listening in it), not unsafe. */
szfriends_status szfriends_socket_directory_check(const char *socket_path, bool create);

/* ---- Framing (pure; shared by the helper, this client and the fake helper) ------------------------ */

typedef struct szfriends_line_reader szfriends_line_reader;

szfriends_line_reader *szfriends_line_reader_new(size_t max_frame_bytes);
void szfriends_line_reader_free(szfriends_line_reader *reader);

/* Appends received bytes. Fails with SZFRIENDS_ERR_FRAME_TOO_LARGE as soon as a pending line exceeds the cap,
 * before buffering the excess, so a peer cannot make the reader allocate without bound. */
szfriends_status szfriends_line_reader_push(szfriends_line_reader *reader, const void *bytes, size_t length);

/* Pops the next complete line without its "\n", NUL-terminated and valid until the next call on this
 * reader. Sets *line to NULL when no complete line is buffered. Empty lines are skipped. */
szfriends_status szfriends_line_reader_next(szfriends_line_reader *reader, const char **line, size_t *length);

/* ---- Spawning the helper ------------------------------------------------------------------------ */

/* Connect-or-spawn (ADR 0002): tries the socket once without waiting; when a helper answers it closes that
 * connection, sets *pid_out to 0 and spawns nothing. A listener the signing policy refuses counts as no helper here,
 * once per launch, so ours can take the path from it. Otherwise starts helper_path with posix_spawn
 * (POSIX_SPAWN_SETSID so it outlives the app's process group, POSIX_SPAWN_CLOEXEC_DEFAULT so it inherits no
 * descriptor, stdin and stdout on /dev/null) with SZFRIENDS_STATE_DIR set to state_dir when given, and returns at
 * once; it never waits for the helper to bind. Safe from any number of windows and apps at once: a duplicate
 * helper finds helper.lock held and exits immediately (PROTOCOL.md § Lifecycle). state_dir NULL means the
 * default. A detached thread reaps the child, so a helper that exits never lingers as a zombie of the app.
 * stderr also goes to /dev/null: a helper holding the app's stderr pipe would keep a parent that reads it (a
 * test runner, a terminal pipeline) waiting until the helper exits; the helper writes its own log.
 * On macOS it refuses to run on the main thread (SZFRIENDS_ERR_INVALID_ARGUMENT, nothing spawned): the launch
 * gate allows the reader no Friends work on the main thread, and failing loudly catches a host that forgot. */
szfriends_status szfriends_spawn_helper(const char *helper_path, const char *state_dir, pid_t *pid_out);

/* ---- Client --------------------------------------------------------------------------------------- */

typedef struct szfriends_client szfriends_client;

typedef enum szfriends_connection_state {
    SZFRIENDS_CONNECTION_IDLE = 0,    /* created, not started */
    SZFRIENDS_CONNECTION_CONNECTING,  /* connect() in progress, or spawning the helper */
    SZFRIENDS_CONNECTION_HANDSHAKING, /* hello sent, waiting for welcome */
    SZFRIENDS_CONNECTION_READY,       /* welcome received; intents may be sent */
    SZFRIENDS_CONNECTION_WAITING,     /* disconnected; retrying with backoff (includes a helper handover) */
    SZFRIENDS_CONNECTION_INCOMPATIBLE /* no common protocol major and no newer helper to hand over to */
} szfriends_connection_state;

/* The only user-facing strings outside the helper's catalog: what the views show while no helper answers,
 * when nobody can supply strings. English; written for the person waiting, e.g. "Starting Friends…". "" for
 * READY and IDLE, where nothing needs saying. Never NULL. Hosts with a client prefer szfriends_client_state_text(),
 * which names the app where the person has to act. */
const char *szfriends_connection_state_text(szfriends_connection_state state);

typedef struct szfriends_client_config {
    const char *state_dir;   /* NULL: szfriends_default_state_dir() */
    const char *helper_path; /* this app's embedded helper executable; NULL: never spawn */
    /* Identity of the embedded helper, sent in hello so an older running helper can hand over. */
    const char *helper_version;
    uint64_t helper_build_number;
    int helper_protocol_major;
    int helper_protocol_minor;
    /* hello.client fields (PROTOCOL.md § Handshake). */
    const char *app_id;      /* "com.intuition.shenzhenpdf" */
    const char *app_name;    /* "ShenzhenPDF"; the helper names the app with it in strings */
    const char *app_version; /* "26.10.12" */
    const char *toolkit;     /* "appkit" or "gtk4" */
    const char *reveal_in;   /* name of the file manager, "Finder": "Show in Finder" */
    const char *locale;      /* BCP 47, "en-GB"; NULL: "en" */
    const char *const *capabilities; /* client capability strings (PROTOCOL.md § Capabilities) */
    size_t capability_count;
    const char *const *open_formats; /* lowercase extensions this app opens in place */
    size_t open_format_count;
    /* Every helper frame, including welcome, as one JSON object without the newline. `json` is valid only
     * during the call. Called from szfriends_client_on_readable() or szfriends_client_tick() on the caller's
     * thread. Reply correlation: when a connection drops while intents still wait for their replies, the
     * library delivers one synthesized reply per waiting intent, {"type":"reply","re":"<id>","ok":false,
     * "error":{"code":"connection_lost","message":null,"retryable":true,"details":{}}}, after the state change,
     * so every intent's reply handler runs exactly once. The intent may or may not have taken effect;
     * send_message and send_files are safe to retry with the same client_token. */
    void (*on_frame)(void *context, const char *json, size_t length);
    /* Connection state changes. After every transition to READY the host re-sends its subscriptions:
     * subscription ids never survive a reconnect. */
    void (*on_state)(void *context, szfriends_connection_state state);
    void *context;
    /* hello.client.url_scheme: the app's URL scheme ("shenzhenpdf"), where a click on a Friends notification opens
     * it (PROTOCOL.md § Notifications). NULL: omitted. Last, so hosts that predate it still initialise the rest. */
    const char *url_scheme;
} szfriends_client_config;

/* Copies everything it needs from config; the caller may free its strings afterwards. NULL when config is NULL,
 * when app_id, app_name, app_version, toolkit or reveal_in is NULL, or when memory runs out. */
szfriends_client *szfriends_client_new(const szfriends_client_config *config);
/* Never call it from inside on_frame or on_state; stop the client there instead. */
void szfriends_client_free(szfriends_client *client);

/* Begins connecting (non-blocking). If nothing listens and helper_path is set, spawns the helper and keeps
 * retrying with jittered backoff (first retry 50 ms, cap 2 s), also across helper restarts and handovers.
 * Spawning runs on a detached thread, never on the caller's: the host may call this from its main thread.
 * The first attempt runs at once; a condition worth logging (SZFRIENDS_ERR_UNSAFE_DIRECTORY,
 * SZFRIENDS_ERR_PATH_TOO_LONG, SZFRIENDS_ERR_PEER_UID, SZFRIENDS_ERR_PEER_SIGNATURE) is returned while the client
 * keeps retrying; it never spawns for a listener the signing policy refused. */
szfriends_status szfriends_client_start(szfriends_client *client);

/* Sends `disable` when connected and friends_disabled is true (PROTOCOL.md § Intents), then closes and returns
 * to IDLE. The helper keeps running for other apps; it exits at once if this was its last client with Friends
 * on. Intents still waiting for replies are dropped without callbacks: the host is tearing down. Safe to call
 * from inside on_frame and on_state. */
szfriends_status szfriends_client_stop(szfriends_client *client, bool friends_disabled);

szfriends_connection_state szfriends_client_state(const szfriends_client *client);

/* szfriends_connection_state_text() for this client's current state, with the app named where the person has to
 * do something: "...Update ShenzhenPDF to use Friends." when INCOMPATIBLE (config.app_name). Owned by the client,
 * valid until it is freed; "" when client is NULL. Safe to call from on_state. */
const char *szfriends_client_state_text(const szfriends_client *client);

/* The descriptor to watch for readability, or -1 while not connected (watch nothing; keep ticking). */
int szfriends_client_fd(const szfriends_client *client);

/* Reads and dispatches every complete frame. Returns an error only for conditions the host should log; the
 * client has already scheduled its own reconnection by then. */
szfriends_status szfriends_client_on_readable(szfriends_client *client);

/* Runs reconnection and handover timers, and flushes output the socket could not take at once. now_ms is any
 * monotonic millisecond clock, the same one on every call; szfriends_monotonic_ms() is a good choice. Events
 * that happen between ticks (a disconnect seen in on_readable) are scheduled from the last now_ms plus the time
 * elapsed since, measured with CLOCK_MONOTONIC. */
void szfriends_client_tick(szfriends_client *client, uint64_t now_ms);

/* Milliseconds until the next tick is due, 0 when overdue, or -1 when nothing is scheduled. While output is
 * waiting for socket space it returns a few milliseconds, since the library does not ask to watch writability. */
int64_t szfriends_client_next_tick_ms(const szfriends_client *client, uint64_t now_ms);

/* CLOCK_MONOTONIC in milliseconds. */
uint64_t szfriends_monotonic_ms(void);

/* Sends one intent. `type` is the intent name ("send_message"); `fields_json` is a JSON object holding its
 * other fields ("{\"conversation_id\":\"c_1\",\"text\":\"hi\"}") or NULL for none. The library adds "type"
 * and a fresh "id", writes the id to id_out (NUL-terminated, at most 15 characters plus NUL) so the host can
 * match the reply, and refuses frames over the cap. Fails with SZFRIENDS_ERR_NOT_READY unless READY; the
 * host shows the failure rather than queueing, because the helper owns every queue. `type` is lowercase
 * letters and underscores and never "hello"; fields_json must be an object without "type" or "id"
 * (SZFRIENDS_ERR_INVALID_ARGUMENT otherwise). SZFRIENDS_ERR_NOT_READY also when 16 MiB of earlier frames still
 * wait for socket space: the helper has stopped reading, and piling up more would be queueing in disguise. */
szfriends_status szfriends_client_send(szfriends_client *client, const char *type, const char *fields_json,
                                       char *id_out, size_t id_out_cap);

/* Negotiated protocol after the welcome; zeros before and while disconnected. */
void szfriends_client_protocol(const szfriends_client *client, int *major, int *minor);

/* Frees memory this library returned (szfriends_intent_fields_json). NULL is ignored. */
void szfriends_free(void *pointer);

/* Writes a fresh client_token for send_message and send_files: 32 random lowercase hex characters and a NUL
 * (out_cap at least 33). Make one per press of Send and reuse it when retrying that press (PROTOCOL.md
 * § Intents, idempotency). */
szfriends_status szfriends_client_token(char *out, size_t out_cap);

/* ---- Intent builders (PROTOCOL.md § Intents) ----------------------------------------------------------- */

/* One intent ready to send: its type and its fields, built with correct JSON escaping so C hosts never
 * assemble JSON by hand. Each builder returns NULL when a required argument is NULL or memory runs out; pass the
 * result straight to szfriends_client_send_intent(), which accepts NULL (reporting INVALID_ARGUMENT). Field
 * values are not validated beyond that: the helper owns validation and answers invalid_field. */
typedef struct szfriends_intent szfriends_intent;

typedef struct szfriends_revision { /* PROTOCOL.md file.revision */
    const char *source;             /* host app id, "com.intuition.shenzhenpdf" */
    const char *document_id;
    const char *revision_id;
    const char *label;  /* "version saved today, 14:02"; NULL: omitted */
    const char *sha256; /* 64 lowercase hex; NULL: omitted */
    uint64_t size;
} szfriends_revision;

typedef struct szfriends_file { /* PROTOCOL.md file object, one per attachment or dropped file */
    const char *path;
    const char *display_name;           /* NULL: omitted (the helper uses the file name) */
    const szfriends_revision *revision; /* NULL: "revision":null, a plain file whose current bytes are meant */
} szfriends_file;

typedef struct szfriends_crop { /* a square in source pixels */
    int64_t x, y, side;
} szfriends_crop;

szfriends_status szfriends_client_send_intent(szfriends_client *client, szfriends_intent *intent, char *id_out,
                                              size_t id_out_cap); /* always consumes `intent` */
const char *szfriends_intent_type(const szfriends_intent *intent);
char *szfriends_intent_fields_json(const szfriends_intent *intent); /* compact JSON object; szfriends_free() it */
void szfriends_intent_free(szfriends_intent *intent);

szfriends_intent *szfriends_intent_ping(void);
szfriends_intent *szfriends_intent_activate(void);
/* view: badge, list, nearby, details (with conversation_id), profile, settings. NULL conversation_id: no params.
 * message_status has its own builder below, because its params are a list. */
szfriends_intent *szfriends_intent_subscribe(const char *view, const char *conversation_id);
/* The message_status view (PROTOCOL.md § Views): where 1 to 16 of this person's outgoing messages stand, without
 * opening (and so reading) their conversation. NULL for no ids, more than 16, or a NULL id. */
szfriends_intent *szfriends_intent_subscribe_message_status(const char *const *message_ids, size_t count);
szfriends_intent *szfriends_intent_unsubscribe(const char *subscription);
szfriends_intent *szfriends_intent_set_filter(const char *subscription, const char *query);
szfriends_intent *szfriends_intent_open_conversation(const char *conversation_id, const char *message_id_or_null);
szfriends_intent *szfriends_intent_load_earlier(const char *subscription);
szfriends_intent *szfriends_intent_send_message(const char *conversation_id, const char *text,
                                                const char *client_token, const szfriends_file *attachments,
                                                size_t attachment_count); /* 0: no "attachments" field */
szfriends_intent *szfriends_intent_send_files(const char *conversation_id, const szfriends_file *files,
                                              size_t file_count, const char *client_token);
/* Marks a send_message or send_files intent as written by the host's assistant and sent by the person
 * ("via_assistant": true; PROTOCOL.md § Intents, Via the assistant), so both people see it came via the assistant.
 * Returns `intent`. Any other intent, or NULL, is freed and NULL returned: only those two intents carry the flag. */
szfriends_intent *szfriends_intent_via_assistant(szfriends_intent *intent);
/* Adds the friends a send_message intent's @ chips name ("mentions", PROTOCOL.md § Mentions), in order, one for each
 * U+FFFC in its text; the helper writes each mention itself, so views never handle IDs or keys. Offer @ only when the
 * helper announces "mentions". Returns `intent`; 0 ids leave it as it was. Any other intent, NULL, a NULL id or more
 * than 20 ids free it and return NULL. */
szfriends_intent *szfriends_intent_with_mentions(szfriends_intent *intent, const char *const *conversation_ids,
                                                 size_t count);
szfriends_intent *szfriends_intent_cancel_transfer(const char *transfer_id);
szfriends_intent *szfriends_intent_accept_offer(const char *transfer_id);
szfriends_intent *szfriends_intent_decline_offer(const char *transfer_id);
szfriends_intent *szfriends_intent_retry_item(const char *item_id);
/* Withdraws an outgoing message that has not left this Mac yet (PROTOCOL.md § Intents, cancel_message), when the
 * helper announces "messages.cancel". `message_id` is send_message's result, which is also the message's item_id. */
szfriends_intent *szfriends_intent_cancel_message(const char *message_id);
szfriends_intent *szfriends_intent_accept_request(const char *conversation_id);
szfriends_intent *szfriends_intent_decline_request(const char *conversation_id);
szfriends_intent *szfriends_intent_cancel_request(const char *conversation_id);
szfriends_intent *szfriends_intent_send_request(const char *nearby_id);
szfriends_intent *szfriends_intent_add_by_id(const char *friends_id);
/* Add from a mention (PROTOCOL.md § Mentions): the three values of the card's add_from_mention action, as they are. */
szfriends_intent *szfriends_intent_add_from_mention(const char *friends_id, const char *identity_key,
                                                    const char *name);
szfriends_intent *szfriends_intent_block(const char *conversation_id);
szfriends_intent *szfriends_intent_unblock(const char *conversation_id);
/* Takes the person off the list (PROTOCOL.md § Intents, remove_friend): send it from a row's menu or a friend's
 * details, after the action's confirm. */
szfriends_intent *szfriends_intent_remove_friend(const char *conversation_id);
/* Sets the field a confirm's ticked `option` names to true (PROTOCOL.md § Shared objects, Action, confirm.option):
 * "delete_history" on remove_friend, when the person also chose to delete the chat history. Returns `intent`. Any
 * other field or intent, or NULL, is freed and NULL returned, so an option is never sent where it means nothing. */
szfriends_intent *szfriends_intent_with_confirm_option(szfriends_intent *intent, const char *field);
szfriends_intent *szfriends_intent_mark_verified(const char *conversation_id);
szfriends_intent *szfriends_intent_accept_key_change(const char *conversation_id);
szfriends_intent *szfriends_intent_set_name(const char *name); /* "" clears it */
szfriends_intent *szfriends_intent_set_picture_animal(int64_t set, int64_t index);
/* crop NULL: "crop":null, the centered largest square. */
szfriends_intent *szfriends_intent_set_picture_image_data(const char *data_base64, const szfriends_crop *crop);
szfriends_intent *szfriends_intent_set_picture_image_path(const char *path, const szfriends_crop *crop);
szfriends_intent *szfriends_intent_set_auto_accept(const char *conversation_id, bool enabled);
/* The folder received files are saved to on this computer, an absolute path (helper capability received.folder). */
szfriends_intent *szfriends_intent_set_received_folder(const char *path);
szfriends_intent *szfriends_intent_dismiss_banner(const char *kind); /* "id_changed" */
szfriends_intent *szfriends_intent_start_visibility(void);
szfriends_intent *szfriends_intent_stop_visibility(void);
/* conversation_id NULL: every conversation (Cmd+K). limit 0: omitted (the helper's default, 20). */
szfriends_intent *szfriends_intent_search_messages(const char *query, const char *conversation_id_or_null,
                                                   int64_t limit);
szfriends_intent *szfriends_intent_assistant_open_scope_conversations(const char *const *conversation_ids,
                                                                      size_t count);
szfriends_intent *szfriends_intent_assistant_open_scope_all(void);
szfriends_intent *szfriends_intent_assistant_search(const char *scope_id, const char *query, int64_t limit);
/* before/after negative: omitted (the helper's default). */
szfriends_intent *szfriends_intent_assistant_read(const char *scope_id, const char *message_id, int64_t before,
                                                  int64_t after);
szfriends_intent *szfriends_intent_assistant_close_scope(const char *scope_id);
szfriends_intent *szfriends_intent_delete_history(const char *conversation_id_or_null); /* NULL: all history */
szfriends_intent *szfriends_intent_reset_friends(void); /* carries confirm "reset"; ask the person first */
szfriends_intent *szfriends_intent_disable(void);
/* Links (PROTOCOL.md § Links), when the helper announces "links". open_link takes the payload ("f.…" or "d.…") the
 * host checked; add_from_link and receive_link are the card's actions, their payload sent as it is. A download link
 * is valid 1, 7 or 30 days (anything else: NULL). */
szfriends_intent *szfriends_intent_open_link(const char *payload);
szfriends_intent *szfriends_intent_add_from_link(const char *payload);
szfriends_intent *szfriends_intent_receive_link(const char *payload);
szfriends_intent *szfriends_intent_make_download_link(const szfriends_file *file, int64_t expires_days);
szfriends_intent *szfriends_intent_reset_friend_link(void);
szfriends_intent *szfriends_intent_revoke_link(const char *link_id);
/* Several computers on one profile (PROTOCOL.md § Devices, § Joining), when the helper announces "devices".
 * join_profile and enter_join_code take what the person typed; approve_join and deny_join a join request's join_id;
 * revoke_device a device row's device_id; rename_device this computer's new name; fetch_from_device the transfer
 * item's transfer_id. */
szfriends_intent *szfriends_intent_join_profile(const char *friends_id);
szfriends_intent *szfriends_intent_enter_join_code(const char *code);
szfriends_intent *szfriends_intent_cancel_join(void);
szfriends_intent *szfriends_intent_approve_join(const char *join_id);
szfriends_intent *szfriends_intent_deny_join(const char *join_id);
szfriends_intent *szfriends_intent_revoke_device(const char *device_id);
szfriends_intent *szfriends_intent_rename_device(const char *name);
szfriends_intent *szfriends_intent_fetch_from_device(const char *transfer_id);
/* Get again (PROTOCOL.md § Getting a file again), when the helper announces "files.again": the transfer item's
 * transfer_id. */
szfriends_intent *szfriends_intent_fetch_from_friend(const char *transfer_id);

#ifdef __cplusplus
}
#endif

#endif /* SZFRIENDS_CLIENT_H */
