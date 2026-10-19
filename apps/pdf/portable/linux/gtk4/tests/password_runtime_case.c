#include <glib.h>
#include <glib/gstdio.h>

#include "../spdf_password.h"
#include "../spdf_password_controller.h"

typedef struct {
    GMainLoop* loop;
    int prompts;
    int destroyed;
    gboolean done;
    gboolean cancelled;
    spdf_document* document;
    SpdfPasswordCredential* credential;
} AsyncProbe;

static void async_probe_destroy(gpointer user_data) {
    AsyncProbe* probe = user_data;
    probe->destroyed++;
}

static void async_probe_ready(spdf_document* document, SpdfPasswordCredential* credential, gboolean cancelled,
                              const char* error, gpointer user_data) {
    AsyncProbe* probe = user_data;
    g_assert_null(error);
    probe->document = document;
    probe->credential = credential;
    probe->cancelled = cancelled;
    probe->done = TRUE;
    if (probe->loop) g_main_loop_quit(probe->loop);
}

static void async_probe_password(SpdfPasswordController* controller, gboolean incorrect, gpointer user_data) {
    AsyncProbe* probe = user_data;

    probe->prompts++;
    if (probe->prompts == 1) {
        g_assert_false(incorrect);
        spdf_password_controller_submit(controller, "wrong");
    } else {
        g_assert_true(incorrect);
        spdf_password_controller_submit(controller, "user-secret");
    }
}

static void async_probe_wait(AsyncProbe* probe) {
    if (!probe->done) {
        probe->loop = g_main_loop_new(NULL, FALSE);
        g_main_loop_run(probe->loop);
        g_main_loop_unref(probe->loop);
        probe->loop = NULL;
    }
    while (!probe->destroyed) g_main_context_iteration(NULL, TRUE);
}

static void test_locked(const char* path) {
    char err[256] = "";
    spdf_open_status status = SPDF_OPEN_ERROR;
    SpdfPasswordCredential* credential;
    spdf_document* document;

    document = spdf_password_open_document(path, NULL, &status, NULL, err, sizeof(err));
    g_assert_null(document);
    g_assert_cmpint(status, ==, SPDF_OPEN_PASSWORD_REQUIRED);

    credential = spdf_password_credential_new(path, "wrong");
    document = spdf_password_open_document(path, credential, &status, NULL, err, sizeof(err));
    g_assert_null(document);
    g_assert_cmpint(status, ==, SPDF_OPEN_BAD_PASSWORD);
    g_assert_false(spdf_password_credential_matches_source(credential));
    spdf_password_credential_unref(credential);

    credential = spdf_password_credential_new(path, "user-secret");
    document = spdf_password_open_document(path, credential, &status, NULL, err, sizeof(err));
    g_assert_nonnull(document);
    g_assert_cmpint(status, ==, SPDF_OPEN_OK);
    g_assert_true(spdf_is_password_protected(document));
    g_assert_cmpint(spdf_page_count(document), ==, 1);
    g_assert_cmpint(spdf_search_page(document, 0, "Encrypted", err, sizeof(err)), >, 0);
    spdf_close(document);
    spdf_password_credential_unref(credential);
}

static void test_restricted(const char* path) {
    char err[256] = "";
    spdf_open_status status = SPDF_OPEN_ERROR;
    SpdfPasswordCredential* credential = spdf_password_credential_new(path, "view-secret");
    spdf_document* document = spdf_password_open_document(path, credential, &status, NULL, err, sizeof(err));

    g_assert_nonnull(document);
    g_assert_cmpint(status, ==, SPDF_OPEN_OK);
    g_assert_true(spdf_has_permission(document, 'p'));
    g_assert_false(spdf_has_permission(document, 'h'));
    /* Copy is granted unconditionally by product decision (see the core
     * header): the flag is advisory, and the text is decrypted and on screen
     * anyway. The neighbouring print/edit assertions prove the OTHER flags are
     * still read from the document, so this is a deliberate exemption rather
     * than a broken permission query. */
    g_assert_true(spdf_has_permission(document, 'c'));
    g_assert_false(spdf_has_permission(document, 'e'));
    spdf_close(document);
    spdf_password_credential_unref(credential);
}

