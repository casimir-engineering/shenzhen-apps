// spdf_updater.c — auto-updater for the GTK4 frontend. Linux port of
// portable/mac/SPDFUpdater.mm with minisign replacing Apple notarization
// (gtk4-parity-spec.md) and pkexec/dpkg replacing the .app atomic swap for
// system installs (a deb install is root-owned).
//
// Layering (top of file is pure and unit-tested offline; the bottom is the
// GTK/transport/install glue):
//   1. version compare + daily-gate delay                    (pure)
//   2. minisign parse + Ed25519/BLAKE2b verify via OpenSSL   (pure)
//   3. structural JSON scanner + GitHub release parse        (pure)
//   4. availability decision + release-notes formatting      (pure)
//   5. update.json store parse/serialize                     (pure)
//   6. paths, flock'd store access, liveness lease
//   7. transport: GSubprocess curl (preferred) / wget fallback
//   8. check pipeline (worker thread), prompt + progress UI
//   9. install: pkexec dpkg -i (deb) / atomic binary swap (user-local)
//  10. launch health check (pendingTag/updateOk), relaunch
//  11. spdf_updater_start / check_interactive / CLI flags
//
// TRANSPORT DECISION: no new build dependencies are allowed (openssl + glib
// only), so HTTPS is delegated to a runtime-probed `curl` (else `wget`)
// via GSubprocess; when neither exists the updater disables itself with a
// logged reason (and says so on the manual check path). Rationale: libsoup
// is a new dependency; GSocketClient+GTlsClientConnection means hand-rolling
// an HTTP/1.1 client (redirects, chunked encoding) on top of a TLS backend
// that is itself a runtime module (glib-networking) — strictly more fragile
// than execing a battle-tested fetcher. curl/wget enforce https-only
// (--proto '=https' --proto-redir '=https' / --https-only), bounded
// redirects and timeouts for us, and the SECURITY BOUNDARY IS NOT THE
// TRANSPORT: nothing is installed unless the minisign signature verifies
// against the pinned pubkey below. The deb should Recommends: curl.

#include "spdf_updater.h"

#include <fcntl.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#include <openssl/evp.h>

#ifndef SPDF_UPDATER_TESTING
#include <signal.h>
#include <sys/wait.h>

#include <glib/gstdio.h>
#endif

// ---------------------------------------------------------------------------
// Constants

// Pinned minisign public key (portable/linux/pkg/minisign.pub, key id
// 95F72498E795D0DD). cut-release.sh signs the Linux release assets with the
// matching secret key (`minisign -S`); this constant is the only key the
// updater will ever accept.
static const char k_spdf_pinned_pubkey[] = "RWTd0JXnmCT3lfku0las2n0Y63vQ1JN6xxfV7WRYdbOMoNX4on2o5azz";

#define SPDF_UPDATER_RELEASES_LATEST_URL "https://api.github.com/repos/casimir-engineering/shenzhen-pdf/releases/latest"

// Release asset names (same convention as ShenzhenPDF-mac-arm64.dmg). The
// deb serves system installs; the tarball (containing the ShenzhenPDF-gtk4
// binary) serves user-local installs under $HOME. Each ships a detached
// minisign signature named "<asset>.minisig".
#define SPDF_UPDATER_DEB_ASSET "ShenzhenPDF-linux-amd64.deb"
#define SPDF_UPDATER_TAR_ASSET "ShenzhenPDF-linux-amd64.tar.gz"

#define SPDF_UPDATER_DAILY_INTERVAL ((gint64)86400) // 24h rolling gate
#define SPDF_UPDATER_IDLE_DELAY_SECONDS 5           // post-launch settle
#define SPDF_UPDATER_CADENCE_SECONDS 3600           // re-arm poll while running
#define SPDF_UPDATER_NET_TIMEOUT_SECONDS 15         // API check
#define SPDF_UPDATER_ASSET_TIMEOUT_SECONDS 600      // asset download
#define SPDF_UPDATER_LEASE_STALE_SECONDS ((gint64)3600)
#define SPDF_UPDATER_LATER_SNOOZE_SECONDS ((gint64)(7 * 86400))
#define SPDF_UPDATER_MAX_ASSET_BYTES ((gint64)256 * 1024 * 1024)
#define SPDF_UPDATER_MAX_SIG_BYTES ((gint64)64 * 1024)
#define SPDF_UPDATER_HEALTH_PROBE_TIMEOUT_SECONDS 10
#define SPDF_UPDATER_NOTES_CHAR_CAP 500

static void set_error(char** error, const char* message) {
    if (error && !*error) *error = g_strdup(message);
}

// ===========================================================================
// 1. Version compare + daily-gate delay (pure)
// ===========================================================================

gint64 spdf_updater_daily_check_delay(gboolean auto_update_enabled, gboolean have_last_check, gint64 last_check_epoch,
                                      gint64 now_epoch) {
    gint64 elapsed;

    if (!auto_update_enabled) return -1;
    if (!have_last_check) return 0; // fresh install: due immediately
    elapsed = now_epoch - last_check_epoch;
    if (elapsed >= SPDF_UPDATER_DAILY_INTERVAL) return 0;
    // Rolling 24h window, deliberately NOT calendar-day based; a backwards
    // clock (negative elapsed) yields a delay > 24h — gate stays closed.
    return SPDF_UPDATER_DAILY_INTERVAL - elapsed;
}

// ===========================================================================
// 2. Minisign parse + verify (pure; OpenSSL EVP_PKEY_ED25519 + EVP_blake2b512)
// ===========================================================================

// Returns the first line that is not empty and not an "untrusted comment:",
// starting from lines[*index]; advances *index past the returned line.
static const char* minisign_next_payload_line(char** lines, guint* index) {
    for (; lines[*index]; ++(*index)) {
        char* line = g_strchomp(lines[*index]); // in-place: strip \r / spaces
        if (!*line) continue;
        if (g_str_has_prefix(line, "untrusted comment:")) continue;
        (*index)++;
        return line;
    }
    return NULL;
}

gboolean spdf_minisign_parse_pubkey(const char* text, SpdfMinisignKey* out, char** error) {
    char** lines;
    guint index = 0;
    const char* key_line;
    guchar* raw = NULL;
    gsize raw_len = 0;
    gboolean ok = FALSE;

    if (out) memset(out, 0, sizeof(*out));
    if (!text || !out) {
        set_error(error, "no public key data");
        return FALSE;
    }
    lines = g_strsplit(text, "\n", -1);
    key_line = minisign_next_payload_line(lines, &index);
    if (key_line) raw = g_base64_decode(key_line, &raw_len);
    if (raw && raw_len == 42 && raw[0] == 'E' && raw[1] == 'd') {
        memcpy(out->key_id, raw + 2, 8);
        memcpy(out->key, raw + 10, 32);
        ok = TRUE;
    } else {
        set_error(error, "malformed minisign public key");
    }
    g_free(raw);
    g_strfreev(lines);
    return ok;
}

gboolean spdf_minisign_parse_sig(const char* text, SpdfMinisignSig* out, char** error) {
    char** lines;
    gboolean have_sig = FALSE;
    gboolean ok = TRUE;

    if (out) memset(out, 0, sizeof(*out));
    if (!text || !out) {
        set_error(error, "no signature data");
        return FALSE;
    }
    lines = g_strsplit(text, "\n", -1);
    for (guint i = 0; ok && lines[i]; ++i) {
        char* line = g_strchomp(lines[i]);
        guchar* raw;
        gsize raw_len = 0;

        if (!*line) continue;
        if (g_str_has_prefix(line, "untrusted comment:")) continue;
        if (g_str_has_prefix(line, "trusted comment:")) {
            // The global signature covers the comment text WITHOUT the
            // "trusted comment: " prefix (one space skipped when present).
            const char* comment = line + strlen("trusted comment:");
            if (*comment == ' ') comment++;
            g_free(out->trusted_comment);
            out->trusted_comment = g_strdup(comment);
            continue;
        }
        raw = g_base64_decode(line, &raw_len);
        if (!have_sig) {
            if (raw && raw_len == 74 && raw[0] == 'E' && (raw[1] == 'd' || raw[1] == 'D')) {
                out->prehashed = (raw[1] == 'D');
                memcpy(out->key_id, raw + 2, 8);
                memcpy(out->sig, raw + 10, 64);
                have_sig = TRUE;
            } else {
                set_error(error, "malformed minisign signature");
                ok = FALSE;
            }
        } else if (!out->has_global_sig) {
            if (raw && raw_len == 64) {
                memcpy(out->global_sig, raw, 64);
                out->has_global_sig = TRUE;
            } else {
                set_error(error, "malformed minisign global signature");
                ok = FALSE;
            }
        }
        g_free(raw);
    }
    g_strfreev(lines);
    if (ok && !have_sig) {
        set_error(error, "no signature line found");
        ok = FALSE;
    }
    if (!ok) spdf_minisign_sig_clear(out);
    return ok;
}

void spdf_minisign_sig_clear(SpdfMinisignSig* sig) {
    if (!sig) return;
    g_free(sig->trusted_comment);
    memset(sig, 0, sizeof(*sig));
}

static gboolean ed25519_verify(const guint8 key[32], const guint8 sig[64], const guint8* msg, gsize msg_len) {
    EVP_PKEY* pkey = EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, NULL, key, 32);
    EVP_MD_CTX* ctx = pkey ? EVP_MD_CTX_new() : NULL;
    gboolean ok = FALSE;

    if (ctx && EVP_DigestVerifyInit(ctx, NULL, NULL, NULL, pkey) == 1 &&
        EVP_DigestVerify(ctx, sig, 64, msg, msg_len) == 1)
        ok = TRUE;
    if (ctx) EVP_MD_CTX_free(ctx);
    if (pkey) EVP_PKEY_free(pkey);
    return ok;
}

gboolean spdf_minisign_verify_buffer(const SpdfMinisignKey* key, const SpdfMinisignSig* sig, const guint8* data,
                                     gsize len, char** error) {
    guint8 digest[EVP_MAX_MD_SIZE];
    const guint8* msg;
    gsize msg_len;

    if (!key || !sig || (!data && len > 0)) {
        set_error(error, "nothing to verify");
        return FALSE;
    }
    if (memcmp(key->key_id, sig->key_id, 8) != 0) {
        set_error(error, "signature key id does not match the pinned public key");
        return FALSE;
    }
    if (sig->prehashed) { // "ED": Ed25519 over BLAKE2b-512(content)
        unsigned int digest_len = 0;
        if (EVP_Digest(data, len, digest, &digest_len, EVP_blake2b512(), NULL) != 1 || digest_len != 64) {
            set_error(error, "BLAKE2b-512 digest failed");
            return FALSE;
        }
        msg = digest;
        msg_len = 64;
    } else { // "Ed": Ed25519 over the raw content
        msg = data;
        msg_len = len;
    }
    if (!ed25519_verify(key->key, sig->sig, msg, msg_len)) {
        set_error(error, "Ed25519 signature verification failed");
        return FALSE;
    }
    // Global signature (over sig || trusted comment). A well-formed .minisig
    // always carries both lines; if either appears, both must and must verify.
    if (sig->trusted_comment || sig->has_global_sig) {
        gsize comment_len;
        guint8* buf;
        gboolean ok;

        if (!sig->trusted_comment || !sig->has_global_sig) {
            set_error(error, "incomplete trusted-comment section");
            return FALSE;
        }
        comment_len = strlen(sig->trusted_comment);
        buf = g_malloc(64 + comment_len);
        memcpy(buf, sig->sig, 64);
        memcpy(buf + 64, sig->trusted_comment, comment_len);
        ok = ed25519_verify(key->key, sig->global_sig, buf, 64 + comment_len);
        g_free(buf);
        if (!ok) {
            set_error(error, "global signature verification failed");
            return FALSE;
        }
    }
    return TRUE;
}

