#include "spdf_password_controller.h"

#include "spdf_password_lifecycle.h"

typedef struct {
    SpdfPasswordSource source;
    guint64 serial;
} PasswordAttempt;

typedef struct {
    spdf_document* document;
    spdf_open_status status;
    spdf_authentication authentication;
    char error[512];
    guint64 serial;
} PasswordAttemptResult;

struct _SpdfPasswordController {
    gint refs;
    SpdfPasswordAsyncState* state;
    GCancellable* cancellable;
    char* source_path;
    char* open_path;
    SpdfPasswordCredential* credential;
    SpdfPasswordNeedsSecret needs_secret;
    SpdfPasswordControllerReady ready;
    gpointer user_data;
    GDestroyNotify destroy;
};

static SpdfPasswordController* controller_ref(SpdfPasswordController* controller) {
    g_atomic_int_inc(&controller->refs);
    return controller;
}

static void controller_unref_count(SpdfPasswordController* controller, gint count) {
    gint previous;

    if (!controller || count <= 0) return;
    previous = g_atomic_int_add(&controller->refs, -count);
    g_return_if_fail(previous >= count);
    if (previous != count) return;
    g_clear_object(&controller->cancellable);
    spdf_password_credential_unref(controller->credential);
    spdf_password_async_state_unref(controller->state);
    g_free(controller->source_path);
    g_free(controller->open_path);
    if (controller->destroy) controller->destroy(controller->user_data);
    g_free(controller);
}

static void controller_unref(SpdfPasswordController* controller) {
    controller_unref_count(controller, 1);
}

static gboolean controller_finish(SpdfPasswordController* controller, spdf_document* document,
                                  SpdfPasswordCredential* credential, gboolean cancelled, const char* error) {
    if (!spdf_password_async_state_finish(controller->state)) {
        if (document) spdf_close(document);
        spdf_password_credential_unref(credential);
        return FALSE;
    }
    if (cancelled) g_cancellable_cancel(controller->cancellable);
    if (controller->ready) controller->ready(document, credential, cancelled, error, controller->user_data);
    return TRUE;
}

static void attempt_free(gpointer data) {
    PasswordAttempt* attempt = data;
    spdf_password_source_clear(&attempt->source);
    g_free(attempt);
}

static void result_free(gpointer data) {
    PasswordAttemptResult* result = data;
    if (!result) return;
    if (result->document) spdf_close(result->document);
    g_free(result);
}

static void attempt_run(GTask* task, gpointer source_object, gpointer task_data, GCancellable* cancellable) {
    PasswordAttempt* attempt = task_data;
    PasswordAttemptResult* result = g_new0(PasswordAttemptResult, 1);

    (void)source_object;
    result->serial = attempt->serial;
    if (!g_cancellable_is_cancelled(cancellable))
        result->document = spdf_password_source_open_typed(&attempt->source, &result->status, &result->authentication,
                                                           result->error, sizeof(result->error));
    g_task_return_pointer(task, result, result_free);
}

static void attempt_done(GObject* source, GAsyncResult* async_result, gpointer user_data) {
    SpdfPasswordController* controller = user_data;
    PasswordAttemptResult* result = g_task_propagate_pointer(G_TASK(async_result), NULL);

    (void)source;
    if (!result || !spdf_password_async_state_accept(controller->state, result->serial)) {
        result_free(result);
        controller_unref(controller);
        return;
    }
    if (result->document) {
        spdf_document* document = result->document;
        SpdfPasswordCredential* credential =
            spdf_is_password_protected(document) ? spdf_password_credential_ref(controller->credential) : NULL;
        result->document = NULL;
        result_free(result);
        controller_finish(controller, document, credential, FALSE, NULL);
        controller_unref_count(controller, 2); // Controller owner + this task callback.
        return;
    }
    if (result->status == SPDF_OPEN_PASSWORD_REQUIRED || result->status == SPDF_OPEN_BAD_PASSWORD) {
        gboolean incorrect = result->status == SPDF_OPEN_BAD_PASSWORD;
        spdf_password_credential_unref(controller->credential);
        controller->credential = NULL;
        result_free(result);
        if (controller->needs_secret) controller->needs_secret(controller, incorrect, controller->user_data);
    } else {
        char* error = g_strdup(result->error[0] ? result->error : "Could not open document.");
        gboolean finished;

        result_free(result);
        finished = controller_finish(controller, NULL, NULL, FALSE, error);
        g_free(error);
        controller_unref_count(controller, finished ? 2 : 1);
        return;
    }
    controller_unref(controller);
}

static void controller_attempt(SpdfPasswordController* controller) {
    PasswordAttempt* attempt = g_new0(PasswordAttempt, 1);
    GTask* task;

    attempt->serial = spdf_password_async_state_begin(controller->state);
    if (!attempt->serial) {
        g_free(attempt);
        return;
    }
    spdf_password_source_init(&attempt->source, controller->open_path, controller->credential);
    task = g_task_new(NULL, controller->cancellable, attempt_done, controller_ref(controller));
    g_task_set_task_data(task, attempt, attempt_free);
    g_task_set_return_on_cancel(task, FALSE);
    g_task_run_in_thread(task, attempt_run);
    g_object_unref(task);
}

SpdfPasswordController* spdf_password_controller_new(const char* source_path, const char* open_path,
                                                     SpdfPasswordCredential* credential,
                                                     SpdfPasswordNeedsSecret needs_secret,
                                                     SpdfPasswordControllerReady ready, gpointer user_data,
                                                     GDestroyNotify destroy) {
    SpdfPasswordController* controller;

    g_return_val_if_fail(open_path && *open_path, NULL);
    controller = g_new0(SpdfPasswordController, 1);
    controller->refs = 1;
    controller->state = spdf_password_async_state_new(NULL, NULL);
    controller->cancellable = g_cancellable_new();
    controller->source_path = g_canonicalize_filename(source_path && *source_path ? source_path : open_path, NULL);
    controller->open_path = g_canonicalize_filename(open_path, NULL);
    controller->credential = spdf_password_credential_ref(credential);
    controller->needs_secret = needs_secret;
    controller->ready = ready;
    controller->user_data = user_data;
    controller->destroy = destroy;
    return controller;
}

void spdf_password_controller_start(SpdfPasswordController* controller) {
    if (controller) controller_attempt(controller);
}

void spdf_password_controller_submit(SpdfPasswordController* controller, const char* password) {
    if (!controller || spdf_password_async_state_cancelled(controller->state)) return;
    spdf_password_credential_unref(controller->credential);
    controller->credential = spdf_password_credential_new(controller->source_path, password ? password : "");
    if (controller->credential)
        controller_attempt(controller);
    else if (controller_finish(controller, NULL, NULL, FALSE, "Could not prepare document credential."))
        controller_unref(controller);
}

void spdf_password_controller_cancel(SpdfPasswordController* controller) {
    if (!controller || spdf_password_async_state_cancelled(controller->state)) return;
    spdf_password_async_state_cancel(controller->state);
    g_cancellable_cancel(controller->cancellable);
    if (controller_finish(controller, NULL, NULL, TRUE, NULL)) controller_unref(controller);
}