static void test_encrypted_edit_refresh(const char* locked_path) {
    char err[256] = "";
    char* directory = g_dir_make_tmp("spdf-password-edit-XXXXXX", NULL);
    char* path = g_build_filename(directory, "edited.pdf", NULL);
    char* bytes = NULL;
    gsize length = 0;
    SpdfPasswordCredential* live;
    SpdfPasswordSource old_worker = {0};
    SpdfPasswordSource new_worker = {0};
    spdf_document* live_document;
    spdf_document* worker_document;

    g_assert_true(g_file_get_contents(locked_path, &bytes, &length, NULL));
    g_assert_true(g_file_set_contents(path, bytes, length, NULL));
    live = spdf_password_credential_new(path, "user-secret");
    live_document = spdf_password_open_document(path, live, NULL, NULL, err, sizeof(err));
    g_assert_nonnull(live_document);
    spdf_close(live_document);
    spdf_password_source_init(&old_worker, path, live);

    g_usleep(2000);
    g_assert_true(g_file_set_contents(path, bytes, length, NULL));
    g_assert_true(spdf_password_credential_refresh_source(live, path));
    live_document = spdf_password_open_document(path, live, NULL, NULL, err, sizeof(err));
    g_assert_nonnull(live_document);
    g_assert_null(spdf_password_source_open(&old_worker, err, sizeof(err)));
    spdf_password_source_init(&new_worker, path, live);
    worker_document = spdf_password_source_open(&new_worker, err, sizeof(err));
    g_assert_nonnull(worker_document);

    spdf_close(worker_document);
    spdf_close(live_document);
    spdf_password_source_clear(&new_worker);
    spdf_password_source_clear(&old_worker);
    spdf_password_credential_unref(live);
    g_free(bytes);
    g_remove(path);
    g_rmdir(directory);
    g_free(path);
    g_free(directory);
}

static void test_async_retry(const char* locked_path) {
    AsyncProbe probe = {0};
    SpdfPasswordController* controller = spdf_password_controller_new(
        locked_path, locked_path, NULL, async_probe_password, async_probe_ready, &probe, async_probe_destroy);

    g_assert_nonnull(controller);
    spdf_password_controller_start(controller);
    async_probe_wait(&probe);
    g_assert_false(probe.cancelled);
    g_assert_cmpint(probe.prompts, ==, 2);
    g_assert_nonnull(probe.document);
    g_assert_nonnull(probe.credential);
    spdf_close(probe.document);
    spdf_password_credential_unref(probe.credential);
}

static void test_async_tab_close_cancel(const char* locked_path) {
    AsyncProbe probe = {0};
    SpdfPasswordController* controller = spdf_password_controller_new(
        locked_path, locked_path, NULL, async_probe_password, async_probe_ready, &probe, async_probe_destroy);

    g_assert_nonnull(controller);
    spdf_password_controller_start(controller);
    spdf_password_controller_cancel(controller);
    async_probe_wait(&probe);
    g_assert_true(probe.cancelled);
    g_assert_null(probe.document);
    g_assert_cmpint(probe.prompts, ==, 0);
    g_assert_cmpint(probe.destroyed, ==, 1);
}

int main(int argc, char** argv) {
    spdf_document* plain;
    spdf_document* owner_only;
    char err[256] = "";

    if (argc != 5) return 2;
    plain = spdf_password_open_document(argv[1], NULL, NULL, NULL, err, sizeof(err));
    owner_only = spdf_password_open_document(argv[3], NULL, NULL, NULL, err, sizeof(err));
    g_assert_nonnull(plain);
    g_assert_nonnull(owner_only);
    spdf_close(plain);
    spdf_close(owner_only);
    test_locked(argv[2]);
    test_restricted(argv[4]);
    test_encrypted_edit_refresh(argv[2]);
    test_async_retry(argv[2]);
    test_async_tab_close_cancel(argv[2]);
    g_print("GTK4 password runtime tests passed\n");
    return 0;
}
