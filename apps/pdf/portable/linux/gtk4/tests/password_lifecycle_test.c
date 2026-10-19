#include <glib.h>

#include "../spdf_password_lifecycle.c"

static void test_startup_waits_for_mapped_parent(void) {
    SpdfPasswordPromptFlow flow;

    spdf_password_prompt_flow_init(&flow, TRUE, FALSE);
    g_assert_cmpint(spdf_password_prompt_flow_opened(&flow, SPDF_OPEN_PASSWORD_REQUIRED), ==,
                    SPDF_PASSWORD_PROMPT_PRESENT_PARENT);
    g_assert_true(flow.awaiting_parent);
    g_assert_cmpint(spdf_password_prompt_flow_parent_ready(&flow), ==, SPDF_PASSWORD_PROMPT_ASK);
    g_assert_true(flow.parent_mapped);
    g_assert_false(flow.incorrect);
}

static void test_command_line_without_parent_can_prompt(void) {
    SpdfPasswordPromptFlow flow;

    spdf_password_prompt_flow_init(&flow, FALSE, FALSE);
    g_assert_cmpint(spdf_password_prompt_flow_opened(&flow, SPDF_OPEN_PASSWORD_REQUIRED), ==, SPDF_PASSWORD_PROMPT_ASK);
}

static void test_wrong_password_retries_and_cancel_stops(void) {
    SpdfPasswordPromptFlow flow;

    spdf_password_prompt_flow_init(&flow, TRUE, TRUE);
    g_assert_cmpint(spdf_password_prompt_flow_opened(&flow, SPDF_OPEN_PASSWORD_REQUIRED), ==, SPDF_PASSWORD_PROMPT_ASK);
    g_assert_false(flow.incorrect);
    g_assert_cmpint(spdf_password_prompt_flow_opened(&flow, SPDF_OPEN_BAD_PASSWORD), ==, SPDF_PASSWORD_PROMPT_ASK);
    g_assert_true(flow.incorrect);
    g_assert_cmpint(spdf_password_prompt_flow_opened(&flow, SPDF_OPEN_OK), ==, SPDF_PASSWORD_PROMPT_DONE);
    spdf_password_prompt_flow_init(&flow, TRUE, TRUE);
    g_assert_cmpint(spdf_password_prompt_flow_opened(&flow, SPDF_OPEN_PASSWORD_REQUIRED), ==, SPDF_PASSWORD_PROMPT_ASK);
    g_assert_cmpint(spdf_password_prompt_flow_cancel(&flow), ==, SPDF_PASSWORD_PROMPT_CANCELLED);
}

typedef struct {
    int destroyed;
    int accepted;
} AsyncOwner;

typedef struct {
    SpdfPasswordAsyncState* state;
    guint64 serial;
    AsyncOwner* owner;
} AsyncCompletion;

static void async_owner_destroy(gpointer user_data) {
    AsyncOwner* owner = user_data;
    owner->destroyed++;
}

static gboolean async_completion_run(gpointer user_data) {
    AsyncCompletion* completion = user_data;
    if (spdf_password_async_state_accept(completion->state, completion->serial)) completion->owner->accepted++;
    spdf_password_async_state_unref(completion->state);
    g_free(completion);
    return G_SOURCE_REMOVE;
}

static void test_tab_close_cancels_scheduled_completion(void) {
    AsyncOwner owner = {0};
    SpdfPasswordAsyncState* state = spdf_password_async_state_new(&owner, async_owner_destroy);
    AsyncCompletion* completion = g_new0(AsyncCompletion, 1);

    completion->state = spdf_password_async_state_ref(state);
    completion->serial = spdf_password_async_state_begin(state);
    completion->owner = &owner;
    g_idle_add(async_completion_run, completion);
    spdf_password_async_state_cancel(state);
    g_assert_true(spdf_password_async_state_finish(state));
    spdf_password_async_state_unref(state);
    while (g_main_context_iteration(NULL, FALSE)) {
    }
    g_assert_cmpint(owner.accepted, ==, 0);
    g_assert_cmpint(owner.destroyed, ==, 1);
}

