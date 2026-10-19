/* The signing policy of team-signed apps: SZFRIENDS_STATE_DIR ignored, and a helper trusted only when the host's
 * verifier accepts its audit token against the team requirement. The verifier is injected (no test reads a real
 * code signature or the Keychain); the helper on the other end is the fake, on a temporary state directory. */

#define _DARWIN_C_SOURCE 1

#include "szfriends_test_support.h"

#include "client/szfriends_client_internal.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct verifier_log {
    int calls;
    bool answer;
    size_t token_length;
    bool token_nonzero;
    char requirement[160];
} verifier_log;

static bool fake_verifier(void *context, const void *audit_token, size_t token_length, const char *requirement) {
    verifier_log *log = (verifier_log *)context;
    const unsigned char *bytes = (const unsigned char *)audit_token;
    size_t i;
    log->calls++;
    log->token_length = token_length;
    log->token_nonzero = false;
    for (i = 0; i < token_length; i++) log->token_nonzero = log->token_nonzero || bytes[i] != 0;
    snprintf(log->requirement, sizeof log->requirement, "%s", requirement);
    return log->answer;
}

static const char team_requirement[] = "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"";

/* A team-signed app reads the real state directory whatever the environment says, like its helper. */
static void test_overrides_ignored_when_signed(void) {
    char *home = szft_temp_dir("signhome");
    char expected[PATH_MAX], out[SZFRIENDS_PATH_CAP];
    const char *saved_home = getenv("HOME");
    char *home_copy = saved_home ? strdup(saved_home) : NULL;

    setenv("HOME", home, 1); /* the default directory is only computed, never created or opened */
    setenv(SZFRIENDS_ENV_STATE_DIR, "/tmp/szft-elsewhere", 1);
    snprintf(expected, sizeof expected, "%s/Library/Application Support/Shenzhen Friends", home);

    EXPECT(szfriends_environment_overrides_allowed(), "unsigned builds honour overrides");
    EXPECT(szfriends_default_state_dir(out, sizeof out) == SZFRIENDS_OK && strcmp(out, "/tmp/szft-elsewhere") == 0,
           "unsigned: the override wins (%s)", out);

    EXPECT(szfriends_set_signing_policy("ABCDE12345", NULL, NULL) == SZFRIENDS_OK, "valid team accepted");
    EXPECT(!szfriends_environment_overrides_allowed(), "signed builds ignore overrides");
    EXPECT(szfriends_default_state_dir(out, sizeof out) == SZFRIENDS_OK && strcmp(out, expected) == 0,
           "signed: the real directory, not the override (%s)", out);

    EXPECT(szfriends_set_signing_policy("bad\"team", NULL, NULL) == SZFRIENDS_ERR_INVALID_ARGUMENT,
           "a malformed team is reported");
    EXPECT(!szfriends_environment_overrides_allowed(), "and still counts as signed (fail closed)");

    EXPECT(szfriends_set_signing_policy(NULL, NULL, NULL) == SZFRIENDS_OK && szfriends_environment_overrides_allowed(),
           "no team: back to the unsigned rule");
    EXPECT(szfriends_set_signing_policy("", NULL, NULL) == SZFRIENDS_OK && szfriends_environment_overrides_allowed(),
           "an empty team is no team");

    unsetenv(SZFRIENDS_ENV_STATE_DIR);
    if (home_copy) setenv("HOME", home_copy, 1);
    else unsetenv("HOME");
    free(home_copy);
    szft_remove_tree(home);
    free(home);
}

static szft_client *start_client(const char *state) {
    szft_client_options options;
    szft_client *harness;
    memset(&options, 0, sizeof options);
    options.state_dir = state;
    harness = szft_client_new(&options);
    return harness;
}

