/* Shenzhen 3D's binding of the Shenzhen Friends client library for Electron's main process.
 *
 * The library (shenzhen-pdf portable/friends/client, built from the commit friends.lock pins) owns the socket
 * rules, the peer checks, connect-or-spawn, reconnection with backoff, the helper handover and the synthesized
 * connection_lost replies. This file only drives it from the main process's libuv loop, the way the GTK views drive
 * it from the GLib main loop: the client's descriptor is watched with a uv_poll (re-created on every state change,
 * because the descriptor changes across reconnects), its ticks run on a uv_timer, and every frame and state change
 * is queued and handed to JavaScript in one batch after the library call that produced it has returned. JavaScript
 * never runs inside a library callback, so it may stop or close the client from its event handler.
 *
 * Everything here runs on the main thread except the two promise-returning calls, prepare() (the app's own signing
 * policy, which reads its code signature) and spawnHelper() (connect-or-spawn, which the library refuses on the
 * macOS main thread), which run on libuv's thread pool. The client object is in friends-link-client.c. */

#include "friends-link.h"

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <bsm/libbsm.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "client/szfriends_client.h"

/* ---- Signing policy (ADR 0002 § Peer checks), as ShenzhenPDF's SPDFMacFriendsSigning.mm does it --------------- */

static char *own_team_identifier(void) {
    SecCodeRef me = NULL;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &me) != errSecSuccess || !me) return NULL;
    SecStaticCodeRef code = NULL;
    OSStatus status = SecCodeCopyStaticCode(me, kSecCSDefaultFlags, &code);
    CFRelease(me);
    if (status != errSecSuccess || !code) return NULL;
    CFDictionaryRef info = NULL;
    status = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info);
    CFRelease(code);
    if (status != errSecSuccess || !info) return NULL;
    char *team = NULL;
    CFTypeRef value = CFDictionaryGetValue(info, kSecCodeInfoTeamIdentifier);
    /* Ad-hoc and linker signatures carry no team; only a real Team ID turns the check on. */
    if (value && CFGetTypeID(value) == CFStringGetTypeID() && CFStringGetLength((CFStringRef)value) > 0) {
        char buffer[64];
        if (CFStringGetCString((CFStringRef)value, buffer, sizeof buffer, kCFStringEncodingUTF8)) team = strdup(buffer);
    }
    CFRelease(info);
    return team;
}

static bool verify_peer(void *context, const void *audit_token, size_t length, const char *requirement) {
    (void)context;
    if (!audit_token || length != sizeof(audit_token_t) || !requirement || !requirement[0]) return false;
    CFDataRef token = CFDataCreate(NULL, audit_token, (CFIndex)length);
    CFStringRef text = CFStringCreateWithCString(NULL, requirement, kCFStringEncodingUTF8);
    bool ok = false;
    if (token && text) {
        const void *keys[] = {kSecGuestAttributeAudit};
        const void *values[] = {token};
        CFDictionaryRef attributes =
            CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        SecCodeRef code = NULL;
        /* The audit token, unlike a pid, names exactly the process that holds the socket. */
        bool found = attributes &&
                     SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code) == errSecSuccess;
        if (found && code) {
            SecRequirementRef required = NULL;
            if (SecRequirementCreateWithString(text, kSecCSDefaultFlags, &required) == errSecSuccess && required) {
                ok = SecCodeCheckValidity(code, kSecCSDefaultFlags, required) == errSecSuccess;
                CFRelease(required);
            }
            CFRelease(code);
        }
        if (attributes) CFRelease(attributes);
    }
    if (token) CFRelease(token);
    if (text) CFRelease(text);
    return ok;
}

static pthread_once_t policy_once = PTHREAD_ONCE_INIT;
static char *policy_team = NULL;

static void apply_signing_policy(void) {
    policy_team = own_team_identifier();
    /* A malformed team makes the library refuse every helper rather than fall back to the uid check, so even a
     * failing status leaves a signed app's policy in force. */
    if (policy_team) (void)szfriends_set_signing_policy(policy_team, verify_peer, NULL);
}

/* ---- Promise helpers ---------------------------------------------------------------------------------------- */

typedef struct Job {
    napi_async_work work;
    napi_deferred deferred;
    char *helper_path;
    char *state_dir;
    szfriends_status status;
    pid_t pid;
} Job;

char *string_arg(napi_env env, napi_value value) {
    napi_valuetype type;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_string) return NULL;
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, NULL, 0, &length) != napi_ok || length > 4096) return NULL;
    char *text = malloc(length + 1);
    if (!text) return NULL;
    if (napi_get_value_string_utf8(env, value, text, length + 1, &length) != napi_ok) {
        free(text);
        return NULL;
    }
    return text;
}

napi_value make_string(napi_env env, const char *text) {
    napi_value value = NULL;
    if (text) napi_create_string_utf8(env, text, NAPI_AUTO_LENGTH, &value);
    else napi_get_null(env, &value);
    return value;
}

static void prepare_execute(napi_env env, void *data) {
    (void)env;
    (void)data;
    pthread_once(&policy_once, apply_signing_policy);
}