gboolean spdf_minisign_verify_file(const SpdfMinisignKey* key, const char* sig_text, const char* path, char** error) {
    SpdfMinisignSig sig;
    char* contents = NULL;
    gsize len = 0;
    gboolean ok;

    if (!spdf_minisign_parse_sig(sig_text, &sig, error)) return FALSE;
    if (!g_file_get_contents(path, &contents, &len, NULL)) {
        set_error(error, "could not read the downloaded file for verification");
        spdf_minisign_sig_clear(&sig);
        return FALSE;
    }
    ok = spdf_minisign_verify_buffer(key, &sig, (const guint8*)contents, len, error);
    g_free(contents);
    spdf_minisign_sig_clear(&sig);
    return ok;
}

// ===========================================================================
// 3. Structural JSON scanner + GitHub release parse (pure)
// ===========================================================================
// A linear tokenizer that walks strings with full escape handling, so
// braces/quotes inside the release "body" can never confuse the asset scan
// (unlike spdf_state.c's strstr-based helpers, which only face our own
// well-known writers).

typedef struct {
    const char* p;
    const char* end;
} JsCursor;

static void js_skip_ws(JsCursor* c) {
    while (c->p < c->end && (*c->p == ' ' || *c->p == '\t' || *c->p == '\n' || *c->p == '\r')) c->p++;
}

// Cursor at '"'. Consumes through the closing quote; decoded content appended
// to `out` when non-NULL.
static gboolean js_parse_string(JsCursor* c, GString* out) {
    if (c->p >= c->end || *c->p != '"') return FALSE;
    c->p++;
    while (c->p < c->end) {
        unsigned char ch = (unsigned char)*c->p;
        if (ch == '"') {
            c->p++;
            return TRUE;
        }
        if (ch == '\\') {
            c->p++;
            if (c->p >= c->end) return FALSE;
            switch (*c->p) {
                case '"':
                    if (out) g_string_append_c(out, '"');
                    break;
                case '\\':
                    if (out) g_string_append_c(out, '\\');
                    break;
                case '/':
                    if (out) g_string_append_c(out, '/');
                    break;
                case 'b':
                    if (out) g_string_append_c(out, '\b');
                    break;
                case 'f':
                    if (out) g_string_append_c(out, '\f');
                    break;
                case 'n':
                    if (out) g_string_append_c(out, '\n');
                    break;
                case 'r':
                    if (out) g_string_append_c(out, '\r');
                    break;
                case 't':
                    if (out) g_string_append_c(out, '\t');
                    break;
                case 'u': {
                    gunichar u = 0;
                    if (c->end - c->p < 5) return FALSE;
                    for (int i = 1; i <= 4; ++i) {
                        int digit = g_ascii_xdigit_value(c->p[i]);
                        if (digit < 0) return FALSE;
                        u = (u << 4) | (gunichar)digit;
                    }
                    c->p += 4;
                    if (u >= 0xD800 && u <= 0xDBFF && c->end - c->p >= 7 && c->p[1] == '\\' && c->p[2] == 'u') {
                        gunichar lo = 0;
                        gboolean valid = TRUE;
                        for (int i = 3; i <= 6; ++i) {
                            int digit = g_ascii_xdigit_value(c->p[i]);
                            if (digit < 0)
                                valid = FALSE;
                            else
                                lo = (lo << 4) | (gunichar)digit;
                        }
                        if (valid && lo >= 0xDC00 && lo <= 0xDFFF) {
                            u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00);
                            c->p += 6;
                        }
                    }
                    if (out && g_unichar_validate(u)) g_string_append_unichar(out, u);
                    break;
                }
                default:
                    return FALSE;
            }
            c->p++;
        } else {
            if (out) g_string_append_c(out, (char)ch);
            c->p++;
        }
    }
    return FALSE; // unterminated
}

static gboolean js_skip_value(JsCursor* c);

// Consumes "{...}" or "[...]" with the opening delimiter at the cursor.
static gboolean js_skip_container(JsCursor* c, char open, char close) {
    if (c->p >= c->end || *c->p != open) return FALSE;
    c->p++;
    js_skip_ws(c);
    if (c->p < c->end && *c->p == close) {
        c->p++;
        return TRUE;
    }
    while (c->p < c->end) {
        if (open == '{') {
            js_skip_ws(c);
            if (!js_parse_string(c, NULL)) return FALSE;
            js_skip_ws(c);
            if (c->p >= c->end || *c->p != ':') return FALSE;
            c->p++;
        }
        if (!js_skip_value(c)) return FALSE;
        js_skip_ws(c);
        if (c->p >= c->end) return FALSE;
        if (*c->p == ',') {
            c->p++;
            continue;
        }
        if (*c->p == close) {
            c->p++;
            return TRUE;
        }
        return FALSE;
    }
    return FALSE;
}

static gboolean js_skip_value(JsCursor* c) {
    js_skip_ws(c);
    if (c->p >= c->end) return FALSE;
    switch (*c->p) {
        case '"':
            return js_parse_string(c, NULL);
        case '{':
            return js_skip_container(c, '{', '}');
        case '[':
            return js_skip_container(c, '[', ']');
        default: {
            const char* start = c->p;
            while (c->p < c->end && *c->p != ',' && *c->p != '}' && *c->p != ']' && *c->p != ' ' && *c->p != '\t' &&
                   *c->p != '\n' && *c->p != '\r')
                c->p++;
            return c->p > start;
        }
    }
}

// Object member iteration: after js_enter_object, call js_next_member until
// it returns 0 (object closed) or -1 (malformed). On 1, *key is owned and the
// cursor sits at the member's value (consume it with one js_* call).
static gboolean js_enter_object(JsCursor* c) {
    js_skip_ws(c);
    if (c->p >= c->end || *c->p != '{') return FALSE;
    c->p++;
    return TRUE;
}

static int js_next_member(JsCursor* c, char** key) {
    GString* name;

    *key = NULL;
    js_skip_ws(c);
    if (c->p >= c->end) return -1;
    if (*c->p == '}') {
        c->p++;
        return 0;
    }
    if (*c->p == ',') {
        c->p++;
        js_skip_ws(c);
    }
    name = g_string_new("");
    if (!js_parse_string(c, name)) {
        g_string_free(name, TRUE);
        return -1;
    }
    js_skip_ws(c);
    if (c->p >= c->end || *c->p != ':') {
        g_string_free(name, TRUE);
        return -1;
    }
    c->p++;
    *key = g_string_free(name, FALSE);
    return 1;
}

static char* js_read_string_value(JsCursor* c) {
    GString* out = g_string_new("");
    js_skip_ws(c);
    if (!js_parse_string(c, out)) {
        g_string_free(out, TRUE);
        return NULL;
    }
    return g_string_free(out, FALSE);
}

static gboolean js_read_bool_value(JsCursor* c, gboolean* out) {
    js_skip_ws(c);
    if (c->end - c->p >= 4 && strncmp(c->p, "true", 4) == 0) {
        *out = TRUE;
        c->p += 4;
        return TRUE;
    }
    if (c->end - c->p >= 5 && strncmp(c->p, "false", 5) == 0) {
        *out = FALSE;
        c->p += 5;
        return TRUE;
    }
    return js_skip_value(c); // unexpected type: skip, keep default
}

static gboolean js_read_int_value(JsCursor* c, gint64* out) {
    char* end = NULL;
    gint64 value;

    js_skip_ws(c);
    value = g_ascii_strtoll(c->p, &end, 10);
    if (end && end > c->p && end <= c->end) {
        *out = value;
        c->p = end;
        // Consume any fraction/exponent tail so the scan stays aligned.
        while (c->p < c->end &&
               (*c->p == '.' || *c->p == 'e' || *c->p == 'E' || *c->p == '+' || *c->p == '-' || g_ascii_isdigit(*c->p)))
            c->p++;
        return TRUE;
    }
    return js_skip_value(c);
}

// One element of the "assets" array.
typedef struct {
    char* name;
    char* url;
    gint64 size;
} JsAsset;

static gboolean js_parse_asset(JsCursor* c, JsAsset* asset) {
    char* key;
    int r;

    memset(asset, 0, sizeof(*asset));
    if (!js_enter_object(c)) return FALSE;
    while ((r = js_next_member(c, &key)) > 0) {
        gboolean ok;
        if (strcmp(key, "name") == 0) {
            g_free(asset->name);
            asset->name = js_read_string_value(c);
            ok = asset->name != NULL;
        } else if (strcmp(key, "browser_download_url") == 0) {
            g_free(asset->url);
            asset->url = js_read_string_value(c);
            ok = asset->url != NULL;
        } else if (strcmp(key, "size") == 0) {
            ok = js_read_int_value(c, &asset->size);
        } else {
            ok = js_skip_value(c);
        }
        g_free(key);
        if (!ok) return FALSE;
    }
    return r == 0;
}

gboolean spdf_updater_parse_release(const char* json, gssize len, const char* asset_name, SpdfReleaseInfo* out) {
    JsCursor c;
    char* sig_name;
    char* key;
    int r = -1;
    gboolean ok = TRUE;

    if (out) memset(out, 0, sizeof(*out));
    if (!json || !asset_name || !out) return FALSE;
    c.p = json;
    c.end = json + (len < 0 ? (gssize)strlen(json) : len);
    sig_name = g_strconcat(asset_name, ".minisig", NULL);

    if (!js_enter_object(&c)) ok = FALSE;
    while (ok && (r = js_next_member(&c, &key)) > 0) {
        if (strcmp(key, "tag_name") == 0) {
            g_free(out->tag);
            out->tag = js_read_string_value(&c);
            ok = out->tag != NULL;
        } else if (strcmp(key, "draft") == 0) {
            ok = js_read_bool_value(&c, &out->draft);
        } else if (strcmp(key, "prerelease") == 0) {
            ok = js_read_bool_value(&c, &out->prerelease);
        } else if (strcmp(key, "body") == 0) {
            js_skip_ws(&c);
            if (c.p < c.end && *c.p == '"') {
                g_free(out->notes);
                out->notes = js_read_string_value(&c);
                ok = out->notes != NULL;
            } else {
                ok = js_skip_value(&c); // null body
            }
        } else if (strcmp(key, "assets") == 0) {
            js_skip_ws(&c);
            if (c.p < c.end && *c.p == '[') {
                c.p++;
                js_skip_ws(&c);
                if (c.p < c.end && *c.p == ']') {
                    c.p++;
                } else {
                    while (ok) {
                        JsAsset asset;
                        ok = js_parse_asset(&c, &asset);
                        if (ok && asset.name && asset.url) {
                            if (strcmp(asset.name, asset_name) == 0) {
                                g_free(out->asset_url);
                                out->asset_url = g_strdup(asset.url);
                                out->asset_size = asset.size;
                            } else if (strcmp(asset.name, sig_name) == 0) {
                                g_free(out->sig_url);
                                out->sig_url = g_strdup(asset.url);
                            }
                        }
                        g_free(asset.name);
                        g_free(asset.url);
                        if (!ok) break;
                        js_skip_ws(&c);
                        if (c.p < c.end && *c.p == ',') {
                            c.p++;
                            continue;
                        }
                        if (c.p < c.end && *c.p == ']') {
                            c.p++;
                            break;
                        }
                        ok = FALSE;
                    }
                }
            } else {
                ok = js_skip_value(&c);
            }
        } else {
            ok = js_skip_value(&c);
        }
        g_free(key);
    }
    g_free(sig_name);
    if (!ok || r != 0 || !out->tag || !*out->tag) {
        spdf_release_info_clear(out);
        return FALSE;
    }
    return TRUE;
}

