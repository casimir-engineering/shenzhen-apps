#include <glib.h>
#include <glib/gstdio.h>

#include "../spdf_password.c"

struct spdf_document {
    int marker;
};

static const char* expected_password;
static gboolean require_password;
static gboolean saw_nonnull_password;
static struct spdf_document fake_document = {42};

void spdf_close(spdf_document* document) {
    (void)document;
}

spdf_document* spdf_open_with_password(const char* path, const char* password, spdf_open_status* status,
                                       spdf_authentication* authentication, char* err, size_t err_len) {
    (void)path;
    if (authentication) *authentication = SPDF_AUTHENTICATION_NOT_REQUIRED;
    if (!require_password) {
        if (status) *status = SPDF_OPEN_OK;
        return &fake_document;
    }
    saw_nonnull_password = password != NULL;
    if (!password) {
        if (status) *status = SPDF_OPEN_PASSWORD_REQUIRED;
        g_strlcpy(err, "Password required.", err_len);
        return NULL;
    }
    if (g_strcmp0(password, expected_password) != 0) {
        if (status) *status = SPDF_OPEN_BAD_PASSWORD;
        g_strlcpy(err, "Incorrect password.", err_len);
        return NULL;
    }
    if (status) *status = SPDF_OPEN_OK;
    if (authentication) *authentication = SPDF_AUTHENTICATION_USER_PASSWORD;
    return &fake_document;
}

static char* make_source(void) {
    char* directory = g_dir_make_tmp("spdf-gtk-password-XXXXXX", NULL);
    char* path = g_build_filename(directory, "source.pdf", NULL);

    g_assert_nonnull(directory);
    g_assert_true(g_file_set_contents(path, "first", -1, NULL));
    g_free(directory);
    return path;
}

static void remove_source(char* path) {
    char* directory = g_path_get_dirname(path);
    g_remove(path);
    g_rmdir(directory);
    g_free(directory);
    g_free(path);
}

static void test_open_and_invalidate(void) {
    char err[128] = "";
    char* path = make_source();
    SpdfPasswordCredential* credential = spdf_password_credential_new(path, "user-secret");
    spdf_open_status status = SPDF_OPEN_ERROR;
    guint64 generation;

    require_password = TRUE;
    expected_password = "user-secret";
    saw_nonnull_password = FALSE;
    g_assert_true(spdf_password_open_document(path, credential, &status, NULL, err, sizeof(err)) == &fake_document);
    g_assert_cmpint(status, ==, SPDF_OPEN_OK);
    g_assert_true(saw_nonnull_password);
    generation = spdf_password_credential_generation(credential);

    g_assert_true(g_file_set_contents(path, "source identity changed", -1, NULL));
    g_assert_false(spdf_password_credential_matches_source(credential));
    g_assert_cmpuint(spdf_password_credential_generation(credential), >, generation);
    g_assert_null(spdf_password_open_document(path, credential, &status, NULL, err, sizeof(err)));
    g_assert_cmpint(status, ==, SPDF_OPEN_PASSWORD_REQUIRED);

    spdf_password_credential_unref(credential);
    remove_source(path);
}

static void test_trusted_refresh_and_retarget(void) {
    char err[128] = "";
    char* path = make_source();
    char* directory = g_path_get_dirname(path);
    char* saved = g_build_filename(directory, "saved.pdf", NULL);
    SpdfPasswordCredential* credential = spdf_password_credential_new(path, "owner-secret");
    spdf_open_status status = SPDF_OPEN_ERROR;

    expected_password = "owner-secret";
    require_password = TRUE;
    g_assert_true(g_file_set_contents(path, "trusted in-place write", -1, NULL));
    g_assert_true(spdf_password_credential_refresh_source(credential, path));
    g_assert_true(spdf_password_credential_matches_source(credential));
    g_assert_true(spdf_password_open_document(path, credential, &status, NULL, err, sizeof(err)) == &fake_document);

    g_assert_true(g_file_set_contents(saved, "trusted save as", -1, NULL));
    g_assert_true(spdf_password_credential_refresh_source(credential, saved));
    g_assert_true(spdf_password_open_document(saved, credential, &status, NULL, err, sizeof(err)) == &fake_document);

    spdf_password_credential_invalidate(credential);
    g_assert_false(spdf_password_credential_matches_source(credential));
    spdf_password_credential_unref(credential);
    g_remove(saved);
    g_free(saved);
    g_free(directory);
    remove_source(path);
}

static void test_wrong_and_empty_passwords(void) {
    char err[128] = "";
    char* path = make_source();
    SpdfPasswordCredential* wrong = spdf_password_credential_new(path, "wrong");
    SpdfPasswordCredential* empty = spdf_password_credential_new(path, "");
    spdf_open_status status = SPDF_OPEN_ERROR;

    require_password = TRUE;
    expected_password = "right";
    g_assert_null(spdf_password_open_document(path, wrong, &status, NULL, err, sizeof(err)));
    g_assert_cmpint(status, ==, SPDF_OPEN_BAD_PASSWORD);
    g_assert_false(spdf_password_credential_matches_source(wrong));

    expected_password = "";
    saw_nonnull_password = FALSE;
    g_assert_true(spdf_password_open_document(path, empty, &status, NULL, err, sizeof(err)) == &fake_document);
    g_assert_true(saw_nonnull_password);
    spdf_password_credential_unref(wrong);
    spdf_password_credential_unref(empty);
    remove_source(path);
}