static void prepare_complete(napi_env env, napi_status status, void *data) {
    Job *job = data;
    napi_value result;
    napi_create_object(env, &result);
    napi_set_named_property(env, result, "team", make_string(env, policy_team));
    if (status == napi_ok) napi_resolve_deferred(env, job->deferred, result);
    else napi_reject_deferred(env, job->deferred, make_string(env, "prepare failed"));
    napi_delete_async_work(env, job->work);
    free(job);
}

/* prepare(): Promise<{team: string|null}>. Sets this app's signing policy once per process, off the main thread. */
static napi_value prepare(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value promise = NULL, name;
    Job *job = calloc(1, sizeof *job);
    if (!job) return NULL;
    CHECK(napi_create_promise(env, &job->deferred, &promise));
    CHECK(napi_create_string_utf8(env, "szfriends.prepare", NAPI_AUTO_LENGTH, &name));
    CHECK(napi_create_async_work(env, NULL, name, prepare_execute, prepare_complete, job, &job->work));
    CHECK(napi_queue_async_work(env, job->work));
    return promise;
fail:
    free(job);
    return promise;
}

static void spawn_execute(napi_env env, void *data) {
    (void)env;
    Job *job = data;
    pthread_once(&policy_once, apply_signing_policy);
    job->status = szfriends_spawn_helper(job->helper_path, job->state_dir, &job->pid);
}

static void spawn_complete(napi_env env, napi_status status, void *data) {
    Job *job = data;
    napi_value result, pid;
    napi_create_object(env, &result);
    napi_set_named_property(env, result, "status", make_string(env, szfriends_status_name(job->status)));
    napi_create_int32(env, (int32_t)job->pid, &pid);
    napi_set_named_property(env, result, "pid", pid);
    if (status == napi_ok) napi_resolve_deferred(env, job->deferred, result);
    else napi_reject_deferred(env, job->deferred, make_string(env, "spawn failed"));
    napi_delete_async_work(env, job->work);
    free(job->helper_path);
    free(job->state_dir);
    free(job);
}

/* spawnHelper(helperPath, stateDir | null): Promise<{status, pid}>. Connect-or-spawn (ADR 0002), never waiting
 * for the helper to bind. */
static napi_value spawn_helper(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2], promise = NULL, name;
    napi_valuetype type = napi_undefined;
    Job *job = calloc(1, sizeof *job);
    if (!job) return NULL;
    CHECK(napi_get_cb_info(env, info, &argc, argv, NULL, NULL));
    job->helper_path = argc > 0 ? string_arg(env, argv[0]) : NULL;
    if (argc > 1) napi_typeof(env, argv[1], &type);
    job->state_dir = type == napi_string ? string_arg(env, argv[1]) : NULL;
    if (!job->helper_path || !job->helper_path[0]) {
        napi_throw_type_error(env, NULL, "spawnHelper needs the helper executable's path");
        goto fail;
    }
    CHECK(napi_create_promise(env, &job->deferred, &promise));
    CHECK(napi_create_string_utf8(env, "szfriends.spawn", NAPI_AUTO_LENGTH, &name));
    CHECK(napi_create_async_work(env, NULL, name, spawn_execute, spawn_complete, job, &job->work));
    CHECK(napi_queue_async_work(env, job->work));
    return promise;
fail:
    free(job->helper_path);
    free(job->state_dir);
    free(job);
    return NULL;
}

/* ---- Plain functions ---------------------------------------------------------------------------------------- */

static napi_value default_state_dir(napi_env env, napi_callback_info info) {
    (void)info;
    char path[SZFRIENDS_PATH_CAP];
    return make_string(env, szfriends_default_state_dir(path, sizeof path) == SZFRIENDS_OK ? path : NULL);
}

static napi_value socket_path(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 1) return NULL;
    char *dir = string_arg(env, argv[0]);
    char path[SZFRIENDS_PATH_CAP];
    bool fallback = false;
    szfriends_status status =
        dir ? szfriends_socket_path(dir, path, sizeof path, &fallback) : SZFRIENDS_ERR_INVALID_ARGUMENT;
    free(dir);
    return make_string(env, status == SZFRIENDS_OK ? path : NULL);
}

static napi_value client_token(napi_env env, napi_callback_info info) {
    (void)info;
    char token[33];
    return make_string(env, szfriends_client_token(token, sizeof token) == SZFRIENDS_OK ? token : NULL);
}

static napi_value init(napi_env env, napi_value exports) {
    const struct {
        const char *name;
        napi_callback callback;
    } functions[] = {{"prepare", prepare},
                     {"spawnHelper", spawn_helper},
                     {"defaultStateDir", default_state_dir},
                     {"socketPath", socket_path},
                     {"clientToken", client_token},
                     {"createClient", create_client}};
    napi_value fn, number;
    for (size_t i = 0; i < sizeof functions / sizeof functions[0]; i++) {
        if (napi_create_function(env, functions[i].name, NAPI_AUTO_LENGTH, functions[i].callback, NULL, &fn) ==
            napi_ok)
            napi_set_named_property(env, exports, functions[i].name, fn);
    }
    napi_create_int32(env, SZFRIENDS_PROTOCOL_MAJOR, &number);
    napi_set_named_property(env, exports, "protocolMajor", number);
    napi_create_int32(env, SZFRIENDS_PROTOCOL_MINOR, &number);
    napi_set_named_property(env, exports, "protocolMinor", number);
    return exports;
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, init)
