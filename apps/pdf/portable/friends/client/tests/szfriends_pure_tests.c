/* Pure parts of the client library: status names, paths, the directory rule, framing, negotiation, texts. */

#define _DARWIN_C_SOURCE 1

#include "szfriends_test_support.h"

#include "client/szfriends_client_internal.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void test_status_names(void) {
    int status;
    EXPECT(strcmp(szfriends_status_name(SZFRIENDS_ERR_NO_HELPER), "no_helper") == 0, "no_helper name");
    for (status = SZFRIENDS_OK; status <= SZFRIENDS_ERR_NO_MEMORY; status++)
        EXPECT(strcmp(szfriends_status_name((szfriends_status)status), "unknown") != 0, "status %d unnamed", status);
}

static void test_fnv(void) {
    /* PROTOCOL.md § Transport test vectors. */
    const char *path = "/Users/raph/Library/Application Support/Shenzhen Friends";
    EXPECT(szfriends_fnv1a64("", 0) == UINT64_C(0xcbf29ce484222325), "fnv empty");
    EXPECT(szfriends_fnv1a64("a", 1) == UINT64_C(0xaf63dc4c8601ec8c), "fnv a");
    EXPECT(szfriends_fnv1a64(path, strlen(path)) == UINT64_C(0xb481e2f85812919d), "fnv state dir");
}

static void test_default_state_dir(void) {
    char out[SZFRIENDS_PATH_CAP];
    char *saved = getenv(SZFRIENDS_ENV_STATE_DIR) ? strdup(getenv(SZFRIENDS_ENV_STATE_DIR)) : NULL;
    char *home = getenv("HOME") ? strdup(getenv("HOME")) : NULL;
    setenv(SZFRIENDS_ENV_STATE_DIR, "/tmp/szft-override", 1);
    EXPECT(szfriends_default_state_dir(out, sizeof out) == SZFRIENDS_OK && strcmp(out, "/tmp/szft-override") == 0,
           "override honoured: %s", out);
    setenv(SZFRIENDS_ENV_STATE_DIR, "relative/dir", 1);
    setenv("HOME", "/Users/someone", 1);
    EXPECT(szfriends_default_state_dir(out, sizeof out) == SZFRIENDS_OK &&
               strcmp(out, "/Users/someone/Library/Application Support/Shenzhen Friends") == 0,
           "relative override ignored: %s", out);
    unsetenv(SZFRIENDS_ENV_STATE_DIR);
    EXPECT(szfriends_default_state_dir(out, 8) == SZFRIENDS_ERR_PATH_TOO_LONG, "short buffer");
    if (home) setenv("HOME", home, 1);
    if (saved) setenv(SZFRIENDS_ENV_STATE_DIR, saved, 1);
    free(home);
    free(saved);
}