void spdf_release_info_clear(SpdfReleaseInfo* info) {
    if (!info) return;
    g_free(info->tag);
    g_free(info->notes);
    g_free(info->asset_url);
    g_free(info->sig_url);
    memset(info, 0, sizeof(*info));
}

// ===========================================================================
// 4. Availability decision + release-notes formatting (pure)
// ===========================================================================

gboolean spdf_updater_release_available(const SpdfReleaseInfo* info, const char* running, const char* highest_seen) {
    if (!info || !info->tag || !*info->tag || !running || !*running) return FALSE;
    if (info->draft || info->prerelease) return FALSE;
    if (!info->asset_url || !*info->asset_url) return FALSE;
    if (!info->sig_url || !*info->sig_url) return FALSE; // unsigned release: never offer
    if (spdf_updater_compare_versions(info->tag, running) <= 0) return FALSE;
    // Downgrade/replay guard against the high-water mark.
    if (highest_seen && *highest_seen && spdf_updater_compare_versions(info->tag, highest_seen) < 0) return FALSE;
    return TRUE;
}

// Port of spdf_format_release_notes_for_alert (SPDFUpdater.mm): highlights
// above the first horizontal rule, markdown stripped, bullets to "• ",
// hard-wrapped continuations rejoined, control + bidi characters removed,
// capped at 500 characters on a line boundary.
char* spdf_updater_format_notes(const char* body) {
    char* normalized;
    char** raw_lines;
    GPtrArray* lines;
    GString* joined;
    GString* cleaned;
    char* text;
    glong chars;

    if (!body || !*body) return g_strdup("");

    {
        GString* norm = g_string_new("");
        for (const char* p = body; *p; ++p) {
            if (*p == '\r') {
                if (p[1] == '\n') continue; // \r\n -> \n (the \n follows)
                g_string_append_c(norm, '\n');
            } else {
                g_string_append_c(norm, *p);
            }
        }
        normalized = g_string_free(norm, FALSE);
    }

    lines = g_ptr_array_new_with_free_func(g_free);
    raw_lines = g_strsplit(normalized, "\n", -1);
    for (guint i = 0; raw_lines[i]; ++i) {
        const char* raw = raw_lines[i];
        char* line = g_strstrip(g_strdup(raw));
        gboolean is_bullet = FALSE;
        gboolean continuation;
        char* stripped;

        // Highlights section only: stop at the first horizontal rule.
        if (g_str_has_prefix(line, "---") || g_str_has_prefix(line, "***") || g_str_has_prefix(line, "___")) {
            g_free(line);
            break;
        }
        {
            char* s = line;
            while (*s == '#') s++;
            if (g_str_has_prefix(s, "> ")) s += 2;
            stripped = g_strstrip(g_strdup(s));
            g_free(line);
            line = stripped;
        }
        if (g_str_has_prefix(line, "- ") || g_str_has_prefix(line, "* ") || g_str_has_prefix(line, "+ ")) {
            char* bullet = g_strconcat("\xE2\x80\xA2 ", line + 2, NULL); // "• "
            g_free(line);
            line = bullet;
            is_bullet = TRUE;
        }
        {
            const char* markers[] = {"**", "`", "_"};
            for (guint m = 0; m < G_N_ELEMENTS(markers); ++m) {
                char** parts = g_strsplit(line, markers[m], -1);
                char* replaced = g_strjoinv("", parts);
                g_strfreev(parts);
                g_free(line);
                line = replaced;
            }
        }
        // Hard-wrapped continuation lines (indented in the raw body) rejoin
        // the previous line so the prompt wraps them naturally.
        continuation = !is_bullet && *line && g_str_has_prefix(raw, "  ") && lines->len > 0 &&
                       *(const char*)g_ptr_array_index(lines, lines->len - 1);
        if (continuation) {
            char* prev = g_ptr_array_index(lines, lines->len - 1);
            char* merged = g_strconcat(prev, " ", line, NULL);
            g_ptr_array_index(lines, lines->len - 1) = merged;
            g_free(prev);
            g_free(line);
        } else if (*line) {
            g_ptr_array_add(lines, line);
        } else {
            g_free(line); // blank lines add nothing in the compact prompt
        }
    }
    g_strfreev(raw_lines);
    g_free(normalized);

    joined = g_string_new("");
    for (guint i = 0; i < lines->len; ++i) {
        if (i) g_string_append_c(joined, '\n');
        g_string_append(joined, g_ptr_array_index(lines, i));
    }
    g_ptr_array_unref(lines);

    // Neutralize control + bidi override characters so a crafted body can't
    // reorder or hide the version/identity text in the prompt.
    cleaned = g_string_new("");
    for (const char* p = joined->str; *p; p = g_utf8_next_char(p)) {
        gunichar u = g_utf8_get_char_validated(p, -1);
        if (u == (gunichar)-1 || u == (gunichar)-2) break;
        if (u != '\n') {
            if (u < 0x20 || u == 0x7F) continue;
            if (u >= 0x202A && u <= 0x202E) continue; // embeddings/overrides
            if (u >= 0x2066 && u <= 0x2069) continue; // isolates
        }
        g_string_append_unichar(cleaned, u);
    }
    g_string_free(joined, TRUE);
    text = g_strstrip(g_string_free(cleaned, FALSE));

    chars = g_utf8_strlen(text, -1);
    if (chars > SPDF_UPDATER_NOTES_CHAR_CAP) {
        char* cap_at = g_utf8_offset_to_pointer(text, SPDF_UPDATER_NOTES_CHAR_CAP);
        char* cut = cap_at;
        char* trimmed;
        char* result;
        // Cut at the last complete line that fits, falling back to a hard cut.
        for (char* q = cap_at; q > text; --q) {
            if (*q == '\n') {
                cut = q;
                break;
            }
        }
        trimmed = g_strstrip(g_strndup(text, (gsize)(cut - text)));
        result = g_strconcat(trimmed, "\n\xE2\x80\xA6", NULL); // "\n…"
        g_free(trimmed);
        g_free(text);
        return result;
    }
    return text; // owned; g_strstrip returned the same buffer
}

// ===========================================================================
// 5. update.json store parse/serialize (pure)
// ===========================================================================

/* Mac writes the in-progress lease as a nested object:
 *   "updateInProgress": { "pid": 123, "timestamp": 1710000000.5 }
 * (SPDFUpdater.mm). Map it onto the flat leasePid/leaseTimestamp fields so a
 * Mac-written update.json can't make the Linux updater take an overlapping
 * lease. */
static gboolean store_parse_mac_lease(JsCursor* c, SpdfUpdateStore* out) {
    char* key;
    int r;

    if (!js_enter_object(c)) return js_skip_value(c);
    while ((r = js_next_member(c, &key)) > 0) {
        gboolean ok;
        if (strcmp(key, "pid") == 0)
            ok = js_read_int_value(c, &out->lease_pid);
        else if (strcmp(key, "timestamp") == 0)
            ok = js_read_int_value(c, &out->lease_ts);
        else
            ok = js_skip_value(c);
        g_free(key);
        if (!ok) return FALSE;
    }
    return r == 0;
}

void spdf_update_store_parse(const char* json, gssize len, SpdfUpdateStore* out) {
    JsCursor c;
    char* key;
    int r;

    if (!out) return;
    memset(out, 0, sizeof(*out));
    if (!json) return;
    c.p = json;
    c.end = json + (len < 0 ? (gssize)strlen(json) : len);
    if (!js_enter_object(&c)) return;
    while ((r = js_next_member(&c, &key)) > 0) {
        gboolean ok;
        if (strcmp(key, "lastUpdateCheck") == 0)
            ok = js_read_int_value(&c, &out->last_check);
        else if (strcmp(key, "remindAfter") == 0)
            ok = js_read_int_value(&c, &out->remind_after);
        else if (strcmp(key, "leasePid") == 0)
            ok = js_read_int_value(&c, &out->lease_pid);
        else if (strcmp(key, "leaseTimestamp") == 0)
            ok = js_read_int_value(&c, &out->lease_ts);
        else if (strcmp(key, "updateInProgress") == 0)
            ok = store_parse_mac_lease(&c, out);
        else if (strcmp(key, "etag") == 0)
            ok = (out->etag = js_read_string_value(&c)) != NULL;
        else if (strcmp(key, "highestVersionSeen") == 0)
            ok = (out->highest_seen = js_read_string_value(&c)) != NULL;
        else if (strcmp(key, "deferredTag") == 0)
            ok = (out->deferred_tag = js_read_string_value(&c)) != NULL;
        else if (strcmp(key, "pendingTag") == 0)
            ok = (out->pending_tag = js_read_string_value(&c)) != NULL;
        else if (strcmp(key, "updateOk") == 0 || strcmp(key, "update_ok") == 0) {
            // Mac spells the healthy-relaunch marker update_ok (snake_case).
            g_free(out->update_ok);
            ok = (out->update_ok = js_read_string_value(&c)) != NULL;
        } else
            ok = js_skip_value(&c);
        g_free(key);
        if (!ok) break;
    }
}

static void store_append_json_string(GString* out, const char* key, const char* value, gboolean* first) {
    if (!value || !*value) return;
    g_string_append_printf(out, "%s  \"%s\": \"", *first ? "" : ",\n", key);
    for (const unsigned char* p = (const unsigned char*)value; *p; ++p) {
        if (*p == '"' || *p == '\\') g_string_append_c(out, '\\');
        if (*p == '\n')
            g_string_append(out, "\\n");
        else if (*p == '\r')
            g_string_append(out, "\\r");
        else if (*p == '\t')
            g_string_append(out, "\\t");
        else if (*p < 0x20)
            g_string_append_printf(out, "\\u%04x", (unsigned int)*p);
        else
            g_string_append_c(out, (char)*p);
    }
    g_string_append_c(out, '"');
    *first = FALSE;
}

static void store_append_json_int(GString* out, const char* key, gint64 value, gboolean* first) {
    if (value == 0) return;
    g_string_append_printf(out, "%s  \"%s\": %" G_GINT64_FORMAT, *first ? "" : ",\n", key, value);
    *first = FALSE;
}

char* spdf_update_store_serialize(const SpdfUpdateStore* store) {
    GString* out = g_string_new("{\n");
    gboolean first = TRUE;

    if (store) {
        store_append_json_string(out, "deferredTag", store->deferred_tag, &first);
        store_append_json_string(out, "etag", store->etag, &first);
        store_append_json_string(out, "highestVersionSeen", store->highest_seen, &first);
        store_append_json_int(out, "lastUpdateCheck", store->last_check, &first);
        store_append_json_int(out, "leasePid", store->lease_pid, &first);
        store_append_json_int(out, "leaseTimestamp", store->lease_ts, &first);
        store_append_json_string(out, "pendingTag", store->pending_tag, &first);
        store_append_json_int(out, "remindAfter", store->remind_after, &first);
        store_append_json_string(out, "updateOk", store->update_ok, &first);
    }
    g_string_append(out, first ? "}" : "\n}");
    return g_string_free(out, FALSE);
}

void spdf_update_store_clear(SpdfUpdateStore* store) {
    if (!store) return;
    g_free(store->etag);
    g_free(store->highest_seen);
    g_free(store->deferred_tag);
    g_free(store->pending_tag);
    g_free(store->update_ok);
    memset(store, 0, sizeof(*store));
}