static void test_source_snapshot_owns_credential(void) {
    char err[128] = "";
    char* path = make_source();
    SpdfPasswordCredential* credential = spdf_password_credential_new(path, "worker-secret");
    SpdfPasswordSource source = {0};

    require_password = TRUE;
    expected_password = "worker-secret";
    spdf_password_source_init(&source, path, credential);
    spdf_password_credential_unref(credential);
    g_assert_true(spdf_password_source_open(&source, err, sizeof(err)) == &fake_document);
    spdf_password_source_clear(&source);
    g_assert_null(source.path);
    g_assert_null(source.credential);
    remove_source(path);
}

static void test_clone_invalidation_is_isolated(void) {
    char err[128] = "";
    char* path = make_source();
    SpdfPasswordCredential* live = spdf_password_credential_new(path, "reload-secret");
    SpdfPasswordCredential* attempt = spdf_password_credential_clone(live);

    require_password = TRUE;
    expected_password = "reload-secret";
    g_assert_nonnull(attempt);
    spdf_password_credential_invalidate(attempt);
    g_assert_true(spdf_password_credential_matches_source(live));
    g_assert_true(spdf_password_open_document(path, live, NULL, NULL, err, sizeof(err)) == &fake_document);
    spdf_password_credential_unref(attempt);
    spdf_password_credential_unref(live);
    remove_source(path);
}

static void test_worker_snapshot_cannot_invalidate_live_credential(void) {
    char err[128] = "";
    char* path = make_source();
    SpdfPasswordCredential* live = spdf_password_credential_new(path, "worker-secret");
    SpdfPasswordSource worker = {0};
    guint64 generation = spdf_password_credential_generation(live);

    require_password = TRUE;
    expected_password = "worker-secret";
    spdf_password_source_init(&worker, path, live);
    g_assert_true(g_file_set_contents(path, "changed externally", -1, NULL));
    g_assert_null(spdf_password_source_open(&worker, err, sizeof(err)));
    g_assert_cmpuint(spdf_password_credential_generation(live), ==, generation);
    spdf_password_source_clear(&worker);
    spdf_password_credential_unref(live);
    remove_source(path);
}

static void test_shadow_worker_tracks_opened_bytes(void) {
    char err[128] = "";
    char* path = make_source();
    char* directory = g_path_get_dirname(path);
    char* shadow = g_build_filename(directory, "shadow.pdf", NULL);
    SpdfPasswordCredential* live = spdf_password_credential_new(path, "shadow-secret");
    SpdfPasswordSource worker = {0};

    require_password = TRUE;
    expected_password = "shadow-secret";
    g_assert_true(g_file_set_contents(shadow, "stable encrypted copy", -1, NULL));
    spdf_password_source_init(&worker, shadow, live);
    g_assert_true(g_file_set_contents(path, "changed external source", -1, NULL));
    g_assert_true(spdf_password_source_open(&worker, err, sizeof(err)) == &fake_document);
    spdf_password_source_clear(&worker);
    spdf_password_credential_unref(live);
    g_remove(shadow);
    g_free(shadow);
    g_free(directory);
    remove_source(path);
}

static void test_close_revocation_reaches_worker_clones(void) {
    char err[128] = "";
    char* path = make_source();
    SpdfPasswordCredential* live = spdf_password_credential_new(path, "close-secret");
    SpdfPasswordSource worker = {0};

    require_password = TRUE;
    expected_password = "close-secret";
    spdf_password_source_init(&worker, path, live);
    spdf_password_credential_revoke(live);
    g_assert_null(spdf_password_source_open(&worker, err, sizeof(err)));
    spdf_password_source_clear(&worker);
    spdf_password_credential_unref(live);
    remove_source(path);
}

static void test_refresh_cancels_old_worker_and_authenticates_new(void) {
    char err[128] = "";
    char* path = make_source();
    SpdfPasswordCredential* live = spdf_password_credential_new(path, "edit-secret");
    SpdfPasswordSource old_worker = {0};
    SpdfPasswordSource new_worker = {0};

    require_password = TRUE;
    expected_password = "edit-secret";
    spdf_password_source_init(&old_worker, path, live);
    g_assert_true(g_file_set_contents(path, "trusted replacement", -1, NULL));
    g_assert_true(spdf_password_credential_refresh_source(live, path));
    g_assert_true(spdf_password_open_document(path, live, NULL, NULL, err, sizeof(err)) == &fake_document);
    g_assert_null(spdf_password_source_open(&old_worker, err, sizeof(err)));
    spdf_password_source_init(&new_worker, path, live);
    g_assert_true(spdf_password_source_open(&new_worker, err, sizeof(err)) == &fake_document);
    spdf_password_source_clear(&new_worker);
    spdf_password_source_clear(&old_worker);
    spdf_password_credential_unref(live);
    remove_source(path);
}

int main(int argc, char** argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/password/credential/open-invalidate", test_open_and_invalidate);
    g_test_add_func("/password/credential/trusted-refresh", test_trusted_refresh_and_retarget);
    g_test_add_func("/password/credential/wrong-empty", test_wrong_and_empty_passwords);
    g_test_add_func("/password/credential/clone-isolated", test_clone_invalidation_is_isolated);
    g_test_add_func("/password/credential/worker-isolated", test_worker_snapshot_cannot_invalidate_live_credential);
    g_test_add_func("/password/credential/shadow-worker", test_shadow_worker_tracks_opened_bytes);
    g_test_add_func("/password/credential/close-revokes-workers", test_close_revocation_reaches_worker_clones);
    g_test_add_func("/password/credential/edit-refresh-workers", test_refresh_cancels_old_worker_and_authenticates_new);
    g_test_add_func("/password/source/owns-credential", test_source_snapshot_owns_credential);
    return g_test_run();
}
