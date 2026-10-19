#include "shenzhen_pdf_core.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;

#define CHECK(condition, message)                   \
    do {                                            \
        if (!(condition)) {                         \
            fprintf(stderr, "FAIL: %s\n", message); \
            failures++;                             \
        }                                           \
    } while (0)

static unsigned long long bitmap_hash(const spdf_bitmap* bitmap) {
    unsigned long long hash = 1469598103934665603ULL;
    size_t bytes = (size_t)bitmap->stride * (size_t)bitmap->height;
    size_t i;

    for (i = 0; i < bytes; ++i) {
        hash ^= bitmap->rgba[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

static unsigned long long render_hash(spdf_document* doc) {
    spdf_bitmap bitmap;
    char err[512];
    unsigned long long hash = 0;

    memset(&bitmap, 0, sizeof(bitmap));
    CHECK(spdf_render_page_rgba(doc, 0, 1.0f, &bitmap, err, sizeof(err)), err);
    if (bitmap.rgba) hash = bitmap_hash(&bitmap);
    spdf_free_bitmap(&bitmap);
    return hash;
}

static spdf_document* open_password(const char* path, const char* password, spdf_open_status expected_status,
                                    spdf_authentication* authentication) {
    char err[512];
    spdf_open_status status = SPDF_OPEN_ERROR;
    spdf_document* doc = spdf_open_with_password(path, password, &status, authentication, err, sizeof(err));

    CHECK(status == expected_status, "unexpected typed open status");
    CHECK((expected_status == SPDF_OPEN_OK) == (doc != NULL), "status and document result disagree");
    return doc;
}

static void test_plain(const char* path, unsigned long long* expected_hash) {
    spdf_authentication authentication = SPDF_AUTHENTICATION_OWNER_PASSWORD;
    spdf_document* doc = open_password(path, NULL, SPDF_OPEN_OK, &authentication);

    if (!doc) return;
    CHECK(authentication == SPDF_AUTHENTICATION_NOT_REQUIRED, "plain PDF unexpectedly authenticated");
    CHECK(!spdf_is_password_protected(doc), "plain PDF marked password protected");
    CHECK(!spdf_needs_password(doc), "compatibility password flag differs");
    CHECK(spdf_page_count(doc) == 1, "plain fixture should have one page");
    *expected_hash = render_hash(doc);
    CHECK(*expected_hash != 0, "plain fixture did not render");
    spdf_close(doc);
}

static void test_locked(const char* path, unsigned long long expected_hash) {
    char err[512];
    spdf_open_status status = SPDF_OPEN_OK;
    spdf_authentication authentication = SPDF_AUTHENTICATION_NOT_REQUIRED;
    spdf_document* doc;

    doc = spdf_open_with_password(path, NULL, &status, &authentication, err, sizeof(err));
    CHECK(!doc, "locked PDF opened without a password");
    CHECK(status == SPDF_OPEN_PASSWORD_REQUIRED, "locked PDF did not report password required");
    CHECK(strcmp(err, "Password required.") == 0, "password-required error changed unexpectedly");

    doc = spdf_open(path, err, sizeof(err));
    CHECK(!doc, "compatibility opener returned a locked document");
    CHECK(strcmp(err, "Password required.") == 0, "compatibility opener did not explain the lock");

    doc = open_password(path, "wrong", SPDF_OPEN_BAD_PASSWORD, &authentication);
    CHECK(!doc, "wrong password returned a document");

    doc = open_password(path, "user-secret", SPDF_OPEN_OK, &authentication);
    if (!doc) return;
    CHECK((authentication & SPDF_AUTHENTICATION_USER_PASSWORD) != 0, "user password class was not preserved");
    CHECK(spdf_authentication_result(doc) == authentication, "stored authentication class differs");
    CHECK(spdf_is_password_protected(doc), "authenticated PDF lost its protected flag");
    CHECK(spdf_needs_password(doc), "compatibility protected flag differs");
    CHECK(spdf_is_password_protected(doc), "protected flag was not stable");
    CHECK(render_hash(doc) == expected_hash, "user-authenticated page differs from the plain source");
    spdf_close(doc);

    doc = open_password(path, "owner-secret", SPDF_OPEN_OK, &authentication);
    if (!doc) return;
    CHECK((authentication & SPDF_AUTHENTICATION_OWNER_PASSWORD) != 0, "owner password class was not preserved");
    CHECK(spdf_has_permission(doc, 'p'), "owner authentication lost print permission");
    CHECK(spdf_has_permission(doc, 'c'), "owner authentication lost copy permission");
    CHECK(spdf_has_permission(doc, 'e'), "owner authentication lost edit permission");
    CHECK(spdf_has_permission(doc, 'h'), "owner authentication lost high-quality print permission");
    CHECK(render_hash(doc) == expected_hash, "owner-authenticated page differs from the plain source");
    spdf_close(doc);
}

static void test_owner_only(const char* path, unsigned long long expected_hash) {
    char err[512];
    spdf_document* doc = spdf_open(path, err, sizeof(err));

    CHECK(doc != NULL, "blank-user-password PDF should open without a prompt");
    if (!doc) return;
    CHECK(!spdf_is_password_protected(doc), "blank-user-password PDF was marked prompt-protected");
    CHECK(render_hash(doc) == expected_hash, "blank-user-password page differs from the plain source");
    spdf_close(doc);
}

static void test_restricted(const char* path, unsigned long long expected_hash) {
    spdf_authentication authentication = SPDF_AUTHENTICATION_NOT_REQUIRED;
    spdf_document* doc = open_password(path, "view-secret", SPDF_OPEN_OK, &authentication);

    if (!doc) return;
    CHECK((authentication & SPDF_AUTHENTICATION_USER_PASSWORD) != 0, "restricted user password class missing");
    CHECK(spdf_has_permission(doc, 'p'), "restricted user should retain low-resolution print permission");
    /* Copy is granted unconditionally by product decision (see the header):
     * the flag is advisory, and the text is decrypted and on screen anyway.
     * The neighbouring edit/print assertions prove the OTHER flags are still
     * read from the document, so this is a deliberate exemption rather than a
     * broken permission query. */
    CHECK(spdf_has_permission(doc, 'c'), "copy must be allowed even for a restricted user");
    CHECK(!spdf_has_permission(doc, 'e'), "restricted user unexpectedly received edit permission");
    CHECK(!spdf_has_permission(doc, 'h'), "restricted user unexpectedly received high-quality print permission");
    CHECK(render_hash(doc) == expected_hash, "restricted user page differs from the plain source");
    spdf_close(doc);

    doc = open_password(path, "owner-secret", SPDF_OPEN_OK, &authentication);
    if (!doc) return;
    CHECK((authentication & SPDF_AUTHENTICATION_OWNER_PASSWORD) != 0, "restricted owner password class missing");
    CHECK(spdf_has_permission(doc, 'p'), "owner lost print permission");
    CHECK(spdf_has_permission(doc, 'c'), "owner lost copy permission");
    CHECK(spdf_has_permission(doc, 'e'), "owner lost edit permission");
    CHECK(spdf_has_permission(doc, 'h'), "owner lost high-quality print permission");
    CHECK(spdf_is_password_protected(doc), "owner protected flag was not stable");
    CHECK(render_hash(doc) == expected_hash, "restricted owner page differs from the plain source");
    spdf_close(doc);
}

int main(int argc, char** argv) {
    unsigned long long expected_hash = 0;

    if (argc != 5) {
        fprintf(stderr, "usage: %s plain.pdf locked.pdf owner-only.pdf restricted.pdf\n", argv[0]);
        return 2;
    }
    test_plain(argv[1], &expected_hash);
    test_locked(argv[2], expected_hash);
    test_owner_only(argv[3], expected_hash);
    test_restricted(argv[4], expected_hash);
    if (failures) {
        fprintf(stderr, "%d password-core assertion(s) failed\n", failures);
        return 1;
    }
    puts("SPDF core password tests passed");
    return 0;
}