#ifndef SPDF_UPDATER_TESTING

// ===========================================================================
// 6. Paths, flock'd store access, liveness lease
// ===========================================================================

static const char* updater_running_version(void) {
    return SPDF_APP_VERSION "-" SPDF_APP_BUILD;
}

static char* updater_config_dir(void) {
    char* dir = g_build_filename(g_get_user_config_dir(), "shenzhenpdf", NULL);
    g_mkdir_with_parents(dir, 0700);
    return dir;
}

static char* updater_cache_dir(void) {
    char* dir = g_build_filename(g_get_user_cache_dir(), "shenzhenpdf", "updates", NULL);
    g_mkdir_with_parents(dir, 0700);
    return dir;
}

// flock'd read-modify-write of update.json (mirrors withLockedUpdateStore:).
// The mutator returns TRUE to persist its changes.
typedef gboolean (*SpdfStoreMutator)(SpdfUpdateStore* store, gpointer user_data);

static void with_locked_update_store(SpdfStoreMutator mutator, gpointer user_data) {
    char* config_dir = updater_config_dir();
    char* lock_path = g_build_filename(config_dir, "update.lock", NULL);
    char* json_path = g_build_filename(config_dir, "update.json", NULL);
    int fd = open(lock_path, O_CREAT | O_RDWR, 0600);
    char* contents = NULL;
    gsize len = 0;
    SpdfUpdateStore store;

    if (fd >= 0) flock(fd, LOCK_EX);
    g_file_get_contents(json_path, &contents, &len, NULL);
    spdf_update_store_parse(contents, (gssize)len, &store);
    g_free(contents);
    if (mutator(&store, user_data)) {
        char* serialized = spdf_update_store_serialize(&store);
        g_file_set_contents(json_path, serialized, -1, NULL);
        g_free(serialized);
    }
    spdf_update_store_clear(&store);
    if (fd >= 0) {
        flock(fd, LOCK_UN);
        close(fd);
    }
    g_free(json_path);
    g_free(lock_path);
    g_free(config_dir);
}

// --- 24h gate: claim today's slot, stamped BEFORE the network call so a
//     crash/network failure still burns the day (no hammering).
static gboolean mutator_claim_daily_slot(SpdfUpdateStore* store, gpointer user_data) {
    gboolean* claimed = user_data;
    gint64 now = g_get_real_time() / G_USEC_PER_SEC;

    if (spdf_updater_daily_check_delay(TRUE, store->last_check != 0, store->last_check, now) != 0) return FALSE;
    store->last_check = now;
    *claimed = TRUE;
    return TRUE;
}

// --- single-driver liveness lease (guards the install window, including a
//     CLI --install-update racing the running app).
static gboolean mutator_acquire_lease(SpdfUpdateStore* store, gpointer user_data) {
    gboolean* acquired = user_data;
    gint64 now = g_get_real_time() / G_USEC_PER_SEC;

    if (store->lease_pid > 0 && store->lease_pid != (gint64)getpid() && kill((pid_t)store->lease_pid, 0) == 0 &&
        (now - store->lease_ts) < SPDF_UPDATER_LEASE_STALE_SECONDS)
        return FALSE; // genuinely held by a live, recent driver
    store->lease_pid = getpid();
    store->lease_ts = now;
    *acquired = TRUE;
    return TRUE;
}

static gboolean mutator_release_lease(SpdfUpdateStore* store, gpointer user_data) {
    (void)user_data;
    if (store->lease_pid == 0) return FALSE;
    store->lease_pid = 0;
    store->lease_ts = 0;
    return TRUE;
}

// ===========================================================================
// 7. Transport: GSubprocess curl (preferred) / wget fallback
// ===========================================================================

static char* updater_user_agent(void) {
    return g_strdup_printf("ShenzhenPDF/%s (GTK4 Linux; +https://github.com/casimir-engineering/shenzhen-pdf)",
                           updater_running_version());
}

// Returns the fetcher path, setting *is_curl. NULL when neither tool exists
// (the caller disables the updater with a logged reason).
static char* updater_find_fetcher(gboolean* is_curl) {
    char* tool = g_find_program_in_path("curl");
    if (tool) {
        *is_curl = TRUE;
        return tool;
    }
    tool = g_find_program_in_path("wget");
    *is_curl = FALSE;
    return tool;
}

// Parse the LAST "HTTP/..." status line (redirect chains emit several blocks)
// and the last ETag header from a header dump (curl -D file, or wget
// --server-response stderr where lines are indented).
static void updater_parse_headers(const char* text, int* status_out, char** etag_out) {
    char** lines = g_strsplit(text ? text : "", "\n", -1);

    *status_out = -1;
    *etag_out = NULL;
    for (guint i = 0; lines[i]; ++i) {
        char* line = g_strstrip(lines[i]);
        if (g_ascii_strncasecmp(line, "HTTP/", 5) == 0) {
            const char* sp = strchr(line, ' ');
            if (sp) *status_out = atoi(sp + 1);
        } else if (g_ascii_strncasecmp(line, "etag:", 5) == 0) {
            g_free(*etag_out);
            *etag_out = g_strdup(g_strstrip(line + 5));
        }
    }
    g_strfreev(lines);
}

static void updater_cancel_kill_subprocess(GCancellable* cancellable, gpointer user_data) {
    (void)cancellable;
    g_subprocess_force_exit(G_SUBPROCESS(user_data));
}

// Fetch `url` into `dest_path`. https-only (enforced by the tool on every
// redirect hop), bounded redirects, bounded time, size cap re-checked on the
// resulting file. Returns TRUE when an HTTP status was obtained (the caller
// interprets it); FALSE with *error_out on transport/tool failure.
static gboolean updater_fetch(const char* url, const char* dest_path, const char* etag_in, gboolean api_request,
                              gint64 max_bytes, guint timeout_secs, GCancellable* cancellable, int* status_out,
                              char** etag_out, char** error_out) {
    gboolean is_curl = FALSE;
    char* tool = updater_find_fetcher(&is_curl);
    char* headers_path = g_strconcat(dest_path, ".headers", NULL);
    char* ua = updater_user_agent();
    GPtrArray* argv = g_ptr_array_new_with_free_func(g_free);
    GSubprocessLauncher* launcher;
    GSubprocess* proc;
    GError* gerr = NULL;
    char* headers = NULL;
    gulong cancel_id = 0;
    gboolean ok = FALSE;

    *status_out = -1;
    if (etag_out) *etag_out = NULL;
    if (!tool) {
        set_error(error_out, "neither curl nor wget was found in PATH; automatic updates are unavailable");
        goto out;
    }
    if (!g_str_has_prefix(url, "https://")) {
        set_error(error_out, "the update URL was not https");
        goto out;
    }

    g_ptr_array_add(argv, g_strdup(tool));
    if (is_curl) {
        g_ptr_array_add(argv, g_strdup("--silent"));
        g_ptr_array_add(argv, g_strdup("--location"));
        g_ptr_array_add(argv, g_strdup("--proto"));
        g_ptr_array_add(argv, g_strdup("=https"));
        g_ptr_array_add(argv, g_strdup("--proto-redir"));
        g_ptr_array_add(argv, g_strdup("=https"));
        g_ptr_array_add(argv, g_strdup("--max-redirs"));
        g_ptr_array_add(argv, g_strdup("5"));
        g_ptr_array_add(argv, g_strdup("--max-time"));
        g_ptr_array_add(argv, g_strdup_printf("%u", timeout_secs));
        g_ptr_array_add(argv, g_strdup("--max-filesize"));
        g_ptr_array_add(argv, g_strdup_printf("%" G_GINT64_FORMAT, max_bytes));
        g_ptr_array_add(argv, g_strdup("-A"));
        g_ptr_array_add(argv, g_strdup(ua));
        g_ptr_array_add(argv, g_strdup("-o"));
        g_ptr_array_add(argv, g_strdup(dest_path));
        g_ptr_array_add(argv, g_strdup("-D"));
        g_ptr_array_add(argv, g_strdup(headers_path));
        if (api_request) {
            g_ptr_array_add(argv, g_strdup("-H"));
            g_ptr_array_add(argv, g_strdup("Accept: application/vnd.github+json"));
            g_ptr_array_add(argv, g_strdup("-H"));
            g_ptr_array_add(argv, g_strdup("X-GitHub-Api-Version: 2022-11-28"));
        }
        if (etag_in && *etag_in) {
            g_ptr_array_add(argv, g_strdup("-H"));
            g_ptr_array_add(argv, g_strdup_printf("If-None-Match: %s", etag_in));
        }
    } else {
        // NOT --quiet: it would suppress the --server-response header dump.
        g_ptr_array_add(argv, g_strdup("--no-verbose"));
        g_ptr_array_add(argv, g_strdup("--server-response"));
        g_ptr_array_add(argv, g_strdup("--https-only"));
        g_ptr_array_add(argv, g_strdup("--max-redirect=5"));
        g_ptr_array_add(argv, g_strdup_printf("--timeout=%u", timeout_secs));
        g_ptr_array_add(argv, g_strdup("--tries=1"));
        g_ptr_array_add(argv, g_strdup("-U"));
        g_ptr_array_add(argv, g_strdup(ua));
        if (api_request) {
            g_ptr_array_add(argv, g_strdup("--header=Accept: application/vnd.github+json"));
            g_ptr_array_add(argv, g_strdup("--header=X-GitHub-Api-Version: 2022-11-28"));
        }
        if (etag_in && *etag_in) g_ptr_array_add(argv, g_strdup_printf("--header=If-None-Match: %s", etag_in));
        g_ptr_array_add(argv, g_strdup("-O"));
        g_ptr_array_add(argv, g_strdup(dest_path));
    }
    g_ptr_array_add(argv, g_strdup(url));
    g_ptr_array_add(argv, NULL);

    launcher = g_subprocess_launcher_new(G_SUBPROCESS_FLAGS_STDOUT_SILENCE |
                                         (is_curl ? G_SUBPROCESS_FLAGS_STDERR_SILENCE : G_SUBPROCESS_FLAGS_NONE));
    // wget prints its --server-response header dump on stderr; curl writes
    // headers via -D and gets its stderr dropped (the exit code + parsed
    // status carry the outcome).
    if (!is_curl) g_subprocess_launcher_set_stderr_file_path(launcher, headers_path);
    proc = g_subprocess_launcher_spawnv(launcher, (const char* const*)argv->pdata, &gerr);
    g_object_unref(launcher);
    if (!proc) {
        set_error(error_out, gerr ? gerr->message : "could not start the download tool");
        g_clear_error(&gerr);
        goto out;
    }
    if (cancellable)
        cancel_id = g_cancellable_connect(cancellable, G_CALLBACK(updater_cancel_kill_subprocess), g_object_ref(proc),
                                          g_object_unref);
    g_subprocess_wait(proc, NULL, NULL);
    if (cancellable && cancel_id) g_cancellable_disconnect(cancellable, cancel_id);
    if (cancellable && g_cancellable_is_cancelled(cancellable)) {
        set_error(error_out, "cancelled");
        g_object_unref(proc);
        goto out;
    }

    if (g_file_get_contents(headers_path, &headers, NULL, NULL)) updater_parse_headers(headers, status_out, etag_out);
    g_free(headers);

    if (*status_out < 100) {
        // No HTTP status at all: transport-level failure (offline, DNS, TLS).
        set_error(error_out, g_subprocess_get_if_exited(proc) ? "could not reach the update server"
                                                              : "the download tool was interrupted");
        g_object_unref(proc);
        goto out;
    }
    g_object_unref(proc);

    // Belt-and-braces size cap (curl --max-filesize can miss chunked bodies;
    // wget has no cap at all).
    {
        GStatBuf st;
        if (g_stat(dest_path, &st) == 0 && (gint64)st.st_size > max_bytes) {
            set_error(error_out, "the downloaded file exceeded the size limit");
            g_unlink(dest_path);
            goto out;
        }
    }
    ok = TRUE;

out:
    g_unlink(headers_path);
    g_ptr_array_unref(argv);
    g_free(ua);
    g_free(headers_path);
    g_free(tool);
    return ok;
}