/* The helper's audit token goes to the verifier with the team requirement; only a yes reaches READY. */
static void test_helper_signature_checked(void) {
    char *state = szft_temp_dir("signpeer");
    szfriends_fake_helper *fake = szft_fake_start(state, 0, 0, 0, 0, false);
    char socket_path[SZFRIENDS_PATH_CAP];
    verifier_log log;
    szft_client *harness;
    szfriends_status status;

    memset(&log, 0, sizeof log);
    log.answer = false;
    szfriends_set_signing_policy("ABCDE12345", fake_verifier, &log);
    harness = start_client(state);
    status = szfriends_client_start(harness->client);
    EXPECT(status == SZFRIENDS_ERR_PEER_SIGNATURE, "a helper of another team is refused: %s",
           szfriends_status_name(status));
    EXPECT(log.calls >= 1 && strcmp(log.requirement, team_requirement) == 0,
           "asked with the helper's own requirement: \"%s\"", log.requirement);
    EXPECT(log.token_length == 32 && log.token_nonzero, "a whole audit token (%zu bytes)", log.token_length);
    EXPECT(!szft_wait_state(harness, SZFRIENDS_CONNECTION_READY, 400), "never READY, nothing sent to it");
    szft_client_free(harness);

    EXPECT(szfriends_socket_path(state, socket_path, sizeof socket_path, NULL) == SZFRIENDS_OK, "socket path");
    EXPECT(szfriends_probe_socket(socket_path) == SZFRIENDS_ERR_PEER_SIGNATURE,
           "connect-or-spawn sees the refusal too, so it starts our own helper");

    log.answer = true;
    harness = start_client(state);
    szfriends_client_start(harness->client);
    EXPECT(szft_wait_state(harness, SZFRIENDS_CONNECTION_READY, 5000), "the same team's helper is trusted");
    szft_client_free(harness);

    /* No verifier, or a malformed team: refused even though the uid matches. */
    szfriends_set_signing_policy("ABCDE12345", NULL, NULL);
    EXPECT(szfriends_probe_socket(socket_path) == SZFRIENDS_ERR_PEER_SIGNATURE, "no verifier: refused");
    log.calls = 0;
    szfriends_set_signing_policy("abcde12345", fake_verifier, &log);
    EXPECT(szfriends_probe_socket(socket_path) == SZFRIENDS_ERR_PEER_SIGNATURE && log.calls == 0,
           "malformed team: refused without asking");

    szfriends_set_signing_policy(NULL, NULL, NULL);
    log.calls = 0;
    EXPECT(szfriends_probe_socket(socket_path) == SZFRIENDS_OK && log.calls == 0, "unsigned: the uid check only");

    szfriends_fake_helper_stop(fake);
    szft_remove_tree(state);
    free(state);
}

/* The incompatible line names the app that needs updating. */
static void test_state_text_names_the_app(void) {
    char *state = szft_temp_dir("signtext");
    szfriends_fake_helper *fake = szft_fake_start(state, 3, 0, 3, 0, false);
    szft_client *harness = start_client(state);
    const char *text;
    EXPECT(strcmp(szfriends_client_state_text(harness->client), "") == 0, "nothing to say while idle");
    szfriends_client_start(harness->client);
    EXPECT(szft_wait_state(harness, SZFRIENDS_CONNECTION_INCOMPATIBLE, 5000), "INCOMPATIBLE");
    text = szfriends_client_state_text(harness->client);
    EXPECT(strstr(text, "Update ShenzhenPDF to use Friends.") != NULL && strstr(text, "this app") == NULL &&
               strstr(text, "on this computer") != NULL && strstr(text, "Mac") == NULL,
           "names the app: %s", text);
    EXPECT(strcmp(szfriends_client_state_text(NULL), "") == 0, "NULL client");
    szft_client_free(harness);
    szfriends_fake_helper_stop(fake);
    szft_remove_tree(state);
    free(state);
}

void szft_run_signing_tests(void) {
    test_overrides_ignored_when_signed();
    test_helper_signature_checked();
    test_state_text_names_the_app();
    szfriends_set_signing_policy(NULL, NULL, NULL); /* leave the process as the other groups expect */
}
