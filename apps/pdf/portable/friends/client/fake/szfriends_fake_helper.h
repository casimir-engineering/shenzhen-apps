/* Shenzhen Friends fake helper: speaks the real socket protocol and serves the golden fixtures.
 *
 * For tests and view development only, never shipped. It listens on szfriends_socket_path() for a state
 * directory, answers hello with fixtures/frames/welcome.json (version negotiation and handover included), each
 * subscribe and open_conversation with the matching fixtures/snapshots/ file (snapshot first, then the reply,
 * as PROTOCOL.md § Intents requires), and every other intent with fixtures/replies/<intent>.json or an empty
 * result. Tests script state changes through the functions below: replace a view's data, script a reply, send a
 * goodbye, drop every client as a crash would, or write raw bytes.
 *
 * Threading: the fake runs its own thread with a poll loop, so an AppKit main run loop or a test driving the
 * real client library on its own thread can talk to it. Every function here is safe from any thread; scripting
 * calls are applied on the fake's thread in the order they were made, and each one applies to every client frame
 * written after it returned, however the frames arrive together. A frame written before the call may or may not
 * see it; wait for that frame's reply first when it matters. C99, libc, pthreads and cJSON, so the GTK views can
 * use it as well (link the fake library, the client objects and cJSON).
 *
 * The executable built beside it (szfriends-fake-helper) wraps the same library: it takes helper.lock like the
 * real helper, exits when idle, and reads scripting commands on stdin (see szfriends_fake_main.c). */

#ifndef SZFRIENDS_FAKE_HELPER_H
#define SZFRIENDS_FAKE_HELPER_H

#include "client/szfriends_client.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct szfriends_fake_helper szfriends_fake_helper;

typedef struct szfriends_fake_helper_config {
    const char *state_dir;    /* required: the fake binds szfriends_socket_path(state_dir) */
    const char *fixtures_dir; /* required: portable/friends/fixtures */
    /* What this fake speaks. Zeros: this library's SZFRIENDS_PROTOCOL_MAJOR/MINOR/MIN_MAJOR. */
    int protocol_major, protocol_minor, protocol_min_major;
    /* welcome.helper.version and build_number. NULL / 0: the welcome fixture's values. */
    const char *version;
    uint64_t build_number;
    /* Take an exclusive flock on <state_dir>/helper.lock before binding, like the real helper; start fails with
     * SZFRIENDS_ERR_IO and errno EWOULDBLOCK when another helper holds it. */
    bool take_lock;
    /* After welcoming a client whose embedded helper is newer, step aside this many ms later: goodbye with
     * reason handover to every client, stop listening, release the lock. 0: 100 ms. */
    int handover_delay_ms;
    /* welcome.capabilities as a JSON array, to play a helper that offers something else: "[]" is one from before
     * messages.status, whose hosts must not ask about delivery. NULL: the welcome fixture's. Anything but an array:
     * start fails with SZFRIENDS_ERR_INVALID_ARGUMENT. */
    const char *capabilities_json;
} szfriends_fake_helper_config;

/* Loads the fixtures, binds and starts listening on the fake's own thread. */
szfriends_status szfriends_fake_helper_start(const szfriends_fake_helper_config *config,
                                             szfriends_fake_helper **fake_out);
/* Closes every connection, removes the socket file, releases the lock, joins the thread and frees. */
void szfriends_fake_helper_stop(szfriends_fake_helper *fake);

/* ---- Scripting ---------------------------------------------------------------------------------------- */

/* Serves `view` (badge, list, nearby, details, profile, settings, join) from another fixture file in
 * fixtures/snapshots/ ("list-id-changed.json") and sends it to every current subscriber with the next rev. */
szfriends_status szfriends_fake_helper_set_view_fixture(szfriends_fake_helper *fake, const char *view,
                                                        const char *fixture_name);
/* Same with literal `data` JSON (a view's data object, PROTOCOL.md § Schemas snapshot.<view>). For view
 * "conversation" the data's conversation_id says which conversation it replaces or adds. */
szfriends_status szfriends_fake_helper_set_view_data(szfriends_fake_helper *fake, const char *view,
                                                     const char *data_json);
/* The next reply to `intent` (and every later one) is this frame, with "re" rewritten to the intent's id: an
 * error reply, a different result. NULL reply_json restores the fixture behaviour. `intent` "hello" scripts the
 * answer to hello instead of the welcome, leaving the connection open. */
szfriends_status szfriends_fake_helper_set_reply(szfriends_fake_helper *fake, const char *intent,
                                                 const char *reply_json);
/* Sends this goodbye frame to every client and closes their connections. Reason handover also stops the fake
 * listening and releases the lock, as a real handover does. */
szfriends_status szfriends_fake_helper_send_goodbye(szfriends_fake_helper *fake, const char *goodbye_json);
/* Writes these bytes to every client as they are (an over-cap line, a malformed frame). */
szfriends_status szfriends_fake_helper_send_raw(szfriends_fake_helper *fake, const void *bytes, size_t length);
/* Closes every client connection without a goodbye, as a crash would. The fake keeps listening. */
szfriends_status szfriends_fake_helper_drop_clients(szfriends_fake_helper *fake);
/* While held, intents are received and recorded but not answered (hello still is): a busy helper, so tests can
 * drop a connection with replies outstanding or show a view's waiting state. Every intent written after the call
 * returns is held. Releasing answers nothing late; held intents stay unanswered, as they would on a helper that
 * crashed. */
szfriends_status szfriends_fake_helper_hold_replies(szfriends_fake_helper *fake, bool hold);

/* ---- Observation -------------------------------------------------------------------------------------- */

size_t szfriends_fake_helper_client_count(szfriends_fake_helper *fake);
/* Client frames received so far, every connection, in arrival order (hello included). */
size_t szfriends_fake_helper_frame_count(szfriends_fake_helper *fake);
/* A copy of received frame `index` (compact JSON as received), or NULL. Free with szfriends_free(). */
char *szfriends_fake_helper_copy_frame(szfriends_fake_helper *fake, size_t index);
/* Milliseconds since the last client left, -1 while clients are connected, or -2 when none ever connected
 * (the executable's idle exit uses it). */
int64_t szfriends_fake_helper_idle_ms(szfriends_fake_helper *fake);
/* True once the fake stopped listening (after a handover goodbye). */
bool szfriends_fake_helper_stepped_aside(szfriends_fake_helper *fake);

#ifdef __cplusplus
}
#endif

#endif /* SZFRIENDS_FAKE_HELPER_H */