// ===========================================================================
// 8. Check pipeline
// ===========================================================================

// Install mode: a binary under $HOME is a user-local (tarball) install that
// we can atomically swap; anything else (deb under /usr, /opt) needs pkexec.
static char* updater_self_exe(void) {
    return g_file_read_link("/proc/self/exe", NULL);
}

static gboolean updater_is_user_local(void) {
    char* exe = updater_self_exe();
    gboolean user_local = exe && g_str_has_prefix(exe, g_get_home_dir());
    g_free(exe);
    return user_local;
}

static const char* updater_asset_name(void) {
    return updater_is_user_local() ? SPDF_UPDATER_TAR_ASSET : SPDF_UPDATER_DEB_ASSET;
}

// A system install can only be auto-updated where dpkg exists (the system
// asset is a .deb). On foreign-package installs (the rpm from build-rpm.sh,
// or anything else that lands the binary outside $HOME without dpkg) the
// updater still announces new releases but must not offer to install —
// updates come from the distribution/package manager (pkg/README.md).
static gboolean updater_can_install(void) {
    char* dpkg;
    gboolean ok;

    if (updater_is_user_local()) return TRUE;
    dpkg = g_find_program_in_path("dpkg");
    ok = dpkg != NULL;
    g_free(dpkg);
    return ok;
}

typedef struct {
    gboolean ok;           // an HTTP outcome was obtained and parsed
    gboolean not_modified; // 304
    gboolean available;
    gboolean newer_but_missing_asset; // newer tag exists, no Linux asset/sig
    SpdfReleaseInfo release;
    char* error;
} SpdfCheckOutcome;

static void check_outcome_clear(SpdfCheckOutcome* outcome) {
    spdf_release_info_clear(&outcome->release);
    g_free(outcome->error);
    memset(outcome, 0, sizeof(*outcome));
}

typedef struct {
    char* etag;
    char* highest_seen;
    char* deferred_tag;
    gint64 remind_after;
} StoreSnapshot;

static gboolean mutator_read_snapshot(SpdfUpdateStore* store, gpointer user_data) {
    StoreSnapshot* snap = user_data;
    snap->etag = g_strdup(store->etag);
    snap->highest_seen = g_strdup(store->highest_seen);
    snap->deferred_tag = g_strdup(store->deferred_tag);
    snap->remind_after = store->remind_after;
    return FALSE;
}

typedef struct {
    const char* etag;
    const char* tag;
} PersistCheckArgs;

static gboolean mutator_persist_check(SpdfUpdateStore* store, gpointer user_data) {
    PersistCheckArgs* args = user_data;
    gboolean changed = FALSE;

    if (args->etag && *args->etag && g_strcmp0(store->etag, args->etag) != 0) {
        g_free(store->etag);
        store->etag = g_strdup(args->etag);
        changed = TRUE;
    }
    // Advance the downgrade/replay high-water mark on every 200, independent
    // of the user's Skip/Later choice. An absent mark is always overtaken
    // (compare_versions treats empty input as "no ordering decision").
    if (args->tag && *args->tag &&
        (!store->highest_seen || !*store->highest_seen ||
         spdf_updater_compare_versions(args->tag, store->highest_seen) > 0)) {
        g_free(store->highest_seen);
        store->highest_seen = g_strdup(args->tag);
        changed = TRUE;
    }
    return changed;
}

// Blocking; run on a worker thread (or the CLI). The manual path omits the
// ETag so the server always returns a fresh 200 and the full decision logic
// runs; the silent daily path sends it so a 304 short-circuits.
static void updater_check_sync(gboolean user_initiated, SpdfCheckOutcome* outcome) {
    char* cache_dir = updater_cache_dir();
    char* body_path = g_build_filename(cache_dir, "release.json", NULL);
    StoreSnapshot snap = {0};
    int status = -1;
    char* new_etag = NULL;
    char* body = NULL;
    gsize body_len = 0;

    memset(outcome, 0, sizeof(*outcome));
    with_locked_update_store(mutator_read_snapshot, &snap);

    if (!updater_fetch(SPDF_UPDATER_RELEASES_LATEST_URL, body_path, user_initiated ? NULL : snap.etag, TRUE,
                       (gint64)8 * 1024 * 1024, SPDF_UPDATER_NET_TIMEOUT_SECONDS, NULL, &status, &new_etag,
                       &outcome->error))
        goto out;

    if (status == 304) {
        outcome->ok = TRUE;
        outcome->not_modified = TRUE;
        goto out;
    }
    if (status != 200) {
        outcome->error = g_strdup_printf("the update server returned HTTP %d", status);
        goto out;
    }
    if (!g_file_get_contents(body_path, &body, &body_len, NULL) ||
        !spdf_updater_parse_release(body, (gssize)body_len, updater_asset_name(), &outcome->release)) {
        set_error(&outcome->error, "the update server response was malformed");
        goto out;
    }

    {
        PersistCheckArgs args = {new_etag, outcome->release.tag};
        with_locked_update_store(mutator_persist_check, &args);
    }

    outcome->ok = TRUE;
    outcome->available =
        spdf_updater_release_available(&outcome->release, updater_running_version(), snap.highest_seen);
    outcome->newer_but_missing_asset =
        !outcome->available && !outcome->release.draft && !outcome->release.prerelease &&
        spdf_updater_compare_versions(outcome->release.tag, updater_running_version()) > 0 &&
        (!outcome->release.asset_url || !outcome->release.sig_url);

out:
    g_unlink(body_path);
    g_free(body);
    g_free(new_etag);
    g_free(snap.etag);
    g_free(snap.highest_seen);
    g_free(snap.deferred_tag);
    g_free(body_path);
    g_free(cache_dir);
}

// ===========================================================================
// Updater singleton (app mode)
// ===========================================================================

static struct {
    SpdfApp* app; // owned ref taken in spdf_updater_start
    guint first_check_id;
    guint cadence_id;
    gboolean check_running; // in-process driver flags (main thread)
    gboolean install_running;
    GCancellable* cancellable; // cancels the in-flight download

    GtkWindow* progress_window;
    GtkProgressBar* progress_bar;
    GtkLabel* progress_label;
    guint progress_timer;
    char* progress_path; // file whose size drives the bar
    gint64 progress_total;
} g_updater;

static GtkWindow* updater_active_window(void) {
    if (!g_updater.app) return NULL;
    return gtk_application_get_active_window(GTK_APPLICATION(g_updater.app));
}

static void updater_show_message(GtkWindow* parent, const char* message, const char* detail) {
    GtkAlertDialog* alert = gtk_alert_dialog_new("%s", message);
    if (detail && *detail) gtk_alert_dialog_set_detail(alert, detail);
    gtk_alert_dialog_show(alert, parent ? parent : updater_active_window());
    g_object_unref(alert);
}

// ----- progress window ------------------------------------------------------

static gboolean progress_timer_tick(gpointer user_data) {
    GStatBuf st;
    (void)user_data;
    if (!g_updater.progress_window || !g_updater.progress_path) return G_SOURCE_CONTINUE;
    if (g_stat(g_updater.progress_path, &st) == 0 && g_updater.progress_total > 0) {
        double written = (double)st.st_size;
        double total = (double)g_updater.progress_total;
        char text[64];
        gtk_progress_bar_set_fraction(g_updater.progress_bar, CLAMP(written / total, 0.0, 1.0));
        g_snprintf(text, sizeof(text), "%.1f MB of %.1f MB", written / (1024.0 * 1024.0), total / (1024.0 * 1024.0));
        gtk_label_set_text(g_updater.progress_label, text);
    } else {
        gtk_progress_bar_pulse(g_updater.progress_bar);
    }
    return G_SOURCE_CONTINUE;
}

static void progress_cancel_clicked(GtkButton* button, gpointer user_data) {
    (void)button;
    (void)user_data;
    if (g_updater.cancellable) g_cancellable_cancel(g_updater.cancellable);
}

static void updater_show_progress(const char* tag) {
    GtkWidget* box;
    GtkWidget* title;
    GtkWidget* cancel;
    char* title_text;

    if (g_updater.progress_window) return;
    g_updater.progress_window = GTK_WINDOW(gtk_window_new());
    gtk_window_set_title(g_updater.progress_window, "Software Update");
    gtk_window_set_resizable(g_updater.progress_window, FALSE);
    gtk_window_set_default_size(g_updater.progress_window, 420, -1);
    if (updater_active_window()) gtk_window_set_transient_for(g_updater.progress_window, updater_active_window());

    box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
    gtk_widget_set_margin_top(box, 16);
    gtk_widget_set_margin_bottom(box, 16);
    gtk_widget_set_margin_start(box, 18);
    gtk_widget_set_margin_end(box, 18);

    title_text = g_strdup_printf("Downloading Shenzhen PDF %s", tag ? tag : "");
    title = gtk_label_new(title_text);
    g_free(title_text);
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    gtk_widget_add_css_class(title, "heading");
    gtk_box_append(GTK_BOX(box), title);

    g_updater.progress_bar = GTK_PROGRESS_BAR(gtk_progress_bar_new());
    gtk_box_append(GTK_BOX(box), GTK_WIDGET(g_updater.progress_bar));

    g_updater.progress_label = GTK_LABEL(gtk_label_new("Starting…"));
    gtk_widget_set_halign(GTK_WIDGET(g_updater.progress_label), GTK_ALIGN_START);
    gtk_widget_add_css_class(GTK_WIDGET(g_updater.progress_label), "dim-label");
    gtk_box_append(GTK_BOX(box), GTK_WIDGET(g_updater.progress_label));

    cancel = gtk_button_new_with_label("Cancel");
    gtk_widget_set_halign(cancel, GTK_ALIGN_END);
    g_signal_connect(cancel, "clicked", G_CALLBACK(progress_cancel_clicked), NULL);
    gtk_box_append(GTK_BOX(box), cancel);

    gtk_window_set_child(g_updater.progress_window, box);
    gtk_window_present(g_updater.progress_window);
    g_updater.progress_timer = g_timeout_add(200, progress_timer_tick, NULL);
}

static void updater_dismiss_progress(void) {
    if (g_updater.progress_timer) {
        g_source_remove(g_updater.progress_timer);
        g_updater.progress_timer = 0;
    }
    if (g_updater.progress_window) {
        gtk_window_destroy(g_updater.progress_window);
        g_updater.progress_window = NULL;
        g_updater.progress_bar = NULL;
        g_updater.progress_label = NULL;
    }
    g_clear_pointer(&g_updater.progress_path, g_free);
    g_updater.progress_total = 0;
}

// ===========================================================================
// 9. Install: download + verify + (pkexec dpkg -i | atomic swap)
// ===========================================================================

