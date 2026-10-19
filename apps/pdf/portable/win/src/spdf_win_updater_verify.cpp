/* spdf_win_updater_verify.cpp — the updater's trust boundary on Windows:
 * Authenticode plus a pinned publisher thumbprint, and the two integrity
 * checks around it (the on-disk version resource, SHA-256).
 *
 * WHY AUTHENTICODE AND NOT A VENDORED ED25519. The other two frontends verify
 * against a key THEY carry: macOS pins the Developer ID Team, Linux pins a
 * minisign public key and verifies with OpenSSL. Windows has neither OpenSSL
 * nor a package signer, but it has the platform's own counterpart of the
 * Developer ID -- Authenticode -- and WinVerifyTrust is what Explorer, SmartScreen
 * and every installer already trust. A hand-rolled ed25519 in this tree would
 * be one more thing to audit that does nothing Authenticode does not.
 *
 * WHY THE PIN ON TOP OF WinVerifyTrust. WinVerifyTrust answers "is this signed
 * by SOME certificate the machine trusts?" -- any of the hundreds of code-signing
 * CAs. The pin answers the question that matters: "is it signed by US?" It is
 * the SHA-256 thumbprint of the leaf certificate, compiled in as a constant,
 * exactly as Linux compiles in its minisign key. Until a certificate exists the
 * constant is "", and "" fails every verification: a build that cannot verify
 * updates must not install them. This is NOT a skip, and the message the user
 * sees says so.
 *
 * WHAT IS CHECKED, in order, and what each catches:
 *   1. WinVerifyTrust, embedded signature, chain to a trusted root, revocation
 *      from the cache only (an offline machine must still be able to verify).
 *      Catches: an unsigned file, a tampered file, a broken chain.
 *   2. Leaf thumbprint == pin. Catches: a valid signature by someone else.
 *   3. (caller) VERSIONINFO ProductVersion == the release tag, read from the
 *      file on disk. Catches: the right publisher's WRONG build, before it is
 *      swapped in -- so a mismatched relaunch is stopped before the relaunch.
 *   4. (caller) SHA-256 == the sidecar. Catches truncation and a CDN serving
 *      stale bytes. Integrity only; never a trust decision.
 */
#include "spdf_win_updater.h"

#include <windows.h>
#include <softpub.h>
#include <wincrypt.h>
#include <wintrust.h>

#include <stdio.h>
#include <string.h>

#pragma comment(lib, "wintrust.lib")
#pragma comment(lib, "crypt32.lib")
#pragma comment(lib, "version.lib")
#pragma comment(lib, "advapi32.lib")

/* THE PIN. 64 lower-case hex digits: the SHA-256 thumbprint of the leaf
 * code-signing certificate that signs ShenzhenPDF-win-x64.exe, as
 * `certutil -hashfile cert.cer SHA256` or the certificate's Details tab prints
 * it. The release pipeline fills this when a certificate exists; a changed
 * certificate is a new release of the app (which this constant then pins),
 * exactly as a rotated minisign key would be on Linux. */
static const char k_spdf_win_pinned_thumbprint[] = "";

const char* spdf_win_updater_pinned_thumbprint(void) {
    return k_spdf_win_pinned_thumbprint;
}

static void set_err(char* err, size_t err_len, const char* msg) {
    if (!err || !err_len) return;
    strncpy_s(err, err_len, msg, _TRUNCATE);
}

