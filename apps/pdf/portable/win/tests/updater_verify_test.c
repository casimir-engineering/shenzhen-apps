/* updater_verify_test.c — the updater's trust boundary, exercised against real
 * signatures: WinVerifyTrust plus the pinned-thumbprint rule, the on-disk
 * version resource, and SHA-256.
 *
 * WHAT IT PROVES, in order:
 *   1. THE NEGATIVE PATH, on this very test binary: it is unsigned, so
 *      verify_authenticode() must fail, signer_thumbprint() must find nothing,
 *      and verify_pinned() must fail whatever the pin says. This is the case
 *      that matters most -- a verifier that accepts an unsigned file is not a
 *      verifier -- and it needs no fixture, because cl.exe just built one.
 *   2. THE PIN RULE: an empty pin fails BEFORE any signature is consulted,
 *      with the "this build cannot verify updates" message; a malformed pin
 *      fails the same way. This is the "never install, never skip" decision.
 *   3. THE POSITIVE PATH, on a system binary that carries an EMBEDDED
 *      Authenticode signature. Windows 11 catalog-signs most of System32, and
 *      a catalog signature is exactly what WinVerifyTrust(WTD_CHOICE_FILE) must
 *      NOT accept for a download -- so the candidates are the few Microsoft
 *      binaries known to be embedded-signed, tried in order. With one found:
 *      authenticode verifies, the thumbprint is 64 hex digits, pinning to THAT
 *      thumbprint passes, and pinning to a different 64-hex string fails with
 *      the "signed, but not by Shenzhen PDF's publisher" message. With none
 *      found the case is reported and the exit code stays 0: nothing about the
 *      code under test was learned, and the negative path above still ran.
 *   4. The ProductVersion string of an exe on disk is readable (any system exe
 *      has one) and absent for a non-PE file.
 *   5. SHA-256 of a temp file with known content matches the published digest
 *      ("abc" -> ba7816bf...), and the sidecar parser round-trips it.
 *
 * NO NETWORK. Revocation is cache-only in the code under test, so an offline
 * machine gives the same answers.
 */
/* spdf-test-sources: portable/win/src/spdf_win_updater_verify.cpp portable/win/src/spdf_win_updater_feed.c portable/win/src/spdf_win_updater_version.c portable/win/src/spdf_win_updater_store.c */
#include <windows.h>

