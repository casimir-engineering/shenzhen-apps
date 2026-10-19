/* spdf_win_toolchain_cmd.cpp -- the command lines the installer and the jobs
 * run: argument quoting per CommandLineToArgvW, the winget / pip / curl /
 * argospm lines, and the per-user tessdata directory. Pure strings;
 * portable/win/tests/toolchain_test.c pins every function. Split from
 * spdf_win_toolchain.cpp at the 500-line cap. */
#include "spdf_win_toolchain.h"
#include "spdf_win_toolchain_internal.h"

#include <stdio.h>
#include <string.h>

/* --- command lines ---------------------------------------------------------- */

size_t spdf_win_toolchain_quote_arg(const char* arg, char* out, size_t out_bytes) {
    size_t at = 0;
    int needs = !arg || !*arg;
    for (const char* p = arg ? arg : ""; *p && !needs; ++p)
        if (*p == ' ' || *p == '\t' || *p == '"') needs = 1;
    if (!needs) return put(out, out_bytes, 0, arg);
    at = put(out, out_bytes, at, "\"");
    {
        size_t backslashes = 0;
        for (const char* p = arg ? arg : ""; *p; ++p) {
            char one[2] = {*p, 0};
            if (*p == '\\') {
                ++backslashes;
                at = put(out, out_bytes, at, one);
                continue;
            }
            if (*p == '"') {
                /* CommandLineToArgvW: backslashes before a quote are doubled,
                 * then the quote itself is escaped. */
                for (size_t i = 0; i < backslashes + 1; ++i) at = put(out, out_bytes, at, "\\");
            }
            backslashes = 0;
            at = put(out, out_bytes, at, one);
        }
        for (size_t i = 0; i < backslashes; ++i) at = put(out, out_bytes, at, "\\");
    }
    return put(out, out_bytes, at, "\"");
}

size_t spdf_win_toolchain_join_argv(const char* const* argv, int argc, char* out, size_t out_bytes) {
    size_t at = 0;
    char q[SPDF_WIN_TC_CMD];
    for (int i = 0; i < argc; ++i) {
        if (i) at = put(out, out_bytes, at, " ");
        spdf_win_toolchain_quote_arg(argv[i], q, sizeof(q));
        at = put(out, out_bytes, at, q);
    }
    return at;
}

size_t spdf_win_toolchain_winget_cmd(const char* winget, const char* id, int user_scope, char* out, size_t out_bytes) {
    const char* argv[10] = {winget, "install", "--id", id, "-e", "--accept-source-agreements",
                            "--accept-package-agreements", "--disable-interactivity", "--scope", "user"};
    return spdf_win_toolchain_join_argv(argv, user_scope ? 10 : 8, out, out_bytes);
}

size_t spdf_win_toolchain_pip_cmd(const char* python, int user_site, const char* const* packages, int count,
                                  char* out, size_t out_bytes) {
    const char* argv[16] = {python, "-m", "pip", "install"};
    int argc = 4;
    if (user_site) argv[argc++] = "--user";
    argv[argc++] = "--upgrade";
    argv[argc++] = "--progress-bar";
    argv[argc++] = "off";
    for (int i = 0; i < count && argc < 16; ++i) argv[argc++] = packages[i];
    return spdf_win_toolchain_join_argv(argv, argc, out, out_bytes);
}

size_t spdf_win_toolchain_venv_cmd(const char* python, const char* dir, char* out, size_t out_bytes) {
    const char* argv[4] = {python, "-m", "venv", dir};
    return spdf_win_toolchain_join_argv(argv, 4, out, out_bytes);
}

int spdf_win_toolchain_argos_env_dir(const SpdfWinToolchainRoots* roots, char* out, size_t out_bytes) {
    return roots && out && join2(out, out_bytes, roots->user_profile, ".shenzhenpdf\\argos");
}

int spdf_win_toolchain_argos_env_python(const SpdfWinToolchainRoots* roots, char* out, size_t out_bytes) {
    return roots && out && join2(out, out_bytes, roots->user_profile, ".shenzhenpdf\\argos\\Scripts\\python.exe");
}

size_t spdf_win_toolchain_curl_cmd(const char* curl, const char* url, const char* dest, char* out, size_t out_bytes) {
    const char* argv[7] = {curl, "-L", "-f", "-sS", "-o", dest, url};
    return spdf_win_toolchain_join_argv(argv, 7, out, out_bytes);
}

size_t spdf_win_toolchain_argospm_cmd(const char* argospm, const char* from_lang, const char* to_lang, char* out,
                                      size_t out_bytes) {
    char package[96];
    const char* argv[3] = {argospm, "install", package};
    if (!spdf_win_toolchain_argos_package_name(from_lang, to_lang, package, sizeof(package))) return 0;
    return spdf_win_toolchain_join_argv(argv, 3, out, out_bytes);
}

int spdf_win_toolchain_tessdata_parent(const SpdfWinToolchainRoots* roots, char* out, size_t out_bytes) {
    return roots && out && join2(out, out_bytes, roots->user_profile, ".shenzhenpdf\\tesseract");
}