// Spawn argv, wait for exit. timeout_secs == 0 blocks indefinitely (pkexec
// legitimately waits on the polkit auth dialog); otherwise the child is
// SIGKILLed after the bound (never hang the updater on a wedged child).
static gboolean updater_run_tool_sync(const char* const* argv, guint timeout_secs, int* exit_out) {
    GPid pid = 0;
    int wstatus = 0;
    gint64 waited_ms = 0;

    if (exit_out) *exit_out = -1;
    if (!g_spawn_async(
            NULL, (char**)argv, NULL,
            G_SPAWN_SEARCH_PATH | G_SPAWN_DO_NOT_REAP_CHILD | G_SPAWN_STDOUT_TO_DEV_NULL | G_SPAWN_STDERR_TO_DEV_NULL,
            NULL, NULL, &pid, NULL))
        return FALSE;
    for (;;) {
        pid_t r = waitpid(pid, &wstatus, timeout_secs ? WNOHANG : 0);
        if (r == pid) break;
        if (r < 0) {
            g_spawn_close_pid(pid);
            return FALSE;
        }
        if (timeout_secs && waited_ms >= (gint64)timeout_secs * 1000) {
            kill(pid, SIGKILL);
            waitpid(pid, &wstatus, 0);
            g_spawn_close_pid(pid);
            return FALSE;
        }
        g_usleep(100 * 1000);
        waited_ms += 100;
    }
    g_spawn_close_pid(pid);
    if (!WIFEXITED(wstatus)) return FALSE;
    if (exit_out) *exit_out = WEXITSTATUS(wstatus);
    return TRUE;
}

// Post-install/pre-relaunch launch health probe: the target binary must start
// and exit 0 with --updater-health-probe (proves it loads, links and runs its
// CLI path) within a bounded window.
static gboolean updater_health_probe(const char* exe_path) {
    const char* argv[] = {exe_path, "--updater-health-probe", NULL};
    int exit_status = -1;
    if (!updater_run_tool_sync(argv, SPDF_UPDATER_HEALTH_PROBE_TIMEOUT_SECONDS, &exit_status)) return FALSE;
    return exit_status == 0;
}

static void updater_delete_tree(const char* path) {
    GDir* dir = g_dir_open(path, 0, NULL);
    const char* name;

    if (dir) {
        while ((name = g_dir_read_name(dir)) != NULL) {
            char* child = g_build_filename(path, name, NULL);
            if (g_file_test(child, G_FILE_TEST_IS_DIR) && !g_file_test(child, G_FILE_TEST_IS_SYMLINK))
                updater_delete_tree(child);
            else
                g_unlink(child);
            g_free(child);
        }
        g_dir_close(dir);
    }
    g_rmdir(path);
}

// Keep the newest two per-tag cache dirs (current download + one previous
// artifact for manual rollback); delete the rest.
static void updater_prune_cache(void) {
    char* cache_dir = updater_cache_dir();
    GDir* dir = g_dir_open(cache_dir, 0, NULL);
    const char* name;
    GArray* entries = g_array_new(FALSE, FALSE, sizeof(gpointer));

    if (dir) {
        while ((name = g_dir_read_name(dir)) != NULL) {
            char* child = g_build_filename(cache_dir, name, NULL);
            if (g_file_test(child, G_FILE_TEST_IS_DIR))
                g_array_append_val(entries, child);
            else {
                g_unlink(child); // stray files (release.json leftovers)
                g_free(child);
            }
        }
        g_dir_close(dir);
    }
    // Sort by mtime descending; delete everything past the first two.
    for (guint i = 0; i < entries->len; ++i) {
        for (guint j = i + 1; j < entries->len; ++j) {
            GStatBuf si, sj;
            const char* pi = g_array_index(entries, gpointer, i);
            const char* pj = g_array_index(entries, gpointer, j);
            if (g_stat(pi, &si) == 0 && g_stat(pj, &sj) == 0 && sj.st_mtime > si.st_mtime) {
                gpointer tmp = g_array_index(entries, gpointer, i);
                g_array_index(entries, gpointer, i) = g_array_index(entries, gpointer, j);
                g_array_index(entries, gpointer, j) = tmp;
            }
        }
    }
    for (guint i = 0; i < entries->len; ++i) {
        char* path = g_array_index(entries, gpointer, i);
        if (i >= 2) updater_delete_tree(path);
        g_free(path);
    }
    g_array_unref(entries);
    g_free(cache_dir);
}

// Recursive search for the app binary inside the extracted tarball tree.
static char* updater_find_extracted_binary(const char* root) {
    GDir* dir = g_dir_open(root, 0, NULL);
    const char* name;
    char* found = NULL;

    if (!dir) return NULL;
    while (!found && (name = g_dir_read_name(dir)) != NULL) {
        char* child = g_build_filename(root, name, NULL);
        if (!g_file_test(child, G_FILE_TEST_IS_SYMLINK) && g_file_test(child, G_FILE_TEST_IS_DIR)) {
            found = updater_find_extracted_binary(child);
            g_free(child);
        } else if (strcmp(name, "ShenzhenPDF-gtk4") == 0 && g_file_test(child, G_FILE_TEST_IS_REGULAR)) {
            found = child; // ownership transferred
        } else {
            g_free(child);
        }
    }
    g_dir_close(dir);
    return found;
}

// Download the asset + its .minisig into cache/<tag>/ and verify against the
// pinned pubkey. THE trust gate: returns the verified asset path or NULL.
static char* updater_download_and_verify(const SpdfReleaseInfo* rel, GCancellable* cancellable, char** error_out) {
    char* cache_dir = updater_cache_dir();
    char* tag_dir = g_build_filename(cache_dir, rel->tag, NULL);
    const char* asset_name = updater_asset_name();
    char* asset_path = g_build_filename(tag_dir, asset_name, NULL);
    char* sig_path = g_strconcat(asset_path, ".minisig", NULL);
    char* sig_text = NULL;
    SpdfMinisignKey key;
    int status = -1;
    char* result = NULL;

    g_mkdir_with_parents(tag_dir, 0700);

    if (!spdf_minisign_parse_pubkey(k_spdf_pinned_pubkey, &key, error_out)) goto out;

    if (!updater_fetch(rel->sig_url, sig_path, NULL, FALSE, SPDF_UPDATER_MAX_SIG_BYTES,
                       SPDF_UPDATER_NET_TIMEOUT_SECONDS, cancellable, &status, NULL, error_out))
        goto out;
    if (status != 200) {
        set_error(error_out, "the update signature could not be downloaded");
        goto out;
    }

    if (!updater_fetch(rel->asset_url, asset_path, NULL, FALSE, SPDF_UPDATER_MAX_ASSET_BYTES,
                       SPDF_UPDATER_ASSET_TIMEOUT_SECONDS, cancellable, &status, NULL, error_out))
        goto out;
    if (status != 200) {
        set_error(error_out, "the update could not be downloaded");
        goto out;
    }

    // Content-integrity heuristic only (size from the same channel as the
    // download): catches truncation, never tampering. Trust is minisign only.
    if (rel->asset_size > 0) {
        GStatBuf st;
        if (g_stat(asset_path, &st) != 0 || (gint64)st.st_size != rel->asset_size) {
            set_error(error_out, "the downloaded update was incomplete");
            goto out;
        }
    }

    if (!g_file_get_contents(sig_path, &sig_text, NULL, NULL)) {
        set_error(error_out, "the update signature could not be read");
        goto out;
    }
    if (!spdf_minisign_verify_file(&key, sig_text, asset_path, error_out)) {
        char* detail = *error_out;
        *error_out = g_strdup_printf("The update could not be verified and was not installed (%s).",
                                     detail ? detail : "signature mismatch");
        g_free(detail);
        g_unlink(asset_path); // never leave an unverified artifact around
        g_unlink(sig_path);
        goto out;
    }

    result = g_strdup(asset_path);

out:
    if (!result) {
        g_unlink(sig_path);
        g_unlink(asset_path); // never keep a partial or unverified artifact
    }
    g_free(sig_text);
    g_free(sig_path);
    g_free(asset_path);
    g_free(tag_dir);
    g_free(cache_dir);
    return result;
}

// --- user-local (tarball) install: Mac-style atomic swap ---------------------
// rename(exe -> exe.old), rename(staged -> exe); restore .old on any failure;
// health-probe the swapped binary and roll back if it cannot launch.
static gboolean updater_install_user_local(const char* asset_path, char** error_out) {
    char* exe = updater_self_exe();
    char* exe_dir = exe ? g_path_get_dirname(exe) : NULL;
    char* staging = NULL;
    char* extracted = NULL;
    char* staged_new = NULL;
    char* old_path = NULL;
    gboolean moved_aside = FALSE;
    gboolean ok = FALSE;

    if (!exe || !exe_dir) {
        set_error(error_out, "could not resolve the running binary path");
        goto out;
    }

    {
        char* cache_dir = updater_cache_dir();
        staging = g_build_filename(cache_dir, "extract-XXXXXX", NULL);
        g_free(cache_dir);
    }
    if (!g_mkdtemp(staging)) {
        set_error(error_out, "could not create an extraction directory");
        goto out;
    }
    g_chmod(staging, 0700);

    {
        const char* argv[] = {"tar", "-xzf", asset_path, "-C", staging, NULL};
        int exit_status = -1;
        if (!updater_run_tool_sync(argv, 120, &exit_status) || exit_status != 0) {
            set_error(error_out, "the update archive could not be extracted");
            goto out;
        }
    }

    extracted = updater_find_extracted_binary(staging);
    if (!extracted) {
        set_error(error_out, "the update archive did not contain the ShenzhenPDF-gtk4 binary");
        goto out;
    }

    // Stage next to the target so the final rename is atomic (same volume).
    staged_new = g_strconcat(exe, ".new", NULL);
    g_unlink(staged_new);
    {
        GFile* src = g_file_new_for_path(extracted);
        GFile* dst = g_file_new_for_path(staged_new);
        GError* gerr = NULL;
        gboolean copied = g_file_copy(src, dst, G_FILE_COPY_OVERWRITE, NULL, NULL, NULL, &gerr);
        g_object_unref(src);
        g_object_unref(dst);
        if (!copied) {
            set_error(error_out, gerr ? gerr->message : "could not stage the new binary");
            g_clear_error(&gerr);
            goto out;
        }
    }
    g_chmod(staged_new, 0755);

    old_path = g_strconcat(exe, ".old", NULL);
    g_unlink(old_path); // sweep a stale move-aside
    if (rename(exe, old_path) != 0) {
        set_error(error_out, "the installed binary is not writable");
        goto out;
    }
    moved_aside = TRUE;
    if (rename(staged_new, exe) != 0) {
        rename(old_path, exe); // rollback: restore the working install
        moved_aside = FALSE;
        set_error(error_out, "the new binary could not be moved into place");
        goto out;
    }

    // Health probe the binary now sitting at the final path; roll back the
    // swap if the new build cannot even start.
    if (!updater_health_probe(exe)) {
        char* failed = g_strconcat(exe, ".failed", NULL);
        g_unlink(failed);
        rename(exe, failed);
        rename(old_path, exe);
        g_free(failed);
        moved_aside = FALSE;
        set_error(error_out, "the updated binary failed its launch check; the previous version was restored");
        goto out;
    }
    // .old is retained until the relaunched process confirms the pending tag
    // (launch health check), mirroring the Mac .old lifecycle.
    ok = TRUE;

out:
    (void)moved_aside;
    if (staging) updater_delete_tree(staging);
    g_free(staged_new);
    g_free(old_path);
    g_free(extracted);
    g_free(staging);
    g_free(exe_dir);
    g_free(exe);
    return ok;
}

