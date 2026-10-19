/* What the two halves of Shenzhen 3D's Friends addon share: friends-link.c (the module, the signing policy, the
 * promise-returning calls) and friends-link-client.c (the client object on the main process's libuv loop). */
#ifndef SHENZHEN3D_FRIENDS_LINK_H
#define SHENZHEN3D_FRIENDS_LINK_H

#define NAPI_VERSION 8
#include <node_api.h>

#define CHECK(call)                                                                                                \
    do {                                                                                                           \
        if ((call) != napi_ok) goto fail;                                                                          \
    } while (0)

/* A JavaScript string of at most 4096 bytes as a C string the caller frees; NULL for anything else. */
char *string_arg(napi_env env, napi_value value);
/* A C string as a JavaScript string, or null for NULL. */
napi_value make_string(napi_env env, const char *text);
/* createClient(config, onEvents): a client object with start, stop, close, send and state. */
napi_value create_client(napi_env env, napi_callback_info info);

#endif
