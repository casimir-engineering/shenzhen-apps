/* Shenzhen Friends fake helper internals, shared by its source files only. */

#ifndef SZFRIENDS_FAKE_INTERNAL_H
#define SZFRIENDS_FAKE_INTERNAL_H

#include "client/fake/szfriends_fake_helper.h"
#include "client/szfriends_client_internal.h"

#include "cJSON.h"

#include <pthread.h>

/* PROTOCOL.md § Limits. */
#define SZF_FAKE_MAX_CONNECTIONS 64
#define SZF_FAKE_MAX_SUBSCRIPTIONS 32

typedef struct szf_fake_connection {
    int fd;
    int number; /* stable id for subscriptions; fds are reused */
    szfriends_line_reader *reader;
    bool greeted;
    bool closing; /* close once the output is flushed (after a goodbye or a fatal reply) */
    char *out;
    size_t out_offset, out_length, out_capacity;
} szf_fake_connection;

typedef struct szf_fake_subscription {
    char id[24];
    int connection;           /* szf_fake_connection.number */
    char view[24];            /* PROTOCOL.md view names, "conversation" for open_conversation */
    char conversation_id[72]; /* details and conversation */
    char message_id[72];      /* open_conversation's highlight */
    char *query;              /* set_filter, list and nearby */
    bool earlier_loaded;      /* load_earlier ran: has_earlier becomes false */
    long rev;
} szf_fake_subscription;

typedef enum szf_fake_command_kind {
    SZF_FAKE_VIEW_DATA,
    SZF_FAKE_REPLY,
    SZF_FAKE_GOODBYE,
    SZF_FAKE_RAW,
    SZF_FAKE_DROP,
    SZF_FAKE_HOLD,
    SZF_FAKE_RELEASE
} szf_fake_command_kind;

typedef struct szf_fake_command {
    szf_fake_command_kind kind;
    char *name;  /* view or intent */
    char *json;  /* data, reply or goodbye frame; NULL restores a reply */
    char *bytes; /* raw */
    size_t length;
    struct szf_fake_command *next;
} szf_fake_command;

/* Called on the fake's thread as it is about to handle a client frame (`line`, without its line feed), after every
 * scripting command made before that frame arrived has been applied. */
typedef void (*szf_fake_frame_hook)(szfriends_fake_helper *fake, const char *line, size_t length, void *data);

struct szfriends_fake_helper {
    char *state_dir, *fixtures_dir, *version;
    int major, minor, min_major;
    uint64_t build_number;
    int handover_delay_ms;
    char socket_path[SZFRIENDS_PATH_CAP];
    /* The socket sits in the per-user szfriends-<hash> directory because the state path is too deep (PROTOCOL.md
     * § Transport): stopping removes that directory too, or every test run with a deep state directory leaves one
     * behind in TMPDIR (wave-4 integration sweep). */
    bool socket_fallback;
    int listen_fd, lock_fd;
    int wake[2];
    pthread_t thread;
    pthread_mutex_t mutex;

    /* Fixtures and scripted state; touched only on the fake's thread after start. */
    cJSON *welcome;
    cJSON *views;         /* object: view name -> data, for badge, list, nearby, profile, settings */
    cJSON *details;       /* array of details data, matched by conversation_id */
    cJSON *conversations; /* array of conversation data, matched by conversation_id */
    cJSON *replies;       /* object: intent -> successful reply frame from fixtures/replies */
    cJSON *scripted;      /* object: intent -> reply frame set by szfriends_fake_helper_set_reply */

    szf_fake_connection *connections[SZF_FAKE_MAX_CONNECTIONS];
    int next_connection_number;
    szf_fake_subscription *subscriptions;
    size_t subscription_count, subscription_capacity;
    long next_subscription_number;
    uint64_t handover_at; /* monotonic ms; 0 when none is scheduled */
    bool holding;         /* szfriends_fake_helper_hold_replies */
    char *handover_version;
    double handover_build;

    /* Shared with other threads under `mutex`. */
    szf_fake_frame_hook frame_hook; /* szf_fake_set_frame_hook */
    void *frame_hook_data;
    szf_fake_command *commands, *commands_tail;
    char **frames;
    size_t frame_count, frame_capacity;
    size_t client_count;
    bool ever_had_client;
    uint64_t last_left_ms;
    bool stopping;
    bool stepped_aside;
};

/* Scripting queue (szfriends_fake_scripting.c). */
/* For the fake's own tests only: they need to act at an exact point on the fake's thread (between two frames of one
 * client) to prove when scripting applies, which no public call can reach. NULL removes the hook. */
void szf_fake_set_frame_hook(szfriends_fake_helper *fake, szf_fake_frame_hook hook, void *data);
szf_fake_command *szf_fake_command_new(szf_fake_command_kind kind, const char *name, const char *json);
szfriends_status szf_fake_enqueue(szfriends_fake_helper *fake, szf_fake_command *command);
void szf_fake_free_command(szf_fake_command *command);

/* Fixtures (szfriends_fake_fixtures.c). */
szfriends_status szf_fake_load_fixtures(szfriends_fake_helper *fake);
char *szf_fake_read_file(const char *path, size_t *length_out);
cJSON *szf_fake_find_by_conversation(cJSON *array, const char *conversation_id);
bool szf_fake_is_intent(const char *type);

/* Protocol (szfriends_fake_protocol.c). */
void szf_fake_handle_line(szfriends_fake_helper *fake, szf_fake_connection *connection, const char *line,
                          size_t length);
void szf_fake_send_frame(szf_fake_connection *connection, cJSON *frame); /* takes ownership of frame */
void szf_fake_send_text(szf_fake_connection *connection, const char *text, size_t length);
void szf_fake_publish_view(szfriends_fake_helper *fake, const char *view, const char *conversation_id);
void szf_fake_goodbye_all(szfriends_fake_helper *fake, cJSON *goodbye); /* takes ownership */
void szf_fake_remove_subscriptions(szfriends_fake_helper *fake, int connection_number);

#endif /* SZFRIENDS_FAKE_INTERNAL_H */