// --- system (deb) install: pkexec dpkg -i ------------------------------------
static gboolean updater_install_deb(const char* deb_path, char** error_out) {
    char* pkexec = g_find_program_in_path("pkexec");
    char* dpkg = g_find_program_in_path("dpkg");
    char* exe = updater_self_exe();
    gboolean ok = FALSE;
    int exit_status = -1;

    if (!dpkg) {
        // Non-dpkg system (e.g. the rpm install on Fedora): the system asset
        // is a .deb, so there is nothing we could meaningfully install.
        set_error(error_out,
                  "this system does not use dpkg, so the update cannot be installed "
                  "automatically; update Shenzhen PDF through your package manager");
        goto out;
    }
    if (!pkexec) {
        char* msg =
            g_strdup_printf("pkexec is not available. Install the update manually:\n  sudo dpkg -i %s", deb_path);
        set_error(error_out, msg);
        g_free(msg);
        goto out;
    }
    {
        const char* argv[] = {pkexec, dpkg, "-i", deb_path, NULL};
        // No timeout: the polkit auth dialog legitimately waits on the user.
        if (!updater_run_tool_sync(argv, 0, &exit_status)) {
            set_error(error_out, "the package installer could not be started");
            goto out;
        }
    }
    if (exit_status == 126 || exit_status == 127) {
        set_error(error_out, "authorization was dismissed or denied");
        goto out;
    }
    if (exit_status != 0) {
        char* msg = g_strdup_printf("dpkg failed with exit code %d", exit_status);
        set_error(error_out, msg);
        g_free(msg);
        goto out;
    }
    // The deb replaced the file at our install path; probe that it launches.
    // No automated rollback is possible without root — the previous release's
    // .deb is retained in the cache dir for a manual `sudo dpkg -i` (this is
    // the documented divergence from the Mac .old rollback).
    if (exe && !updater_health_probe(exe)) {
        set_error(error_out,
                  "the updated binary failed its launch check; reinstall the previous "
                  "version from the update cache (see the .deb kept in "
                  "~/.cache/shenzhenpdf/updates)");
        goto out;
    }
    ok = TRUE;

out:
    g_free(exe);
    g_free(dpkg);
    g_free(pkexec);
    return ok;
}

typedef struct {
    char* tag;
} PendingTagArgs;

static gboolean mutator_set_pending_tag(SpdfUpdateStore* store, gpointer user_data) {
    PendingTagArgs* args = user_data;
    g_free(store->pending_tag);
    store->pending_tag = g_strdup(args->tag);
    return TRUE;
}

// Shared by the GTK flow (worker thread) and the CLI. Returns TRUE on a
// completed install (pendingTag recorded, cache pruned).
static gboolean updater_install_sync(const SpdfReleaseInfo* rel, GCancellable* cancellable, char** error_out) {
    char* verified;
    gboolean installed;
    PendingTagArgs args;

    // Refuse before downloading: on a no-dpkg system install (rpm etc.) the
    // .deb asset could never be applied (reached via --install-update; the
    // GTK prompt never offers Install Now here).
    if (!updater_can_install()) {
        set_error(error_out,
                  "this system does not use dpkg, so the update cannot be installed "
                  "automatically; update Shenzhen PDF through your package manager");
        return FALSE;
    }
    verified = updater_download_and_verify(rel, cancellable, error_out);
    if (!verified) return FALSE;
    installed = updater_is_user_local() ? updater_install_user_local(verified, error_out)
                                        : updater_install_deb(verified, error_out);
    if (installed) {
        args.tag = rel->tag;
        with_locked_update_store(mutator_set_pending_tag, &args);
        updater_prune_cache();
    }
    g_free(verified);
    return installed;
}

// ===========================================================================
// 10. Relaunch + launch health check
// ===========================================================================

static void updater_relaunch_and_quit(void) {
    char* exe = updater_self_exe();
    if (exe && g_updater.app) {
        // Session is saved before quitting (mirrors app.quit). The helper
        // shell sleeps past our GApplication bus-name release, then execs the
        // new binary, which restores the full multi-window session.
        char* quoted = g_shell_quote(exe);
        char* cmd = g_strdup_printf("sleep 1; exec %s", quoted);
        const char* argv[] = {"/bin/sh", "-c", cmd, NULL};
        GSubprocess* helper;
        spdf_app_save_session(g_updater.app);
        spdf_state_flush(spdf_app_get_state(g_updater.app));
        helper = g_subprocess_newv(argv, G_SUBPROCESS_FLAGS_NONE, NULL); // outlives us
        if (helper) g_object_unref(helper);
        g_free(cmd);
        g_free(quoted);
        g_application_quit(G_APPLICATION(g_updater.app));
    }
    g_free(exe);
}

static void restart_prompt_done(GObject* source, GAsyncResult* result, gpointer user_data) {
    int button = gtk_alert_dialog_choose_finish(GTK_ALERT_DIALOG(source), result, NULL);
    (void)user_data;
    if (button == 0) updater_relaunch_and_quit();
    // "Later": the new binary takes effect on the next launch; the pending
    // tag is confirmed by the launch health check then.
}

static void updater_prompt_restart(const char* tag) {
    GtkAlertDialog* alert = gtk_alert_dialog_new("Update %s installed", tag);
    const char* buttons[] = {"Restart Now", "Later", NULL};
    gtk_alert_dialog_set_detail(alert,
                                "Restart Shenzhen PDF to finish updating. Your windows and "
                                "tabs will be restored.");
    gtk_alert_dialog_set_buttons(alert, buttons);
    gtk_alert_dialog_set_default_button(alert, 0);
    gtk_alert_dialog_set_cancel_button(alert, 1);
    gtk_alert_dialog_choose(alert, updater_active_window(), NULL, restart_prompt_done, NULL);
    g_object_unref(alert);
}

typedef struct {
    char* pending;
    gboolean confirmed;
} ConsumePendingArgs;

static gboolean mutator_consume_pending(SpdfUpdateStore* store, gpointer user_data) {
    ConsumePendingArgs* args = user_data;

    if (!store->pending_tag || !*store->pending_tag) return FALSE;
    args->pending = g_strdup(store->pending_tag);
    args->confirmed = spdf_update_versions_match_release_target(store->pending_tag, updater_running_version());
    if (args->confirmed) {
        g_free(store->update_ok);
        store->update_ok = g_strdup(store->pending_tag);
    }
    g_clear_pointer(&store->pending_tag, g_free);
    // Whatever installed us is done driving; drop any leftover lease.
    store->lease_pid = 0;
    store->lease_ts = 0;
    return TRUE;
}

// Launch health check (runs once, a few seconds after launch): consume
// pendingTag. Confirmed => updateOk + delete <exe>.old + one-time banner.
// Mismatch => we are still (or again) the old build: the swap did not take or
// the user restored manually. Keep <exe>.old for recovery, clear the state.
static void updater_consume_pending_marker(void) {
    ConsumePendingArgs args = {NULL, FALSE};
    char* exe = updater_self_exe();
    char* old_path = exe ? g_strconcat(exe, ".old", NULL) : NULL;

    with_locked_update_store(mutator_consume_pending, &args);
    if (args.pending) {
        if (args.confirmed) {
            if (old_path) g_unlink(old_path);
            {
                char* msg = g_strdup_printf("You're now on Shenzhen PDF %s.", args.pending);
                updater_show_message(NULL, msg, NULL);
                g_free(msg);
            }
        } else {
            g_message(
                "shenzhenpdf: update to %s did not take (running %s); previous binary %s", args.pending,
                updater_running_version(),
                old_path && g_file_test(old_path, G_FILE_TEST_EXISTS) ? "kept alongside the install" : "not found");
        }
    } else if (old_path && g_file_test(old_path, G_FILE_TEST_EXISTS)) {
        // No update in flight: sweep an aged orphaned .old.
        GStatBuf st;
        gint64 now = g_get_real_time() / G_USEC_PER_SEC;
        if (g_stat(old_path, &st) == 0 && now - (gint64)st.st_mtime > SPDF_UPDATER_LEASE_STALE_SECONDS)
            g_unlink(old_path);
    }
    g_free(args.pending);
    g_free(old_path);
    g_free(exe);
}

// ===========================================================================
// 11. Check triggers, prompt flow, start / interactive / CLI
// ===========================================================================

static SpdfSettings* updater_settings(void) {
    if (!g_updater.app) return NULL;
    return spdf_state_settings(spdf_app_get_state(g_updater.app));
}

// ----- install flow (worker thread + main-thread bookends) -------------------

typedef struct {
    SpdfReleaseInfo release;
    char* error;
    gboolean ok;
} InstallCtx;

static void install_ctx_free(InstallCtx* ctx) {
    spdf_release_info_clear(&ctx->release);
    g_free(ctx->error);
    g_free(ctx);
}

static gboolean install_finished_idle(gpointer user_data) {
    InstallCtx* ctx = user_data;

    updater_dismiss_progress();
    g_updater.install_running = FALSE;
    g_clear_object(&g_updater.cancellable);
    with_locked_update_store(mutator_release_lease, NULL);

    if (ctx->ok) {
        updater_prompt_restart(ctx->release.tag);
    } else if (ctx->error && strcmp(ctx->error, "cancelled") != 0) {
        updater_show_message(NULL, "Software Update", ctx->error);
    }
    install_ctx_free(ctx);
    return G_SOURCE_REMOVE;
}

static gpointer install_thread(gpointer user_data) {
    InstallCtx* ctx = user_data;
    ctx->ok = updater_install_sync(&ctx->release, g_updater.cancellable, &ctx->error);
    g_idle_add(install_finished_idle, ctx);
    return NULL;
}

static void updater_begin_install(const SpdfReleaseInfo* release) {
    gboolean lease_acquired = FALSE;
    InstallCtx* ctx;

    if (g_updater.install_running) {
        updater_show_message(NULL, "Software Update", "An update is already in progress.");
        return;
    }
    with_locked_update_store(mutator_acquire_lease, &lease_acquired);
    if (!lease_acquired) {
        updater_show_message(NULL, "Software Update", "An update is already in progress.");
        return;
    }
    g_updater.install_running = TRUE;
    g_updater.cancellable = g_cancellable_new();

    ctx = g_new0(InstallCtx, 1);
    ctx->release.tag = g_strdup(release->tag);
    ctx->release.notes = g_strdup(release->notes);
    ctx->release.asset_url = g_strdup(release->asset_url);
    ctx->release.sig_url = g_strdup(release->sig_url);
    ctx->release.asset_size = release->asset_size;

    updater_show_progress(release->tag);
    // The progress bar tracks the growing asset file in the cache dir.
    {
        char* cache_dir = updater_cache_dir();
        char* tag_dir = g_build_filename(cache_dir, release->tag, NULL);
        g_clear_pointer(&g_updater.progress_path, g_free);
        g_updater.progress_path = g_build_filename(tag_dir, updater_asset_name(), NULL);
        g_updater.progress_total = release->asset_size;
        g_free(tag_dir);
        g_free(cache_dir);
    }
    g_thread_unref(g_thread_new("spdf-updater-install", install_thread, ctx));
}

// ----- update-available prompt -----------------------------------------------

typedef struct {
    SpdfReleaseInfo release;
    gboolean user_initiated;
    gboolean can_install; // FALSE: no-dpkg system install (rpm etc.)
} PromptCtx;

static void prompt_ctx_free(PromptCtx* ctx) {
    spdf_release_info_clear(&ctx->release);
    g_free(ctx);
}

typedef struct {
    char* tag;
} SnoozeArgs;

static gboolean mutator_snooze(SpdfUpdateStore* store, gpointer user_data) {
    SnoozeArgs* args = user_data;
    g_free(store->deferred_tag);
    store->deferred_tag = g_strdup(args->tag);
    store->remind_after = g_get_real_time() / G_USEC_PER_SEC + SPDF_UPDATER_LATER_SNOOZE_SECONDS;
    return TRUE;
}

