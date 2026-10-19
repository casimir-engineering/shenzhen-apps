/* watcher_logic_test.c — pins spdf_win_watcher_logic.h with the GTK original's
 * own cases (portable/linux/gtk4/tests/watcher_test.c) transcribed: the
 * trailing-edge debounce, the shadow-copy name's shape and determinism, the
 * containment rule, the read-only decision table, stat comparison, copy reuse
 * and the orphan sweep -- plus the SHA-256 the name is built on, against the
 * FIPS 180-4 vectors, since it is written out here rather than taken from a
 * library. The probes that touch the filesystem are watcher_test.c's.
 *
 * Header-only under test, so no `spdf-test-sources` line.
 */
#include "spdf_win_watcher_logic.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                                     \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

#define CHECK_STR(got, want)                                                                                           \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (strcmp((got), (want)) != 0) {                                                                              \
            printf("FAIL %s:%d: \"%s\" != \"%s\"\n", __FILE__, __LINE__, (got), (want));                               \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

static void hex_of(const unsigned char* d, size_t n, char* out) {
    static const char hex[] = "0123456789abcdef";
    size_t i;
    for (i = 0; i < n; ++i) {
        out[i * 2] = hex[d[i] >> 4];
        out[i * 2 + 1] = hex[d[i] & 0xF];
    }
    out[n * 2] = '\0';
}

static void test_debounce_coalesce(void) {
    SpdfWinWatcherDebounce d = {0};
    const long long delay = 500 * 1000;
    CHECK(!spdf_win_watcher_debounce_fire(&d, 1000));
    CHECK(spdf_win_watcher_debounce_event(&d, 0, delay) == delay);
    CHECK(spdf_win_watcher_debounce_event(&d, 100 * 1000, delay) == 600 * 1000);
    CHECK(spdf_win_watcher_debounce_event(&d, 450 * 1000, delay) == 950 * 1000);
    CHECK(!spdf_win_watcher_debounce_fire(&d, 949 * 1000));
    CHECK(spdf_win_watcher_debounce_fire(&d, 950 * 1000));
    CHECK(!spdf_win_watcher_debounce_fire(&d, 951 * 1000));
    spdf_win_watcher_debounce_event(&d, 2000 * 1000, delay);
    CHECK(!spdf_win_watcher_debounce_fire(&d, 2000 * 1000 + delay - 1));
    CHECK(spdf_win_watcher_debounce_fire(&d, 2000 * 1000 + delay));
}