int spdf_win_updater_verify_authenticode(const wchar_t* path, char* err, size_t err_len) {
    GUID action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
    WINTRUST_FILE_INFO file;
    WINTRUST_DATA data;
    LONG status;

    if (err && err_len) err[0] = '\0';
    if (!path || !*path) {
        set_err(err, err_len, "no file to verify");
        return 0;
    }
    memset(&file, 0, sizeof(file));
    file.cbStruct = sizeof(file);
    file.pcwszFilePath = path;

    memset(&data, 0, sizeof(data));
    data.cbStruct = sizeof(data);
    data.dwUIChoice = WTD_UI_NONE;
    /* Cache-only revocation: a machine with no network must still verify an
     * update it has already downloaded, and the chain itself is still checked
     * against the trusted roots. */
    data.fdwRevocationChecks = WTD_REVOKE_NONE;
    data.dwUnionChoice = WTD_CHOICE_FILE;
    data.pFile = &file;
    data.dwStateAction = WTD_STATEACTION_VERIFY;
    data.dwProvFlags = WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT | WTD_CACHE_ONLY_URL_RETRIEVAL;
    data.dwUIContext = WTD_UICONTEXT_EXECUTE;

    status = WinVerifyTrust((HWND)INVALID_HANDLE_VALUE, &action, &data);
    data.dwStateAction = WTD_STATEACTION_CLOSE;
    WinVerifyTrust((HWND)INVALID_HANDLE_VALUE, &action, &data);

    if (status == ERROR_SUCCESS) return 1;
    switch ((DWORD)status) {
        case TRUST_E_NOSIGNATURE:
            set_err(err, err_len, "the downloaded file is not signed");
            break;
        case TRUST_E_EXPLICIT_DISTRUST:
            set_err(err, err_len, "the downloaded file's signature is explicitly distrusted on this machine");
            break;
        case TRUST_E_SUBJECT_NOT_TRUSTED:
            set_err(err, err_len, "the downloaded file's publisher is not trusted");
            break;
        case CERT_E_UNTRUSTEDROOT:
            set_err(err, err_len, "the downloaded file's certificate chain does not reach a trusted root");
            break;
        case TRUST_E_BAD_DIGEST:
            set_err(err, err_len, "the downloaded file does not match its signature (altered in transit)");
            break;
        default: {
            char msg[128];
            snprintf(msg, sizeof(msg), "the downloaded file's signature did not verify (0x%08lX)", (unsigned long)status);
            set_err(err, err_len, msg);
        }
    }
    return 0;
}

int spdf_win_updater_signer_thumbprint(const wchar_t* path, char* out_hex, size_t out_len) {
    HCERTSTORE store = NULL;
    HCRYPTMSG msg = NULL;
    DWORD encoding = 0, content_type = 0, format_type = 0;
    DWORD signer_len = 0;
    PCMSG_SIGNER_INFO signer = NULL;
    PCCERT_CONTEXT cert = NULL;
    CERT_INFO want;
    BYTE hash[32];
    DWORD hash_len = sizeof(hash);
    int ok = 0;
    static const char hex[] = "0123456789abcdef";

    if (!out_hex || out_len < 65) return 0;
    out_hex[0] = '\0';
    if (!path) return 0;

    if (!CryptQueryObject(CERT_QUERY_OBJECT_FILE, path, CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED_EMBED,
                          CERT_QUERY_FORMAT_FLAG_BINARY, 0, &encoding, &content_type, &format_type, &store, &msg,
                          NULL))
        return 0;
    if (!CryptMsgGetParam(msg, CMSG_SIGNER_INFO_PARAM, 0, NULL, &signer_len) || signer_len == 0) goto out;
    signer = (PCMSG_SIGNER_INFO)LocalAlloc(LPTR, signer_len);
    if (!signer) goto out;
    if (!CryptMsgGetParam(msg, CMSG_SIGNER_INFO_PARAM, 0, signer, &signer_len)) goto out;

    memset(&want, 0, sizeof(want));
    want.Issuer = signer->Issuer;
    want.SerialNumber = signer->SerialNumber;
    cert = CertFindCertificateInStore(store, encoding, 0, CERT_FIND_SUBJECT_CERT, &want, NULL);
    if (!cert) goto out;
    /* SHA-256 over the DER certificate: what certutil and the Details tab call
     * the thumbprint when asked for SHA256. The legacy CERT_HASH_PROP_ID is
     * SHA-1 and is not used here. */
    if (!CertGetCertificateContextProperty(cert, CERT_SHA256_HASH_PROP_ID, hash, &hash_len) || hash_len != 32)
        goto out;
    for (DWORD i = 0; i < 32; ++i) {
        out_hex[i * 2] = hex[hash[i] >> 4];
        out_hex[i * 2 + 1] = hex[hash[i] & 0xF];
    }
    out_hex[64] = '\0';
    ok = 1;

out:
    if (cert) CertFreeCertificateContext(cert);
    if (signer) LocalFree(signer);
    if (msg) CryptMsgClose(msg);
    if (store) CertCloseStore(store, 0);
    return ok;
}