static void update_prompt_done(GObject* source, GAsyncResult* result, gpointer user_data) {
    PromptCtx* ctx = user_data;
    int button = gtk_alert_dialog_choose_finish(GTK_ALERT_DIALOG(source), result, NULL);
    // Buttons: {"Install Now", "Skip This Version", "Later"} when installable,
    // {"OK", "Skip This Version"} on a no-dpkg system install (OK == Later).
    gboolean install = ctx->can_install && button == 0;
    gboolean skip = button == 1;

    if (install) {
        updater_begin_install(&ctx->release);
    } else if (skip) { // Skip This Version (permanent per-version)
        SpdfSettings* settings = updater_settings();
        if (settings) {
            spdf_state_set_string(&settings->skipped_update_version, ctx->release.tag);
            spdf_state_save_settings(spdf_app_get_state(g_updater.app));
        }
    } else { // Later/OK: snooze this tag on the silent path
        SnoozeArgs args = {ctx->release.tag};
        with_locked_update_store(mutator_snooze, &args);
    }
    prompt_ctx_free(ctx);
}

static void updater_present_update_available(PromptCtx* ctx) {
    GtkAlertDialog* alert =
        gtk_alert_dialog_new(ctx->can_install ? "Update %s ready" : "Update %s available", ctx->release.tag);
    const char* install_buttons[] = {"Install Now", "Skip This Version", "Later", NULL};
    const char* manual_buttons[] = {"OK", "Skip This Version", NULL};
    char* notes = spdf_updater_format_notes(ctx->release.notes);
    char* detail;

    detail = g_strdup_printf("Shenzhen PDF %s is available — you have %s.%s%s", ctx->release.tag,
                             updater_running_version(), *notes ? "\n\n" : "", notes);
    if (!ctx->can_install) {
        // Announce only: this system install cannot take the .deb asset
        // (no dpkg — e.g. the rpm package), so never offer Install Now.
        char* manual = g_strdup_printf(
            "%s\n\nThis copy was installed by your system's package manager, so it "
            "can't update itself. Install the new version the same way you installed "
            "this one.",
            detail);
        g_free(detail);
        detail = manual;
    }
    gtk_alert_dialog_set_detail(alert, detail);
    gtk_alert_dialog_set_buttons(alert, ctx->can_install ? install_buttons : manual_buttons);
    gtk_alert_dialog_set_default_button(alert, 0);
    gtk_alert_dialog_set_cancel_button(alert, ctx->can_install ? 2 : 0);
    gtk_alert_dialog_choose(alert, updater_active_window(), NULL, update_prompt_done, ctx);
    g_object_unref(alert);
    g_free(detail);
    g_free(notes);
}

// ----- check flow (worker thread + main-thread completion) -------------------

typedef struct {
    gboolean user_initiated;
    SpdfCheckOutcome outcome;
} CheckCtx;

static gboolean check_finished_idle(gpointer user_data) {
    CheckCtx* ctx = user_data;
    SpdfCheckOutcome* o = &ctx->outcome;

    g_updater.check_running = FALSE;

    if (!o->ok) {
        if (ctx->user_initiated)
            updater_show_message(NULL, "Software Update", o->error ? o->error : "The update check failed.");
        goto done; // silent on the daily path; lastUpdateCheck already stamped
    }

    if (o->available) {
        gboolean suppress = FALSE;
        if (!ctx->user_initiated) {
            // Silent path honours Skip + the "Later" snooze; manual ignores both.
            SpdfSettings* settings = updater_settings();
            StoreSnapshot snap = {0};
            if (settings && settings->skipped_update_version &&
                g_strcmp0(settings->skipped_update_version, o->release.tag) == 0)
                suppress = TRUE;
            with_locked_update_store(mutator_read_snapshot, &snap);
            if (!suppress && snap.deferred_tag && g_strcmp0(snap.deferred_tag, o->release.tag) == 0 &&
                g_get_real_time() / G_USEC_PER_SEC < snap.remind_after)
                suppress = TRUE;
            g_free(snap.etag);
            g_free(snap.highest_seen);
            g_free(snap.deferred_tag);
        }
        if (!suppress) {
            PromptCtx* prompt = g_new0(PromptCtx, 1);
            prompt->user_initiated = ctx->user_initiated;
            prompt->can_install = updater_can_install();
            prompt->release = o->release; // transfer ownership
            memset(&o->release, 0, sizeof(o->release));
            updater_present_update_available(prompt);
        }
    } else if (ctx->user_initiated) {
        if (o->newer_but_missing_asset) {
            char* detail = g_strdup_printf(
                "Release %s exists but does not ship the required Linux asset (%s), so it "
                "cannot be installed automatically.",
                o->release.tag, updater_asset_name());
            updater_show_message(NULL, "Software Update", detail);
            g_free(detail);
        } else {
            char* detail = g_strdup_printf("Shenzhen PDF %s is the latest version.", updater_running_version());
            updater_show_message(NULL, "You're up to date.", detail);
            g_free(detail);
        }
    }

done:
    check_outcome_clear(&ctx->outcome);
    g_free(ctx);
    return G_SOURCE_REMOVE;
}

static gpointer check_thread(gpointer user_data) {
    CheckCtx* ctx = user_data;
    updater_check_sync(ctx->user_initiated, &ctx->outcome);
    g_idle_add(check_finished_idle, ctx);
    return NULL;
}

static void updater_launch_check(gboolean user_initiated) {
    CheckCtx* ctx;

    if (g_updater.check_running || g_updater.install_running) {
        if (user_initiated) updater_show_message(NULL, "Software Update", "An update check is already running.");
        return;
    }
    g_updater.check_running = TRUE;
    ctx = g_new0(CheckCtx, 1);
    ctx->user_initiated = user_initiated;
    g_thread_unref(g_thread_new("spdf-updater-check", check_thread, ctx));
}

// ----- cadence triggers -------------------------------------------------------

// Shared by the post-launch idle trigger and the hourly cadence timer: read
// autoUpdateEnabled live, then try to claim the flock'd 24h slot. Stamping
// happens before the network call, so redundant triggers are harmless.
static void updater_daily_trigger(void) {
    SpdfSettings* settings = updater_settings();
    gboolean claimed = FALSE;

    if (!settings || !settings->auto_update_enabled) return;
    with_locked_update_store(mutator_claim_daily_slot, &claimed);
    if (!claimed) return;
    updater_launch_check(FALSE);
}

static gboolean updater_cadence_tick(gpointer user_data) {
    (void)user_data;
    updater_daily_trigger();
    return G_SOURCE_CONTINUE;
}

static gboolean updater_first_idle(gpointer user_data) {
    (void)user_data;
    g_updater.first_check_id = 0;
    // Health check for a just-installed update first, then the daily check.
    updater_consume_pending_marker();
    updater_daily_trigger();
    return G_SOURCE_REMOVE;
}

// ----- public entry points ----------------------------------------------------

// Flatpak installs update through the remote that shipped them (Flathub);
// self-updating would fight the sandbox (read-only /app, no pkexec/dpkg) and
// the store. Same disable-with-a-reason pattern as the missing-curl/wget
// path: the silent cadence never arms, the manual check explains itself.
#define SPDF_UPDATER_FLATPAK_REASON                                           \
    "This Shenzhen PDF was installed as a Flatpak; updates are delivered by " \
    "your software store (e.g. Flathub), not the built-in updater."

void spdf_updater_start(SpdfApp* app) {
    g_return_if_fail(SPDF_IS_APP(app));
    if (spdf_running_in_flatpak()) {
        g_message("shenzhenpdf: %s", SPDF_UPDATER_FLATPAK_REASON);
        return; // no timers, no state, no network — fully disabled
    }
    if (g_updater.app) return; // started once per process
    g_updater.app = g_object_ref(app);
    // Nothing runs on the launch path: the first gate/health-check I/O happens
    // seconds after the main loop settles, and the network check on a worker
    // thread after that. The hourly cadence timer re-arms the 24h gate so an
    // app left running for days keeps checking (GLib timers don't fire while
    // suspended; the hourly poll catches up naturally after resume).
    g_updater.first_check_id = g_timeout_add_seconds(SPDF_UPDATER_IDLE_DELAY_SECONDS, updater_first_idle, NULL);
    g_updater.cadence_id = g_timeout_add_seconds(SPDF_UPDATER_CADENCE_SECONDS, updater_cadence_tick, NULL);
}

void spdf_updater_check_interactive(SpdfApp* app, GtkWindow* parent) {
    g_return_if_fail(SPDF_IS_APP(app));
    if (spdf_running_in_flatpak()) {
        updater_show_message(parent, "Software Update", SPDF_UPDATER_FLATPAK_REASON);
        return;
    }
    (void)parent; // dialogs attach to the active window
    if (!g_updater.app) g_updater.app = g_object_ref(app);
    updater_launch_check(TRUE);
}

// ----- CLI --------------------------------------------------------------------

static int updater_cli_check(void) {
    SpdfCheckOutcome outcome;
    int status = 1;

    updater_check_sync(TRUE, &outcome);
    if (!outcome.ok) {
        g_printerr("check-failed: %s\n", outcome.error ? outcome.error : "unknown error");
    } else if (outcome.available) {
        g_print("update-available %s %s\n", outcome.release.tag, outcome.release.asset_url);
        status = 0;
    } else if (outcome.newer_but_missing_asset) {
        g_print("update-unavailable %s (no %s asset)\n", outcome.release.tag, updater_asset_name());
        status = 0;
    } else {
        g_print("up-to-date %s\n", updater_running_version());
        status = 0;
    }
    check_outcome_clear(&outcome);
    return status;
}

static int updater_cli_install(void) {
    SpdfCheckOutcome outcome;
    int status = 1;

    updater_check_sync(TRUE, &outcome);
    if (!outcome.ok) {
        g_printerr("check-failed: %s\n", outcome.error ? outcome.error : "unknown error");
    } else if (!outcome.available) {
        g_print("no-update %s\n", updater_running_version());
        status = 0;
    } else {
        gboolean lease_acquired = FALSE;
        char* error = NULL;

        g_print("downloading %s\n", outcome.release.tag);
        with_locked_update_store(mutator_acquire_lease, &lease_acquired);
        if (!lease_acquired) {
            g_printerr("install-failed: an update is already in progress\n");
        } else if (updater_install_sync(&outcome.release, NULL, &error)) {
            with_locked_update_store(mutator_release_lease, NULL);
            g_print("installed %s (restart Shenzhen PDF to finish)\n", outcome.release.tag);
            status = 0;
        } else {
            with_locked_update_store(mutator_release_lease, NULL);
            g_printerr("install-failed: %s\n", error ? error : "unknown error");
        }
        g_free(error);
    }
    check_outcome_clear(&outcome);
    return status;
}

int spdf_updater_handle_cli(int argc, char** argv) {
    for (int i = 1; i < argc; ++i) {
        if (!argv[i]) continue;
        if (strcmp(argv[i], "--updater-health-probe") == 0) return 0;
        if (strcmp(argv[i], "--check-updates-now") == 0 || strcmp(argv[i], "--install-update") == 0) {
            if (spdf_running_in_flatpak()) {
                g_print("updates-disabled: %s\n", SPDF_UPDATER_FLATPAK_REASON);
                return 0;
            }
            return strcmp(argv[i], "--check-updates-now") == 0 ? updater_cli_check() : updater_cli_install();
        }
    }
    return -1;
}

#endif // !SPDF_UPDATER_TESTING
