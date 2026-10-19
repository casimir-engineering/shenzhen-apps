#pragma once

#include <glib.h>

#include "shenzhen_pdf_core.h"

G_BEGIN_DECLS

typedef enum {
    SPDF_PASSWORD_PROMPT_DONE,
    SPDF_PASSWORD_PROMPT_FAILED,
    SPDF_PASSWORD_PROMPT_PRESENT_PARENT,
    SPDF_PASSWORD_PROMPT_ASK,
    SPDF_PASSWORD_PROMPT_CANCELLED,
} SpdfPasswordPromptAction;

typedef struct {
    gboolean has_parent;
    gboolean parent_mapped;
    gboolean awaiting_parent;
    gboolean incorrect;
} SpdfPasswordPromptFlow;

void spdf_password_prompt_flow_init(SpdfPasswordPromptFlow* flow, gboolean has_parent, gboolean parent_mapped);
SpdfPasswordPromptAction spdf_password_prompt_flow_opened(SpdfPasswordPromptFlow* flow, spdf_open_status status);
SpdfPasswordPromptAction spdf_password_prompt_flow_parent_ready(SpdfPasswordPromptFlow* flow);
SpdfPasswordPromptAction spdf_password_prompt_flow_cancel(SpdfPasswordPromptFlow* flow);

typedef struct {
    gboolean replace_live_state;
    gboolean advance_baseline;
    gboolean retry_pending;
} SpdfPasswordReloadPolicy;

SpdfPasswordReloadPolicy spdf_password_reload_policy(gboolean opened, gboolean cancelled);
char* spdf_password_reload_staging_path(const char* directory, const char* source_path);

typedef struct _SpdfPasswordAsyncState SpdfPasswordAsyncState;
typedef void (*SpdfPasswordAsyncDestroy)(gpointer user_data);

SpdfPasswordAsyncState* spdf_password_async_state_new(gpointer owner, SpdfPasswordAsyncDestroy destroy);
SpdfPasswordAsyncState* spdf_password_async_state_ref(SpdfPasswordAsyncState* state);
void spdf_password_async_state_unref(SpdfPasswordAsyncState* state);
guint64 spdf_password_async_state_begin(SpdfPasswordAsyncState* state);
gboolean spdf_password_async_state_accept(SpdfPasswordAsyncState* state, guint64 serial);
gboolean spdf_password_async_state_finish(SpdfPasswordAsyncState* state);
void spdf_password_async_state_cancel(SpdfPasswordAsyncState* state);
gboolean spdf_password_async_state_cancelled(SpdfPasswordAsyncState* state);
gpointer spdf_password_async_state_owner(SpdfPasswordAsyncState* state);

G_END_DECLS