static void test_sha256_vectors(void) {
    unsigned char d[32];
    char hex[65];
    unsigned char million[1000];
    spdf_win_watcher_sha256((const unsigned char*)"abc", 3, d);
    hex_of(d, 32, hex);
    CHECK_STR(hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    spdf_win_watcher_sha256((const unsigned char*)"", 0, d);
    hex_of(d, 32, hex);
    CHECK_STR(hex, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    spdf_win_watcher_sha256((const unsigned char*)"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 56, d);
    hex_of(d, 32, hex);
    CHECK_STR(hex, "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
    /* 55, 56, 63, 64 and 65 bytes straddle the padding boundary. */
    memset(million, 'a', sizeof(million));
    spdf_win_watcher_sha256(million, 64, d);
    hex_of(d, 32, hex);
    CHECK_STR(hex, "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb");
    spdf_win_watcher_sha256(million, 65, d);
    hex_of(d, 32, hex);
    CHECK_STR(hex, "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0");
}

static void test_shadow_copy_name(void) {
    char a[64], a_again[64], b[64], no_ext[64], upper[64];
    int i;
    CHECK(spdf_win_watcher_shadow_copy_name("c:\\docs\\manual.pdf", a, sizeof(a)));
    CHECK(spdf_win_watcher_shadow_copy_name("c:\\docs\\manual.pdf", a_again, sizeof(a_again)));
    CHECK(spdf_win_watcher_shadow_copy_name("c:\\docs\\other.pdf", b, sizeof(b)));
    CHECK(spdf_win_watcher_shadow_copy_name("c:\\docs\\manual", no_ext, sizeof(no_ext)));
    CHECK(spdf_win_watcher_shadow_copy_name("/docs/SHEET.PDF", upper, sizeof(upper)));
    /* Deterministic: an unchanged source reclaims the same copy across launches. */
    CHECK_STR(a, a_again);
    CHECK(strcmp(a, b) != 0);
    /* Format: ro-<32 hex>.<ext>; a missing extension defaults to pdf; the
     * extension is kept as it is. */
    CHECK(strncmp(a, "ro-", 3) == 0);
    CHECK(strlen(a) == 3 + 32 + 1 + 3);
    CHECK(strcmp(a + strlen(a) - 4, ".pdf") == 0);
    CHECK(strcmp(no_ext + strlen(no_ext) - 4, ".pdf") == 0);
    CHECK(strcmp(upper + strlen(upper) - 4, ".PDF") == 0);
    for (i = 3; i < 3 + 32; ++i) CHECK((a[i] >= '0' && a[i] <= '9') || (a[i] >= 'a' && a[i] <= 'f'));
    /* The digest IS SHA-256 of the path bytes: "/docs/Manual.pdf" -> known prefix. */
    {
        unsigned char d[32];
        char hex[65], name[64];
        spdf_win_watcher_sha256((const unsigned char*)"/docs/Manual.pdf", strlen("/docs/Manual.pdf"), d);
        hex_of(d, 16, hex);
        CHECK(spdf_win_watcher_shadow_copy_name("/docs/Manual.pdf", name, sizeof(name)));
        CHECK(strncmp(name + 3, hex, 32) == 0);
    }
    CHECK(!spdf_win_watcher_shadow_copy_name(NULL, a, sizeof(a)));
    CHECK(!spdf_win_watcher_shadow_copy_name("", a, sizeof(a)));
    CHECK(!spdf_win_watcher_shadow_copy_name("c:\\x.pdf", a, 20));
    CHECK_STR(spdf_win_watcher_extension("c:\\docs\\a.tar.gz"), "gz");
    CHECK_STR(spdf_win_watcher_extension("c:\\docs.v2\\a"), "");
    CHECK_STR(spdf_win_watcher_extension("c:\\docs\\.hidden"), "");
    CHECK_STR(spdf_win_watcher_extension("c:\\docs\\trailing."), "");
}

static void test_path_is_shadow_in(void) {
    const char* dir = "c:\\users\\u\\appdata\\roaming\\shenzhenpdf\\readonlycopies";
    char name[64], good[256], nested[256], elsewhere[256];
    CHECK(spdf_win_watcher_shadow_copy_name("c:\\docs\\manual.pdf", name, sizeof(name)));
    snprintf(good, sizeof(good), "%s\\%s", dir, name);
    snprintf(nested, sizeof(nested), "%s\\sub\\%s", dir, name);
    snprintf(elsewhere, sizeof(elsewhere), "c:\\tmp\\%s", name);
    CHECK(spdf_win_watcher_path_is_shadow_in(good, dir));
    /* A trailing separator on the directory is tolerated. */
    CHECK(spdf_win_watcher_path_is_shadow_in(good, "c:\\users\\u\\appdata\\roaming\\shenzhenpdf\\readonlycopies\\"));
    CHECK(!spdf_win_watcher_path_is_shadow_in(nested, dir));
    CHECK(!spdf_win_watcher_path_is_shadow_in(elsewhere, dir));
    CHECK(!spdf_win_watcher_path_is_shadow_in("c:\\users\\u\\appdata\\roaming\\shenzhenpdf\\readonlycopies\\x.pdf", dir));
    CHECK(!spdf_win_watcher_path_is_shadow_in("c:\\users\\u\\appdata\\roaming\\shenzhenpdf\\readonlycopies\\ro-zz.pdf", dir));
    CHECK(!spdf_win_watcher_path_is_shadow_in(
        "c:\\users\\u\\appdata\\roaming\\shenzhenpdf\\readonlycopies\\ro-0123456789abcdef0123456789abcdef", dir));
    CHECK(!spdf_win_watcher_path_is_shadow_in("c:\\users\\u\\appdata\\roaming\\shenzhenpdf\\readonlycopiesx\\ro-0123456789abcdef0123456789abcdef.pdf", dir));
    CHECK(!spdf_win_watcher_path_is_shadow_in(NULL, dir));
    CHECK(!spdf_win_watcher_path_is_shadow_in(good, NULL));
    CHECK(!spdf_win_watcher_path_is_shadow_in("", dir));
}

static void test_read_only_verdict(void) {
    CHECK(spdf_win_watcher_read_only_verdict(1, 1, 0));
    CHECK(!spdf_win_watcher_read_only_verdict(1, 1, 1));
    CHECK(!spdf_win_watcher_read_only_verdict(0, 0, 0));
    CHECK(!spdf_win_watcher_read_only_verdict(1, 0, 0));
    CHECK(!spdf_win_watcher_read_only_verdict(1, 0, 1));
}

static void test_stat_and_reuse_and_sweep(void) {
    const double now = 10000.0;
    CHECK(!spdf_win_watcher_stat_differs(100, 5.0, 100, 5.0));
    CHECK(!spdf_win_watcher_stat_differs(100, 5.0, 100, 5.0 + SPDF_WIN_WATCHER_MTIME_TOLERANCE / 2));
    CHECK(spdf_win_watcher_stat_differs(100, 5.0, 100, 5.0 + SPDF_WIN_WATCHER_MTIME_TOLERANCE * 2));
    CHECK(spdf_win_watcher_stat_differs(100, 5.0, 101, 5.0));
    CHECK(spdf_win_watcher_copy_reusable(1, 100, 5.0, 100, 5.0));
    CHECK(spdf_win_watcher_copy_reusable(1, 100, 5.0, 100, 5.0 + SPDF_WIN_WATCHER_MTIME_TOLERANCE / 2));
    CHECK(!spdf_win_watcher_copy_reusable(0, 100, 5.0, 100, 5.0));
    CHECK(!spdf_win_watcher_copy_reusable(1, 0, 0.0, 100, 5.0));
    CHECK(!spdf_win_watcher_copy_reusable(1, 100, 5.0, 100, 9.0));
    CHECK(!spdf_win_watcher_copy_reusable(1, 100, 5.0, 250, 5.0));
    CHECK(!spdf_win_watcher_sweep_should_delete(1, now - 3600.0, now));
    CHECK(spdf_win_watcher_sweep_should_delete(0, now - 3600.0, now));
    CHECK(!spdf_win_watcher_sweep_should_delete(0, now - SPDF_WIN_WATCHER_SWEEP_RECENCY_S / 2, now));
    CHECK(!spdf_win_watcher_sweep_should_delete(0, now, now));
}

int main(void) {
    test_debounce_coalesce();
    test_sha256_vectors();
    test_shadow_copy_name();
    test_path_is_shadow_in();
    test_read_only_verdict();
    test_stat_and_reuse_and_sweep();
    printf("watcher_logic_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
