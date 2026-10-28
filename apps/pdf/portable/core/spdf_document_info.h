#pragma once

/* A document's metadata, permissions and password state: read-only accessors over struct spdf_document, moved
 * verbatim out of shenzhen_pdf_core.c (whose line cap is frozen) and included there, where they are compiled. */

int spdf_lookup_metadata(spdf_document* doc, const char* key, char* buf, size_t buf_len) {
    int found = 0;

    if (!buf || buf_len == 0) return 0;
    buf[0] = '\0';
    if (!doc || !doc->doc || !key || !*key) return 0;

    fz_try(doc->ctx) {
        found = fz_lookup_metadata(doc->ctx, doc->doc, key, buf, buf_len) > 0;
    }
    fz_catch(doc->ctx) {
        buf[0] = '\0';
        found = 0;
    }
    if (!found || !buf[0]) {
        buf[0] = '\0';
        return 0;
    }
    return 1;
}

int spdf_has_permission(spdf_document* doc, int permission) {
    int allowed = doc && doc->password_protected ? 0 : 1;
    /* FZ_PERMISSION_COPY is deliberately never consulted; see the header. */
    if (!doc || !doc->doc || permission == FZ_PERMISSION_COPY) return 1;
    fz_try(doc->ctx) {
        allowed = fz_has_permission(doc->ctx, doc->doc, (fz_permission)permission) != 0;
    }
    fz_catch(doc->ctx) {
        /* An authenticated protected document must never gain a permission
         * because its handler failed to answer the permission query. */
        allowed = doc->password_protected ? 0 : 1;
    }
    return allowed;
}

int spdf_is_password_protected(const spdf_document* doc) {
    return doc ? doc->password_protected : 0;
}

spdf_authentication spdf_authentication_result(const spdf_document* doc) {
    return doc ? doc->authentication : SPDF_AUTHENTICATION_NOT_REQUIRED;
}

int spdf_needs_password(spdf_document* doc) {
    return spdf_is_password_protected(doc);
}