static void test_retry_supersedes_old_async_attempt(void) {
    AsyncOwner owner = {0};
    SpdfPasswordAsyncState* state = spdf_password_async_state_new(&owner, async_owner_destroy);
    guint64 wrong = spdf_password_async_state_begin(state);
    guint64 retry = spdf_password_async_state_begin(state);

    g_assert_false(spdf_password_async_state_accept(state, wrong));
    g_assert_true(spdf_password_async_state_accept(state, retry));
    g_assert_true(spdf_password_async_state_finish(state));
    spdf_password_async_state_unref(state);
    g_assert_cmpint(owner.destroyed, ==, 1);
}

static void test_watcher_cancel_preserves_then_later_retry_commits(void) {
    char* live_document = g_strdup("live-document");
    char* live_credential = g_strdup("live-credential");
    char* live_render = g_strdup("live-render");
    guint64 baseline = 10;
    SpdfPasswordReloadPolicy policy = spdf_password_reload_policy(FALSE, TRUE);

    g_assert_false(policy.replace_live_state);
    g_assert_cmpstr(live_document, ==, "live-document");
    g_assert_cmpstr(live_credential, ==, "live-credential");
    g_assert_cmpstr(live_render, ==, "live-render");
    g_assert_cmpuint(baseline, ==, 10);
    g_assert_true(policy.retry_pending);
    policy = spdf_password_reload_policy(TRUE, FALSE);
    if (policy.replace_live_state) {
        g_free(live_document);
        g_free(live_credential);
        g_free(live_render);
        live_document = g_strdup("replacement-document");
        live_credential = g_strdup("replacement-credential");
        live_render = g_strdup("replacement-render");
        baseline = 20;
    }
    g_assert_cmpstr(live_document, ==, "replacement-document");
    g_assert_cmpstr(live_credential, ==, "replacement-credential");
    g_assert_cmpstr(live_render, ==, "replacement-render");
    g_assert_cmpuint(baseline, ==, 20);
    g_free(live_document);
    g_free(live_credential);
    g_free(live_render);
}

static void test_watcher_error_also_preserves_baseline(void) {
    SpdfPasswordReloadPolicy policy = spdf_password_reload_policy(FALSE, FALSE);

    g_assert_false(policy.replace_live_state);
    g_assert_false(policy.advance_baseline);
    g_assert_true(policy.retry_pending);
}

static void test_reload_staging_path_is_unique_and_private_shaped(void) {
    char* first = spdf_password_reload_staging_path("/tmp/private", "/docs/report.pdf");
    char* second = spdf_password_reload_staging_path("/tmp/private", "/docs/report.pdf");
    char* base = g_path_get_basename(first);

    g_assert_true(g_str_has_prefix(first, "/tmp/private/ro-"));
    g_assert_true(g_str_has_suffix(first, ".pdf"));
    g_assert_cmpuint(strlen(base), ==, strlen("ro-") + 32 + strlen(".pdf"));
    g_assert_cmpstr(first, !=, second);
    g_free(base);
    g_free(second);
    g_free(first);
}

int main(int argc, char** argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/password/lifecycle/startup-mapped-parent", test_startup_waits_for_mapped_parent);
    g_test_add_func("/password/lifecycle/command-line-no-parent", test_command_line_without_parent_can_prompt);
    g_test_add_func("/password/lifecycle/wrong-retry-cancel", test_wrong_password_retries_and_cancel_stops);
    g_test_add_func("/password/lifecycle/tab-close-cancel", test_tab_close_cancels_scheduled_completion);
    g_test_add_func("/password/lifecycle/stale-retry", test_retry_supersedes_old_async_attempt);
    g_test_add_func("/password/lifecycle/watcher-cancel-retry", test_watcher_cancel_preserves_then_later_retry_commits);
    g_test_add_func("/password/lifecycle/watcher-error", test_watcher_error_also_preserves_baseline);
    g_test_add_func("/password/lifecycle/reload-staging-path", test_reload_staging_path_is_unique_and_private_shaped);
    return g_test_run();
}
