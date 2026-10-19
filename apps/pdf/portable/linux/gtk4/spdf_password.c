#include "spdf_password.h"

#include <string.h>
#include <sys/stat.h>

typedef struct {
    gint refs;
    GMutex lock;
    gboolean revoked;
} SpdfPasswordLease;

struct _SpdfPasswordCredential {
    gint refs;
    GMutex lock;
    char* source_path;
    char* source_identity;
    char* secret;
    gsize secret_len;
    guint64 generation;
    gboolean valid;
    SpdfPasswordLease* lease;
};

static SpdfPasswordLease* password_lease_new(void) {
    SpdfPasswordLease* lease = g_new0(SpdfPasswordLease, 1);

    lease->refs = 1;
    g_mutex_init(&lease->lock);
    return lease;
}

static SpdfPasswordLease* password_lease_ref(SpdfPasswordLease* lease) {
    if (lease) g_atomic_int_inc(&lease->refs);
    return lease;
}

static void password_lease_unref(SpdfPasswordLease* lease) {
    if (!lease || !g_atomic_int_dec_and_test(&lease->refs)) return;
    g_mutex_clear(&lease->lock);
    g_free(lease);
}

static void password_secure_zero(void* bytes, gsize length) {
    volatile unsigned char* cursor = bytes;

    while (length-- > 0) *cursor++ = 0;
}

static void password_invalidate_locked(SpdfPasswordCredential* credential) {
    if (credential->secret) {
        password_secure_zero(credential->secret, credential->secret_len + 1);
        g_clear_pointer(&credential->secret, g_free);
        credential->secret_len = 0;
    }
    credential->valid = FALSE;
    credential->generation++;
}

static char* password_canonical_path(const char* path) {
    return path && *path ? g_canonicalize_filename(path, NULL) : NULL;
}

static char* password_source_identity(const char* path) {
    char* canonical = password_canonical_path(path);
    struct stat st;
    long nanoseconds;
    long long seconds;
    char* identity;

    if (!canonical || stat(canonical, &st) != 0) {
        g_free(canonical);
        return NULL;
    }
#if defined(__APPLE__)
    seconds = (long long)st.st_mtimespec.tv_sec;
    nanoseconds = st.st_mtimespec.tv_nsec;
#else
    seconds = (long long)st.st_mtim.tv_sec;
    nanoseconds = st.st_mtim.tv_nsec;
#endif
    identity =
        g_strdup_printf("%s:%" G_GUINT64_FORMAT ":%" G_GUINT64_FORMAT ":%" G_GUINT64_FORMAT ":%lld:%ld", canonical,
                        (guint64)st.st_dev, (guint64)st.st_ino, (guint64)st.st_size, seconds, nanoseconds);
    g_free(canonical);
    return identity;
}

SpdfPasswordCredential* spdf_password_credential_new(const char* source_path, const char* password) {
    SpdfPasswordCredential* credential;
    char* canonical = password_canonical_path(source_path);
    char* identity = password_source_identity(source_path);
    gsize length;

    if (!canonical || !identity || !password) {
        g_free(canonical);
        g_free(identity);
        return NULL;
    }
    length = strlen(password);
    credential = g_new0(SpdfPasswordCredential, 1);
    credential->refs = 1;
    g_mutex_init(&credential->lock);
    credential->source_path = canonical;
    credential->source_identity = identity;
    credential->secret = g_malloc0(length + 1);
    if (length > 0) memcpy(credential->secret, password, length);
    credential->secret_len = length;
    credential->generation = 1;
    credential->valid = TRUE;
    credential->lease = password_lease_new();
    return credential;
}

SpdfPasswordCredential* spdf_password_credential_ref(SpdfPasswordCredential* credential) {
    if (credential) g_atomic_int_inc(&credential->refs);
    return credential;
}