#include "spdf_win_updater.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                      \
    do {                                                                                 \
        ++g_checks;                                                                      \
        if (!(cond)) {                                                                   \
            fprintf(stderr, "FAIL %s (%s:%d)\n", #cond, __FILE__, __LINE__);             \
            ++g_failures;                                                                \
        }                                                                                \
    } while (0)

static int is_hex64(const char* s) {
    int i;
    if (!s || strlen(s) != 64) return 0;
    for (i = 0; i < 64; ++i)
        if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return 0;
    return 1;
}

/* --- 1 + 2. the unsigned test binary and the pin rule --------------------- */

static void test_unsigned_self(void) {
    wchar_t self[MAX_PATH];
    char err[256];
    char thumb[65];

    CHECK(GetModuleFileNameW(NULL, self, MAX_PATH) > 0);
    CHECK(!spdf_win_updater_verify_authenticode(self, err, sizeof(err)));
    CHECK(strstr(err, "not signed") != NULL);
    CHECK(!spdf_win_updater_signer_thumbprint(self, thumb, sizeof(thumb)));
    CHECK(thumb[0] == '\0');

    /* The pin rule. */
    CHECK(!spdf_win_updater_verify_pinned(self, "", err, sizeof(err)));
    CHECK(strstr(err, "cannot verify updates") != NULL);
    CHECK(!spdf_win_updater_verify_pinned(self, NULL, err, sizeof(err)));
    CHECK(strstr(err, "cannot verify updates") != NULL);
    CHECK(!spdf_win_updater_verify_pinned(self, "abc", err, sizeof(err))); /* too short */
    CHECK(strstr(err, "cannot verify updates") != NULL);
    CHECK(!spdf_win_updater_verify_pinned(
        self, "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ", err, sizeof(err))); /* not hex */
    CHECK(strstr(err, "malformed") != NULL);
    /* A well-formed pin against an unsigned file: the signature check fails. */
    CHECK(!spdf_win_updater_verify_pinned(
        self, "0000000000000000000000000000000000000000000000000000000000000000", err, sizeof(err)));
    CHECK(strstr(err, "not signed") != NULL);
    /* The compiled-in pin is empty until the release pipeline has a
     * certificate, and the code must say so rather than pretend. */
    CHECK(spdf_win_updater_pinned_thumbprint() != NULL);
    CHECK(strlen(spdf_win_updater_pinned_thumbprint()) == 0 || is_hex64(spdf_win_updater_pinned_thumbprint()));

    /* A file that does not exist. */
    CHECK(!spdf_win_updater_verify_authenticode(L"C:\\nonexistent\\ShenzhenPDF-win-x64.exe", err, sizeof(err)));
    CHECK(!spdf_win_updater_verify_authenticode(NULL, err, sizeof(err)));
}

/* --- 3. a real embedded signature --------------------------------------- */

static const wchar_t* const k_signed_candidates[] = {
    /* System32 candidates that historically carry embedded signatures; the
     * catalog-only ones simply fail the probe and are skipped. */
    L"%WINDIR%\\System32\\notepad.exe",
    L"%WINDIR%\\explorer.exe",
    L"%WINDIR%\\System32\\smartscreen.exe",
    L"%WINDIR%\\System32\\mrt.exe",
    L"%WINDIR%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
    L"%WINDIR%\\System32\\OneDriveSetup.exe",
    L"%WINDIR%\\SysWOW64\\OneDriveSetup.exe",
    L"%ProgramFiles%\\Windows Defender\\MpCmdRun.exe",
    L"%ProgramFiles(x86)%\\Microsoft\\Edge\\Application\\msedge.exe",
    L"%ProgramFiles%\\Microsoft\\Edge\\Application\\msedge.exe",
    L"%ProgramFiles%\\PowerShell\\7\\pwsh.exe",
    L"%ProgramFiles%\\Git\\cmd\\git.exe",
    L"%ProgramFiles(x86)%\\Windows Kits\\10\\bin\\10.0.26100.0\\x64\\signtool.exe",
    L"%ProgramFiles(x86)%\\Windows Kits\\10\\bin\\10.0.22621.0\\x64\\signtool.exe",
};

static void test_signed_system_binary(void) {
    wchar_t path[MAX_PATH];
    char err[256];
    char thumb[65];
    char other[65];
    size_t i;
    int found = 0;

    for (i = 0; i < sizeof(k_signed_candidates) / sizeof(k_signed_candidates[0]) && !found; ++i) {
        if (!ExpandEnvironmentStringsW(k_signed_candidates[i], path, MAX_PATH)) continue;
        if (GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES) continue;
        if (!spdf_win_updater_verify_authenticode(path, err, sizeof(err))) continue;
        found = 1;
        printf("updater_verify_test: embedded-signed positive fixture: %ls\n", path);
        CHECK(spdf_win_updater_signer_thumbprint(path, thumb, sizeof(thumb)));
        CHECK(is_hex64(thumb));
        printf("updater_verify_test: signer thumbprint %s\n", thumb);
        /* Pin to the actual signer: passes. */
        CHECK(spdf_win_updater_verify_pinned(path, thumb, err, sizeof(err)));
        CHECK(err[0] == '\0');
        /* Pin to someone else: a valid signature is still a rejection. */
        memcpy(other, thumb, 65);
        other[0] = other[0] == '0' ? '1' : '0';
        CHECK(!spdf_win_updater_verify_pinned(path, other, err, sizeof(err)));
        CHECK(strstr(err, "not by Shenzhen PDF's publisher") != NULL);
        /* And the pin rule still comes first even on a signed file. */
        CHECK(!spdf_win_updater_verify_pinned(path, "", err, sizeof(err)));
        CHECK(strstr(err, "cannot verify updates") != NULL);
    }
    if (!found)
        printf("updater_verify_test: NOTE no embedded-signed system binary found among %u candidates; the positive "
               "path did not run (Windows 11 catalog-signs System32). The negative path ran.\n",
               (unsigned)(sizeof(k_signed_candidates) / sizeof(k_signed_candidates[0])));
}

/* --- 4. the version resource -------------------------------------------- */

static void test_product_version(void) {
    wchar_t path[MAX_PATH];
    char version[128];
    wchar_t self[MAX_PATH];

    CHECK(ExpandEnvironmentStringsW(L"%WINDIR%\\System32\\notepad.exe", path, MAX_PATH) > 0);
    if (GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES) {
        CHECK(spdf_win_updater_file_product_version(path, version, sizeof(version)));
        CHECK(version[0] >= '0' && version[0] <= '9');
        printf("updater_verify_test: notepad ProductVersion %s\n", version);
    }
    /* This test binary was linked with no resource script: no version. */
    CHECK(GetModuleFileNameW(NULL, self, MAX_PATH) > 0);
    CHECK(!spdf_win_updater_file_product_version(self, version, sizeof(version)));
    CHECK(version[0] == '\0');
    CHECK(!spdf_win_updater_file_product_version(L"C:\\nonexistent.exe", version, sizeof(version)));
    CHECK(!spdf_win_updater_file_product_version(NULL, version, sizeof(version)));
}

/* --- 5. SHA-256 --------------------------------------------------------- */

static void test_sha256(void) {
    wchar_t dir[MAX_PATH];
    wchar_t file[MAX_PATH + 32];
    HANDLE h;
    DWORD wrote = 0;
    char hex[65];
    char parsed[65];
    char sidecar[128];

    CHECK(GetTempPathW(MAX_PATH, dir) > 0);
    _snwprintf_s(file, _countof(file), _TRUNCATE, L"%sspdf-sha256-%lu.bin", dir, (unsigned long)GetCurrentProcessId());
    h = CreateFileW(file, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    CHECK(h != INVALID_HANDLE_VALUE);
    if (h != INVALID_HANDLE_VALUE) {
        CHECK(WriteFile(h, "abc", 3, &wrote, NULL) && wrote == 3);
        CloseHandle(h);
    }
    CHECK(spdf_win_updater_sha256_file(file, hex, sizeof(hex)));
    CHECK(strcmp(hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") == 0);
    /* The sidecar the release pipeline will publish, and the comparison the
     * updater makes with it. */
    snprintf(sidecar, sizeof(sidecar), "%s  ShenzhenPDF-win-x64.exe\n", hex);
    CHECK(spdf_win_updater_parse_sha256_sidecar(sidecar, parsed, sizeof(parsed)));
    CHECK(strcmp(parsed, hex) == 0);
    /* An empty file has the well-known empty digest. */
    h = CreateFileW(file, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
    CHECK(spdf_win_updater_sha256_file(file, hex, sizeof(hex)));
    CHECK(strcmp(hex, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") == 0);
    DeleteFileW(file);
    CHECK(!spdf_win_updater_sha256_file(file, hex, sizeof(hex))); /* gone */
    CHECK(!spdf_win_updater_sha256_file(NULL, hex, sizeof(hex)));
    CHECK(!spdf_win_updater_sha256_file(file, hex, 10));
}

int main(void) {
    test_unsigned_self();
    test_signed_system_binary();
    test_product_version();
    test_sha256();
    printf("updater_verify_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