int spdf_win_updater_verify_pinned(const wchar_t* path, const char* pinned_hex, char* err, size_t err_len) {
    char thumb[65];
    size_t i;

    if (err && err_len) err[0] = '\0';
    /* The pin is checked FIRST so that an unpinned build reports the real
     * reason -- "this build cannot verify updates" -- and not whatever
     * WinVerifyTrust happened to say about the file. */
    if (!pinned_hex || strlen(pinned_hex) != 64) {
        set_err(err, err_len,
                "this build of Shenzhen PDF carries no publisher certificate pin, so it cannot verify updates and "
                "will not install them; download the release from GitHub instead");
        return 0;
    }
    for (i = 0; i < 64; ++i) {
        char ch = pinned_hex[i];
        if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'))) {
            set_err(err, err_len, "this build's publisher certificate pin is malformed; updates cannot be verified");
            return 0;
        }
    }
    if (!spdf_win_updater_verify_authenticode(path, err, err_len)) return 0;
    if (!spdf_win_updater_signer_thumbprint(path, thumb, sizeof(thumb))) {
        set_err(err, err_len, "the downloaded file's signing certificate could not be read");
        return 0;
    }
    if (strcmp(thumb, pinned_hex) != 0) {
        set_err(err, err_len, "the downloaded file is signed, but not by Shenzhen PDF's publisher");
        return 0;
    }
    return 1;
}

int spdf_win_updater_file_product_version(const wchar_t* path, char* out, size_t out_len) {
    DWORD handle = 0;
    DWORD size;
    void* block;
    struct LANGANDCODEPAGE {
        WORD language;
        WORD codepage;
    }* translate = NULL;
    UINT translate_len = 0;
    int ok = 0;

    if (!out || !out_len) return 0;
    out[0] = '\0';
    if (!path) return 0;
    size = GetFileVersionInfoSizeW(path, &handle);
    if (!size) return 0;
    block = malloc(size);
    if (!block) return 0;
    if (GetFileVersionInfoW(path, 0, size, block) &&
        VerQueryValueW(block, L"\\VarFileInfo\\Translation", (void**)&translate, &translate_len) &&
        translate_len >= sizeof(*translate)) {
        UINT count = translate_len / sizeof(*translate);
        for (UINT i = 0; i < count && !ok; ++i) {
            wchar_t sub[64];
            wchar_t* value = NULL;
            UINT value_len = 0;
            _snwprintf_s(sub, _countof(sub), _TRUNCATE, L"\\StringFileInfo\\%04x%04x\\ProductVersion",
                         translate[i].language, translate[i].codepage);
            if (VerQueryValueW(block, sub, (void**)&value, &value_len) && value && value_len) {
                if (WideCharToMultiByte(CP_UTF8, 0, value, -1, out, (int)out_len, NULL, NULL) > 0) ok = 1;
                else out[0] = '\0';
            }
        }
    }
    free(block);
    return ok;
}

int spdf_win_updater_sha256_file(const wchar_t* path, char* out_hex, size_t out_len) {
    HCRYPTPROV prov = 0;
    HCRYPTHASH hash = 0;
    HANDLE file = INVALID_HANDLE_VALUE;
    BYTE buf[64 * 1024];
    BYTE digest[32];
    DWORD digest_len = sizeof(digest);
    DWORD got;
    int ok = 0;
    static const char hex[] = "0123456789abcdef";

    if (!out_hex || out_len < 65) return 0;
    out_hex[0] = '\0';
    if (!path) return 0;
    file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return 0;
    if (!CryptAcquireContextW(&prov, NULL, NULL, PROV_RSA_AES, CRYPT_VERIFYCONTEXT)) goto out;
    if (!CryptCreateHash(prov, CALG_SHA_256, 0, 0, &hash)) goto out;
    for (;;) {
        if (!ReadFile(file, buf, sizeof(buf), &got, NULL)) goto out;
        if (got == 0) break;
        if (!CryptHashData(hash, buf, got, 0)) goto out;
    }
    if (!CryptGetHashParam(hash, HP_HASHVAL, digest, &digest_len, 0) || digest_len != 32) goto out;
    for (DWORD i = 0; i < 32; ++i) {
        out_hex[i * 2] = hex[digest[i] >> 4];
        out_hex[i * 2 + 1] = hex[digest[i] & 0xF];
    }
    out_hex[64] = '\0';
    ok = 1;
out:
    if (hash) CryptDestroyHash(hash);
    if (prov) CryptReleaseContext(prov, 0);
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    return ok;
}
