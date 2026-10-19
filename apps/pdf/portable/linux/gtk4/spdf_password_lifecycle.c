#include "spdf_password_lifecycle.h"

#include <string.h>

struct _SpdfPasswordAsyncState {
    gint refs;
    GMutex lock;
    guint64 serial;
    gboolean cancelled;
    gboolean finished;
    gpointer owner;
    SpdfPasswordAsyncDestroy destroy;
};

void spdf_password_prompt_flow_init(SpdfPasswordPromptFlow* flow, gboolean has_parent, gboolean parent_mapped) {
    g_return_if_fail(flow != NULL);
    *flow = (SpdfPasswordPromptFlow){
        .has_parent = has_parent,
        .parent_mapped = !has_parent || parent_mapped,
    };
}

SpdfPasswordPromptAction spdf_password_prompt_flow_opened(SpdfPasswordPromptFlow* flow, spdf_open_status status) {
    g_return_val_if_fail(flow != NULL, SPDF_PASSWORD_PROMPT_FAILED);
    if (status == SPDF_OPEN_OK) return SPDF_PASSWORD_PROMPT_DONE;
    if (status == SPDF_OPEN_ERROR) return SPDF_PASSWORD_PROMPT_FAILED;
    flow->incorrect = status == SPDF_OPEN_BAD_PASSWORD;
    if (!flow->parent_mapped) {
        flow->awaiting_parent = TRUE;
        return SPDF_PASSWORD_PROMPT_PRESENT_PARENT;
    }
    return SPDF_PASSWORD_PROMPT_ASK;
}

SpdfPasswordPromptAction spdf_password_prompt_flow_parent_ready(SpdfPasswordPromptFlow* flow) {
    g_return_val_if_fail(flow != NULL, SPDF_PASSWORD_PROMPT_FAILED);
    if (!flow->awaiting_parent) return SPDF_PASSWORD_PROMPT_FAILED;
    flow->awaiting_parent = FALSE;
    flow->parent_mapped = TRUE;
    return SPDF_PASSWORD_PROMPT_ASK;
}

SpdfPasswordPromptAction spdf_password_prompt_flow_cancel(SpdfPasswordPromptFlow* flow) {
    g_return_val_if_fail(flow != NULL, SPDF_PASSWORD_PROMPT_FAILED);
    flow->awaiting_parent = FALSE;
    return SPDF_PASSWORD_PROMPT_CANCELLED;
}

SpdfPasswordReloadPolicy spdf_password_reload_policy(gboolean opened, gboolean cancelled) {
    SpdfPasswordReloadPolicy policy = {0};

    if (opened) {
        policy.replace_live_state = TRUE;
        policy.advance_baseline = TRUE;
    } else {
        policy.retry_pending = TRUE;
        (void)cancelled;
    }
    return policy;
}

char* spdf_password_reload_staging_path(const char* directory, const char* source_path) {
    const char* extension = source_path ? strrchr(source_path, '.') : NULL;
    const char* slash = source_path ? strrchr(source_path, G_DIR_SEPARATOR) : NULL;
    char* uuid;
    GString* token;
    char* name;
    char* path;

    if (!directory || !*directory) return NULL;
    if (!extension || (slash && extension < slash)) extension = "";
    uuid = g_uuid_string_random();
    token = g_string_sized_new(32);
    for (const char* cursor = uuid; *cursor; ++cursor)
        if (*cursor != '-') g_string_append_c(token, *cursor);
    name = g_strdup_printf("ro-%s%s", token->str, extension);
    path = g_build_filename(directory, name, NULL);
    g_free(name);
    g_string_free(token, TRUE);
    g_free(uuid);
    return path;
}

SpdfPasswordAsyncState* spdf_password_async_state_new(gpointer owner, SpdfPasswordAsyncDestroy destroy) {
    SpdfPasswordAsyncState* state = g_new0(SpdfPasswordAsyncState, 1);

    state->refs = 1;
    state->owner = owner;
    state->destroy = destroy;
    g_mutex_init(&state->lock);
    return state;
}

SpdfPasswordAsyncState* spdf_password_async_state_ref(SpdfPasswordAsyncState* state) {
    if (state) g_atomic_int_inc(&state->refs);
    return state;
}

void spdf_password_async_state_unref(SpdfPasswordAsyncState* state) {
    if (!state || !g_atomic_int_dec_and_test(&state->refs)) return;
    if (state->destroy) state->destroy(state->owner);
    g_mutex_clear(&state->lock);
    g_free(state);
}

guint64 spdf_password_async_state_begin(SpdfPasswordAsyncState* state) {
    guint64 serial = 0;

    if (!state) return 0;
    g_mutex_lock(&state->lock);
    if (!state->cancelled && !state->finished) serial = ++state->serial;
    g_mutex_unlock(&state->lock);
    return serial;
}

gboolean spdf_password_async_state_accept(SpdfPasswordAsyncState* state, guint64 serial) {
    gboolean accept;

    if (!state || serial == 0) return FALSE;
    g_mutex_lock(&state->lock);
    accept = !state->cancelled && !state->finished && state->serial == serial;
    g_mutex_unlock(&state->lock);
    return accept;
}

gboolean spdf_password_async_state_finish(SpdfPasswordAsyncState* state) {
    gboolean finish;

    if (!state) return FALSE;
    g_mutex_lock(&state->lock);
    finish = !state->finished;
    state->finished = TRUE;
    state->serial++;
    g_mutex_unlock(&state->lock);
    return finish;
}

void spdf_password_async_state_cancel(SpdfPasswordAsyncState* state) {
    if (!state) return;
    g_mutex_lock(&state->lock);
    state->cancelled = TRUE;
    state->serial++;
    g_mutex_unlock(&state->lock);
}

gboolean spdf_password_async_state_cancelled(SpdfPasswordAsyncState* state) {
    gboolean cancelled;

    if (!state) return TRUE;
    g_mutex_lock(&state->lock);
    cancelled = state->cancelled;
    g_mutex_unlock(&state->lock);
    return cancelled;
}

gpointer spdf_password_async_state_owner(SpdfPasswordAsyncState* state) {
    gpointer owner;

    if (!state) return NULL;
    g_mutex_lock(&state->lock);
    owner = state->cancelled || state->finished ? NULL : state->owner;
    g_mutex_unlock(&state->lock);
    return owner;
}
