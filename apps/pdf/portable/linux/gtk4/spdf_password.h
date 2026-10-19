#pragma once

#include <glib.h>

#include "shenzhen_pdf_core.h"

G_BEGIN_DECLS

typedef struct _SpdfPasswordCredential SpdfPasswordCredential;
typedef struct _SpdfPasswordSource {
    char* path;
    SpdfPasswordCredential* credential;
    guint64 generation;
} SpdfPasswordSource;
typedef struct {
    gboolean copy;
    gboolean edit;
    gboolean annotate;
} SpdfPasswordPermissions;

static inline SpdfPasswordPermissions spdf_password_permissions(spdf_document* document) {
    SpdfPasswordPermissions permissions = {FALSE, FALSE, FALSE};
    if (document) {
        permissions.copy = spdf_has_permission(document, 'c');
        permissions.edit = spdf_has_permission(document, 'e');
        permissions.annotate = spdf_has_permission(document, 'n');
    }
    return permissions;
}

SpdfPasswordCredential* spdf_password_credential_new(const char* source_path, const char* password);
SpdfPasswordCredential* spdf_password_credential_ref(SpdfPasswordCredential* credential);
SpdfPasswordCredential* spdf_password_credential_clone(SpdfPasswordCredential* credential);
SpdfPasswordCredential* spdf_password_credential_clone_for_open_path(SpdfPasswordCredential* credential,
                                                                     const char* open_path);
void spdf_password_credential_unref(SpdfPasswordCredential* credential);

void spdf_password_credential_invalidate(SpdfPasswordCredential* credential);
void spdf_password_credential_revoke(SpdfPasswordCredential* credential);
gboolean spdf_password_credential_matches_source(SpdfPasswordCredential* credential);
guint64 spdf_password_credential_generation(SpdfPasswordCredential* credential);
gboolean spdf_password_credential_is_current(SpdfPasswordCredential* credential, guint64 generation);

/* Retain the secret after a trusted in-app write or Save As while replacing
 * the source identity that future worker opens must match. */
gboolean spdf_password_credential_refresh_source(SpdfPasswordCredential* credential, const char* source_path);

/* Active-document opener. Worker jobs must use SpdfPasswordSource so a
 * generation change cancels their isolated open without invalidating the
 * live credential authority. */
spdf_document* spdf_password_open_document(const char* open_path, SpdfPasswordCredential* credential,
                                           spdf_open_status* status, spdf_authentication* authentication, char* err,
                                           size_t err_len);

/* Refcount-safe, generation-bound source snapshot for worker jobs. */
void spdf_password_source_init(SpdfPasswordSource* source, const char* path, SpdfPasswordCredential* credential);
void spdf_password_source_clear(SpdfPasswordSource* source);
spdf_document* spdf_password_source_open_typed(const SpdfPasswordSource* source, spdf_open_status* status,
                                               spdf_authentication* authentication, char* err, size_t err_len);
spdf_document* spdf_password_source_open(const SpdfPasswordSource* source, char* err, size_t err_len);
spdf_document* spdf_password_reopen_after_write(const char* source_path, const char* open_path,
                                                SpdfPasswordCredential* credential, char* err, size_t err_len);

G_END_DECLS