static void test_socket_paths(void) {
    char *temp = szft_temp_dir("paths");
    char resolved[PATH_MAX], state[SZFRIENDS_PATH_CAP], path[SZFRIENDS_PATH_CAP], expected[SZFRIENDS_PATH_CAP * 2];
    char deep[SZFRIENDS_PATH_CAP], canonical_deep[SZFRIENDS_PATH_CAP * 2], user_temp[SZFRIENDS_PATH_CAP];
    bool fallback = true;
    szfriends_status status;

    realpath(temp, resolved);
    /* A state directory that does not exist yet still canonicalizes through its existing ancestor (/var is a
     * symlink to /private/var), so a client starting before the helper agrees with it. */
    snprintf(state, sizeof state, "%s/n/s/", temp);
    status = szfriends_socket_path(state, path, sizeof path, &fallback);
    snprintf(expected, sizeof expected, "%s/n/s/ipc/helper.sock", resolved);
    EXPECT(status == SZFRIENDS_OK && !fallback && strcmp(path, expected) == 0, "primary path %s vs %s", path,
           expected);
    EXPECT(strstr(resolved, "/private/") == resolved || strncmp(temp, "/var/", 5) != 0, "realpath resolves /var");

    snprintf(deep, sizeof deep, "%s/%s/%s", temp, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
             "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    status = szfriends_socket_path(deep, path, sizeof path, &fallback);
    snprintf(canonical_deep, sizeof canonical_deep, "%s/%s/%s", resolved,
             "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
             "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    confstr(_CS_DARWIN_USER_TEMP_DIR, user_temp, sizeof user_temp);
    snprintf(expected, sizeof expected, "%s%sszfriends-%016llx/helper.sock", user_temp,
             user_temp[strlen(user_temp) - 1] == '/' ? "" : "/",
             (unsigned long long)szfriends_fnv1a64(canonical_deep, strlen(canonical_deep)));
    EXPECT(status == SZFRIENDS_OK && fallback && strcmp(path, expected) == 0, "fallback path %s vs %s", path,
           expected);
    EXPECT(strlen(path) < SZFRIENDS_SUN_PATH_MAX, "fallback fits sun_path");

    snprintf(state, sizeof state, "%s/missing/../state", temp);
    EXPECT(szfriends_socket_path(state, path, sizeof path, NULL) == SZFRIENDS_ERR_INVALID_ARGUMENT,
           "dot-dot in the missing part is refused");
    EXPECT(szfriends_socket_path("relative/state", path, sizeof path, NULL) == SZFRIENDS_ERR_INVALID_ARGUMENT,
           "relative state dir is refused");
    EXPECT(szfriends_socket_path(temp, path, 10, NULL) == SZFRIENDS_ERR_PATH_TOO_LONG, "small output buffer");
    szft_remove_tree(temp);
    free(temp);
}

static void test_directory_check(void) {
    char *temp = szft_temp_dir("dircheck");
    char socket_path[SZFRIENDS_PATH_CAP], directory[SZFRIENDS_PATH_CAP], link_path[SZFRIENDS_PATH_CAP];
    struct stat info;
    snprintf(socket_path, sizeof socket_path, "%s/state/ipc/helper.sock", temp);
    snprintf(directory, sizeof directory, "%s/state/ipc", temp);
    EXPECT(szfriends_socket_directory_check(socket_path, false) == SZFRIENDS_ERR_NO_HELPER,
           "missing directory means nobody listens");
    EXPECT(szfriends_socket_directory_check(socket_path, true) == SZFRIENDS_OK, "created");
    EXPECT(stat(directory, &info) == 0 && (info.st_mode & 0777) == 0700, "created 0700 (%o)", info.st_mode & 0777);
    EXPECT(szfriends_socket_directory_check(socket_path, false) == SZFRIENDS_OK, "existing safe directory");
    chmod(directory, 0755);
    EXPECT(szfriends_socket_directory_check(socket_path, false) == SZFRIENDS_ERR_UNSAFE_DIRECTORY, "group/world");
    EXPECT(szfriends_socket_directory_check(socket_path, true) == SZFRIENDS_ERR_UNSAFE_DIRECTORY,
           "never chmod-ed into shape");
    chmod(directory, 0700);
    snprintf(link_path, sizeof link_path, "%s/linked", temp);
    symlink(directory, link_path);
    snprintf(socket_path, sizeof socket_path, "%s/linked/helper.sock", temp);
    EXPECT(szfriends_socket_directory_check(socket_path, false) == SZFRIENDS_ERR_UNSAFE_DIRECTORY, "symlink");
    EXPECT(szfriends_socket_directory_check("relative/helper.sock", true) == SZFRIENDS_ERR_INVALID_ARGUMENT, "rel");
    szft_remove_tree(temp);
    free(temp);
}

static void expect_line(szfriends_line_reader *reader, const char *want) {
    const char *line = NULL;
    size_t length = 99;
    szfriends_status status = szfriends_line_reader_next(reader, &line, &length);
    if (!want) {
        EXPECT(status == SZFRIENDS_OK && line == NULL, "expected no line, got %s", line ? line : "(null)");
        return;
    }
    EXPECT(status == SZFRIENDS_OK && line && strcmp(line, want) == 0 && length == strlen(want),
           "expected line '%s', got '%s'", want, line ? line : "(null)");
}

static void test_line_reader(void) {
    szfriends_line_reader *reader = szfriends_line_reader_new(8);
    char big[9];
    EXPECT(szfriends_line_reader_new(0) == NULL, "zero cap refused");
    EXPECT(szfriends_line_reader_push(reader, "ab\ncd", 5) == SZFRIENDS_OK, "push");
    expect_line(reader, "ab");
    expect_line(reader, NULL);
    EXPECT(szfriends_line_reader_push(reader, "e\n\n\nf\n", 6) == SZFRIENDS_OK, "push 2");
    expect_line(reader, "cde");
    expect_line(reader, "f"); /* empty lines skipped */
    expect_line(reader, NULL);
    memset(big, 'x', sizeof big);
    EXPECT(szfriends_line_reader_push(reader, big, 8) == SZFRIENDS_OK, "exactly the cap, no newline yet");
    EXPECT(szfriends_line_reader_push(reader, "\n", 1) == SZFRIENDS_OK, "cap excludes the newline");
    expect_line(reader, "xxxxxxxx");
    EXPECT(szfriends_line_reader_push(reader, big, 5) == SZFRIENDS_OK, "partial");
    EXPECT(szfriends_line_reader_push(reader, big, 4) == SZFRIENDS_ERR_FRAME_TOO_LARGE, "over the cap across pushes");
    EXPECT(szfriends_line_reader_push(reader, "\n", 1) == SZFRIENDS_ERR_FRAME_TOO_LARGE, "sticky failure");
    szfriends_line_reader_free(reader);

    /* Complete lines in one push may exceed the cap together; only each line's own length counts. */
    reader = szfriends_line_reader_new(4);
    EXPECT(szfriends_line_reader_push(reader, "1234\n5678\n9", 11) == SZFRIENDS_OK, "many lines in one push");
    expect_line(reader, "1234");
    expect_line(reader, "5678");
    EXPECT(szfriends_line_reader_push(reader, "abcd", 4) == SZFRIENDS_ERR_FRAME_TOO_LARGE, "pending 9abcd");
    szfriends_line_reader_free(reader);
}

static void test_negotiation(void) {
    int major = -1, minor = -1;
    EXPECT(szfriends_negotiate(1, 0, 1, 1, 0, 1, &major, &minor) && major == 1 && minor == 0, "1.0 with 1.0");
    EXPECT(szfriends_negotiate(1, 3, 1, 1, 1, 1, &major, &minor) && major == 1 && minor == 1, "lower minor wins");
    EXPECT(szfriends_negotiate(2, 1, 1, 1, 4, 1, &major, &minor) && major == 1 && minor == 4,
           "newer helper speaks the client's whole major");
    EXPECT(szfriends_negotiate(1, 2, 1, 2, 0, 1, &major, &minor) && major == 1 && minor == 2,
           "newer client speaks the helper's whole major");
    EXPECT(!szfriends_negotiate(3, 0, 3, 1, 0, 1, &major, &minor), "no common major");
    EXPECT(!szfriends_negotiate(1, 0, 1, 3, 0, 2, &major, &minor), "client dropped major 1");
}

static void test_texts_and_config(void) {
    szfriends_client_config config;
    char token[33], other[33];
    int state;
    for (state = SZFRIENDS_CONNECTION_IDLE; state <= SZFRIENDS_CONNECTION_INCOMPATIBLE; state++)
        EXPECT(szfriends_connection_state_text((szfriends_connection_state)state) != NULL, "text %d", state);
    EXPECT(szfriends_connection_state_text(SZFRIENDS_CONNECTION_READY)[0] == '\0', "nothing to say when ready");
    EXPECT(szfriends_connection_state_text(SZFRIENDS_CONNECTION_IDLE)[0] == '\0', "nothing to say when idle");
    EXPECT(strstr(szfriends_connection_state_text(SZFRIENDS_CONNECTION_INCOMPATIBLE), "Update") != NULL,
           "incompatible says what to do");
    /* Read in Shenzhen Files on Linux too: "this computer", never "this Mac". */
    EXPECT(strstr(szfriends_connection_state_text(SZFRIENDS_CONNECTION_INCOMPATIBLE), "on this computer") != NULL &&
               strstr(szfriends_connection_state_text(SZFRIENDS_CONNECTION_INCOMPATIBLE), "Mac") == NULL,
           "incompatible is true on any computer");
    memset(&config, 0, sizeof config);
    EXPECT(szfriends_client_new(NULL) == NULL, "NULL config");
    EXPECT(szfriends_client_new(&config) == NULL, "missing app fields");
    EXPECT(szfriends_client_token(token, sizeof token) == SZFRIENDS_OK && strlen(token) == 32 &&
               strspn(token, "0123456789abcdef") == 32,
           "token is 32 hex");
    szfriends_client_token(other, sizeof other);
    EXPECT(strcmp(token, other) != 0, "tokens differ");
    EXPECT(szfriends_client_token(token, 32) == SZFRIENDS_ERR_INVALID_ARGUMENT, "token buffer too small");
}

void szft_run_pure_tests(void) {
    test_status_names();
    test_fnv();
    test_default_state_dir();
    test_socket_paths();
    test_directory_check();
    test_line_reader();
    test_negotiation();
    test_texts_and_config();
}