SpdfPasswordCredential* spdf_password_credential_clone_for_open_path(SpdfPasswordCredential* credential,
                                                                     const char* open_path) {
    SpdfPasswordCredential* clone = NULL;
    char* canonical;
    char* identity = NULL;

    if (!credential) return NULL;
    canonical = password_canonical_path(open_path);
    g_mutex_lock(&credential->lease->lock);
    g_mutex_lock(&credential->lock);
    if (!credential->lease->revoked && credential->valid && credential->secret) {
        gboolean same_source = !canonical || g_strcmp0(canonical, credential->source_path) == 0;

        identity = same_source ? g_strdup(credential->source_identity) : password_source_identity(canonical);
        if (!identity) goto done;
        clone = g_new0(SpdfPasswordCredential, 1);
        clone->refs = 1;
        g_mutex_init(&clone->lock);
        clone->source_path = same_source ? g_strdup(credential->source_path) : g_steal_pointer(&canonical);
        clone->source_identity = g_steal_pointer(&identity);
        clone->secret = g_memdup2(credential->secret, credential->secret_len + 1);
        clone->secret_len = credential->secret_len;
        clone->generation = credential->generation;
        clone->valid = TRUE;
        clone->lease = password_lease_ref(credential->lease);
    }
done:
    g_mutex_unlock(&credential->lock);
    g_mutex_unlock(&credential->lease->lock);
    g_free(identity);
    g_free(canonical);
    return clone;
}

SpdfPasswordCredential* spdf_password_credential_clone(SpdfPasswordCredential* credential) {
    SpdfPasswordCredential* clone = spdf_password_credential_clone_for_open_path(credential, NULL);

    /* Transaction candidates must survive revoking the old live authority
     * after commit. Per-open worker clones use clone_for_open_path directly
     * and therefore still share the live revocation lease. */
    if (clone) {
        password_lease_unref(clone->lease);
        clone->lease = password_lease_new();
    }
    return clone;
}

void spdf_password_credential_unref(SpdfPasswordCredential* credential) {
    if (!credential || !g_atomic_int_dec_and_test(&credential->refs)) return;
    if (credential->secret) {
        password_secure_zero(credential->secret, credential->secret_len + 1);
        g_free(credential->secret);
    }
    g_free(credential->source_path);
    g_free(credential->source_identity);
    password_lease_unref(credential->lease);
    g_mutex_clear(&credential->lock);
    g_free(credential);
}

void spdf_password_credential_invalidate(SpdfPasswordCredential* credential) {
    if (!credential) return;
    g_mutex_lock(&credential->lock);
    password_invalidate_locked(credential);
    g_mutex_unlock(&credential->lock);
}

void spdf_password_credential_revoke(SpdfPasswordCredential* credential) {
    if (!credential) return;
    g_mutex_lock(&credential->lease->lock);
    credential->lease->revoked = TRUE;
    g_mutex_unlock(&credential->lease->lock);
    spdf_password_credential_invalidate(credential);
}

gboolean spdf_password_credential_matches_source(SpdfPasswordCredential* credential) {
    char* current;
    gboolean matches;

    if (!credential) return FALSE;
    g_mutex_lock(&credential->lease->lock);
    g_mutex_lock(&credential->lock);
    current = password_source_identity(credential->source_path);
    matches = !credential->lease->revoked && credential->valid && current &&
              g_strcmp0(current, credential->source_identity) == 0;
    g_free(current);
    if (!matches && credential->valid) password_invalidate_locked(credential);
    g_mutex_unlock(&credential->lock);
    g_mutex_unlock(&credential->lease->lock);
    return matches;
}

guint64 spdf_password_credential_generation(SpdfPasswordCredential* credential) {
    guint64 generation = 0;

    if (!credential) return 0;
    g_mutex_lock(&credential->lock);
    generation = credential->generation;
    g_mutex_unlock(&credential->lock);
    return generation;
}

gboolean spdf_password_credential_is_current(SpdfPasswordCredential* credential, guint64 generation) {
    gboolean current;

    if (!credential) return generation == 0;
    g_mutex_lock(&credential->lease->lock);
    g_mutex_lock(&credential->lock);
    current = !credential->lease->revoked && credential->valid && credential->generation == generation;
    g_mutex_unlock(&credential->lock);
    g_mutex_unlock(&credential->lease->lock);
    return current;
}

gboolean spdf_password_credential_refresh_source(SpdfPasswordCredential* credential, const char* source_path) {
    char* canonical;
    char* identity;

    if (!credential) return TRUE;
    canonical = password_canonical_path(source_path);
    identity = password_source_identity(source_path);
    if (!canonical || !identity) {
        g_free(canonical);
        g_free(identity);
        spdf_password_credential_invalidate(credential);
        return FALSE;
    }
    g_mutex_lock(&credential->lease->lock);
    g_mutex_lock(&credential->lock);
    if (credential->lease->revoked || !credential->valid || !credential->secret) {
        g_mutex_unlock(&credential->lock);
        g_mutex_unlock(&credential->lease->lock);
        g_free(canonical);
        g_free(identity);
        return FALSE;
    }
    g_free(credential->source_path);
    g_free(credential->source_identity);
    credential->source_path = canonical;
    credential->source_identity = identity;
    credential->generation++;
    g_mutex_unlock(&credential->lock);
    g_mutex_unlock(&credential->lease->lock);
    return TRUE;
}

static char* password_copy_secret(SpdfPasswordCredential* credential, gsize* length) {
    char* copy = NULL;
    char* current;
    gboolean matches;

    if (length) *length = 0;
    if (!credential) return NULL;
    g_mutex_lock(&credential->lease->lock);
    g_mutex_lock(&credential->lock);
    current = password_source_identity(credential->source_path);
    matches = !credential->lease->revoked && credential->valid && current &&
              g_strcmp0(current, credential->source_identity) == 0;
    g_free(current);
    if (matches && credential->secret) {
        copy = g_memdup2(credential->secret, credential->secret_len + 1);
        if (length) *length = credential->secret_len;
    } else if (credential->valid)
        password_invalidate_locked(credential);
    g_mutex_unlock(&credential->lock);
    g_mutex_unlock(&credential->lease->lock);
    return copy;
}

spdf_document* spdf_password_open_document(const char* open_path, SpdfPasswordCredential* credential,
                                           spdf_open_status* status, spdf_authentication* authentication, char* err,
                                           size_t err_len) {
    spdf_open_status local_status = SPDF_OPEN_ERROR;
    spdf_document* document;
    gsize secret_len = 0;
    char* secret = password_copy_secret(credential, &secret_len);

    document = spdf_open_with_password(open_path, secret, &local_status, authentication, err, err_len);
    if (secret) {
        password_secure_zero(secret, secret_len + 1);
        g_free(secret);
    }
    if (credential && (local_status == SPDF_OPEN_BAD_PASSWORD || local_status == SPDF_OPEN_PASSWORD_REQUIRED))
        spdf_password_credential_invalidate(credential);
    if (status) *status = local_status;
    return document;
}

void spdf_password_source_init(SpdfPasswordSource* source, const char* path, SpdfPasswordCredential* credential) {
    g_return_if_fail(source != NULL);
    source->path = g_strdup(path);
    source->credential = spdf_password_credential_ref(credential);
    source->generation = spdf_password_credential_generation(credential);
}

void spdf_password_source_clear(SpdfPasswordSource* source) {
    if (!source) return;
    g_clear_pointer(&source->path, g_free);
    spdf_password_credential_unref(source->credential);
    source->credential = NULL;
    source->generation = 0;
}

spdf_document* spdf_password_source_open_typed(const SpdfPasswordSource* source, spdf_open_status* status,
                                               spdf_authentication* authentication, char* err, size_t err_len) {
    SpdfPasswordCredential* isolated;
    spdf_document* document;

    if (status) *status = SPDF_OPEN_ERROR;
    if (!source || !source->path) {
        if (err && err_len > 0) g_snprintf(err, err_len, "%s", "No document source.");
        return NULL;
    }
    if (!source->credential)
        return spdf_password_open_document(source->path, NULL, status, authentication, err, err_len);
    if (!spdf_password_credential_is_current(source->credential, source->generation)) {
        if (err && err_len > 0) g_snprintf(err, err_len, "%s", "Document credential changed; operation canceled.");
        return NULL;
    }
    isolated = spdf_password_credential_clone_for_open_path(source->credential, source->path);
    if (!isolated) {
        if (err && err_len > 0) g_snprintf(err, err_len, "%s", "Document credential is no longer valid.");
        return NULL;
    }
    document = spdf_password_open_document(source->path, isolated, status, authentication, err, err_len);
    spdf_password_credential_unref(isolated);
    if (!spdf_password_credential_is_current(source->credential, source->generation)) {
        if (document) spdf_close(document);
        if (err && err_len > 0) g_snprintf(err, err_len, "%s", "Document credential changed; operation canceled.");
        return NULL;
    }
    return document;
}

spdf_document* spdf_password_source_open(const SpdfPasswordSource* source, char* err, size_t err_len) {
    return spdf_password_source_open_typed(source, NULL, NULL, err, err_len);
}

spdf_document* spdf_password_reopen_after_write(const char* source_path, const char* open_path,
                                                SpdfPasswordCredential* credential, char* err, size_t err_len) {
    if (!spdf_password_credential_refresh_source(credential, source_path)) {
        if (err && err_len > 0) g_snprintf(err, err_len, "%s", "Document credential is no longer valid.");
        return NULL;
    }
    return spdf_password_open_document(open_path, credential, NULL, NULL, err, err_len);
}
