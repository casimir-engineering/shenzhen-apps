/* spdf_win_ocr.cpp -- OCR: the pure half (table, command line, verdict,
 * naming, environment) and the worker that runs OCRmyPDF, validates its output
 * with the core, retries image-only scans once with --force-ocr and leaves the
 * confirmed result beside the original for the host to swap in. Contract and
 * GTK provenance in spdf_win_ocr.h. */
#include "spdf_win_ocr.h"

#include <windows.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "shenzhen_pdf_core.h"

/* ===========================================================================
 * Pure half (portable/win/tests/ocr_test.c).
 * ======================================================================== */

/* GTK3 OCR_LANGUAGE_OPTIONS / Mac spdf_ocr_languages(), verbatim. */
static const SpdfWinOcrLanguage k_languages[] = {
    {"chi_sim+eng", "Chinese Simplified + English"},
    {"chi_sim", "Chinese Simplified"},
    {"chi_tra+eng", "Chinese Traditional + English"},
    {"chi_tra", "Chinese Traditional"},
    {"eng", "English"},
    /* Top 10 most-spoken languages by total speakers (English and Mandarin above). */
    {"hin", "Hindi"},
    {"spa", "Spanish"},
    {"fra", "French"},
    {"ara", "Arabic"},
    {"ben", "Bengali"},
    {"por", "Portuguese"},
    {"rus", "Russian"},
    {"urd", "Urdu"},
    /* Large European languages (English, Spanish, French, Portuguese, Russian above). */
    {"deu", "German"},
    {"ita", "Italian"},
    {"pol", "Polish"},
    {"ukr", "Ukrainian"},
    {"nld", "Dutch"},
    {"ron", "Romanian"},
};
#define LANGUAGE_COUNT ((int)(sizeof(k_languages) / sizeof(k_languages[0])))

const SpdfWinOcrLanguage* spdf_win_ocr_languages(int* count) {
    if (count) *count = LANGUAGE_COUNT;
    return k_languages;
}

int spdf_win_ocr_language_index(const char* code) {
    if (!code || !*code) return -1;
    for (int i = 0; i < LANGUAGE_COUNT; ++i)
        if (strcmp(k_languages[i].code, code) == 0) return i;
    return -1;
}

size_t spdf_win_ocr_command(const char* tool, int via_python, const char* language, unsigned jobs, int has_text,
                            int force_ocr, const char* input_path, const char* output_path, char* out,
                            size_t out_bytes) {
    const char* argv[20];
    char jobs_text[16];
    int argc = 0;
    argv[argc++] = tool;
    if (via_python) {
        argv[argc++] = "-m";
        argv[argc++] = "ocrmypdf";
    }
    snprintf(jobs_text, sizeof(jobs_text), "%u", jobs > 0 ? jobs : 1u);
    argv[argc++] = "--jobs";
    argv[argc++] = jobs_text;
    argv[argc++] = "--rotate-pages";
    argv[argc++] = "--optimize";
    argv[argc++] = "1";
    argv[argc++] = "-l";
    argv[argc++] = language;
    if (!has_text) {
        argv[argc++] = "--deskew";
        if (force_ocr) argv[argc++] = "--force-ocr";
    } else {
        argv[argc++] = "--redo-ocr";
    }
    argv[argc++] = input_path;
    argv[argc++] = output_path;
    return spdf_win_toolchain_join_argv(argv, argc, out, out_bytes);
}

spdf_win_ocr_verdict spdf_win_ocr_validation_verdict(int run_ok, int output_has_text, int input_had_text, int forced) {
    if (!run_ok) return SPDF_WIN_OCR_FAIL_ERROR;
    if (output_has_text > 0) return SPDF_WIN_OCR_SWAP;
    if (output_has_text < 0) return SPDF_WIN_OCR_FAIL_ERROR;
    /* Completed but produced no selectable text. Image-only PDFs get one
     * forced retry (journal item 37); redo runs and forced runs fail. */
    if (!input_had_text && !forced) return SPDF_WIN_OCR_RETRY_FORCE;
    return SPDF_WIN_OCR_FAIL_NO_TEXT;
}

size_t spdf_win_ocr_failure_message(const char* detail, char* out, size_t out_bytes) {
    const char* text;
    if (!detail || !*detail) {
        text = "OCRmyPDF exited with an error.";
    } else if (strstr(detail, "--redo-ocr") && strstr(detail, "not compatible")) {
        text = "OCRmyPDF rejected --redo-ocr for this PDF or OCRmyPDF version.\n\n"
               "The PDF already has text, and this OCRmyPDF build cannot redo OCR on it. "
               "Try updating OCRmyPDF, or run OCR on a copy without existing text.";
    } else if (strstr(detail, "Traceback")) {
        text = "OCRmyPDF crashed while processing this PDF.\n\n"
               "This looks like an OCRmyPDF compatibility error. Try updating OCRmyPDF and "
               "Tesseract, or run OCRmyPDF from a terminal to see the full traceback.";
    } else {
        text = detail;
    }
    return (size_t)snprintf(out, out_bytes, "%s", text);
}

/* Split "<dir><sep><leaf>": dir_len counts the separator, so dir + leaf
 * reassembles the path with the same separator the caller used. */
static void split_leaf(const char* path, size_t* dir_len, const char** leaf) {
    const char* a = strrchr(path, '\\');
    const char* b = strrchr(path, '/');
    const char* sep = a > b ? a : b;
    *leaf = sep ? sep + 1 : path;
    *dir_len = sep ? (size_t)(sep - path + 1) : 0;
}

int spdf_win_ocr_backup_candidate(const char* path, int index, char* out, size_t out_bytes) {
    size_t dir_len;
    const char* leaf;
    const char* dot;
    const char* ext;
    int stem_len, n;
    if (!path || !*path) return 0;
    split_leaf(path, &dir_len, &leaf);
    dot = strrchr(leaf, '.');
    stem_len = dot ? (int)(dot - leaf) : (int)strlen(leaf);
    ext = dot && dot[1] ? dot + 1 : "pdf";
    if (index <= 0) n = snprintf(out, out_bytes, "%.*s%.*s_backup.%s", (int)dir_len, path, stem_len, leaf, ext);
    else n = snprintf(out, out_bytes, "%.*s%.*s_backup_%d.%s", (int)dir_len, path, stem_len, leaf, index + 1, ext);
    return n > 0 && (size_t)n < out_bytes;
}

int spdf_win_ocr_temp_path(const char* path, unsigned nonce, char* out, size_t out_bytes) {
    size_t dir_len;
    const char* leaf;
    int n;
    if (!path || !*path) return 0;
    split_leaf(path, &dir_len, &leaf);
    n = snprintf(out, out_bytes, "%.*s.%s.ocr-%u.pdf", (int)dir_len, path, leaf, nonce);
    return n > 0 && (size_t)n < out_bytes;
}

size_t spdf_win_ocr_env(const char* tesseract_dir, const char* gs_dir, const char* scripts_dir,
                        const char* tessdata_dir, char* out, size_t out_bytes) {
    const char* tessdata_parent = tessdata_dir; /* the value, whatever level the caller chose */
    char path[SPDF_WIN_TC_ENV] = "PATH=";
    const char* dirs[3] = {tesseract_dir, gs_dir, scripts_dir};
    size_t at = 0, n;
    int any = 0;
    for (int i = 0; i < 3; ++i) {
        if (!dirs[i] || !*dirs[i]) continue;
        n = strlen(path);
        snprintf(path + n, sizeof(path) - n, "%s%s", any ? ";" : "", dirs[i]);
        any = 1;
    }
    if (out_bytes < 2) return 0;
    if (any) {
        n = strlen(path) + 1;
        if (at + n + 1 > out_bytes) return 0;
        memcpy(out + at, path, n);
        at += n;
    }
    if (tessdata_parent && *tessdata_parent) {
        n = strlen("TESSDATA_PREFIX=") + strlen(tessdata_parent) + 1;
        if (at + n + 1 > out_bytes) return 0;
        snprintf(out + at, out_bytes - at, "TESSDATA_PREFIX=%s", tessdata_parent);
        at += n;
    }
    out[at++] = '\0';
    return at;
}

/* ===========================================================================
 * The worker.
 * ======================================================================== */

struct SpdfWinOcrJob {
    SpdfWinOcrCallbacks cb;
    char pdf_path[SPDF_WIN_TC_PATH];
    char tmp_path[SPDF_WIN_TC_PATH];
    char language[64];
    char language_label[96];
    char env[SPDF_WIN_TC_ENV];
    char tool[SPDF_WIN_TC_PATH];
    int via_python;
    int input_has_text;
    int forced;
    HANDLE cancel;
    HANDLE thread;
};

static void status(SpdfWinOcrJob* job, const char* text) {
    if (job->cb.on_status) job->cb.on_status(text, job->cb.user);
    if (job->cb.on_line) job->cb.on_line(text, job->cb.user);
}

static void line_cb(const char* line, void* user) {
    SpdfWinOcrJob* job = (SpdfWinOcrJob*)user;
    if (job->cb.on_line) job->cb.on_line(line, job->cb.user);
}

static int wide(const char* utf8, wchar_t* out, int cap) { return MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out, cap) > 0; }

void spdf_win_ocr_discard(const char* output_path) {
    wchar_t w[SPDF_WIN_TC_PATH];
    if (output_path && *output_path && wide(output_path, w, SPDF_WIN_TC_PATH)) DeleteFileW(w);
}

/* Open the produced PDF with the core and ask whether any page has text:
 * -1 could not open/inspect, 0 no, 1 yes. Runs on the worker; the core allows
 * a document per thread and this one is ours alone. */
static int output_has_text(const char* path, char* err, size_t err_len) {
    spdf_document* doc = spdf_open(path, err, err_len);
    int has;
    if (!doc) return -1;
    has = spdf_document_has_text(doc, 0, err, err_len);
    spdf_close(doc);
    return has < 0 ? -1 : has;
}

static void finish(SpdfWinOcrJob* job, int success, int cancelled, const char* message) {
    if (!success) spdf_win_ocr_discard(job->tmp_path);
    if (job->cb.on_done) job->cb.on_done(success, cancelled, message, success ? job->tmp_path : "", job->cb.user);
}

static DWORD WINAPI ocr_thread(LPVOID param) {
    SpdfWinOcrJob* job = (SpdfWinOcrJob*)param;
    char text[1024];
    unsigned jobs = spdf_win_toolchain_cpu_count();

    snprintf(text, sizeof(text), "OCR running (%s), %u job%s...", job->language_label[0] ? job->language_label : job->language,
             jobs, jobs == 1 ? "" : "s");
    status(job, text);
    for (;;) {
        char cmd[SPDF_WIN_TC_CMD], err[512] = "";
        char* output = NULL;
        SpdfWinToolchainRun run;
        int rc, has;
        spdf_win_ocr_verdict verdict;

        spdf_win_ocr_discard(job->tmp_path);
        spdf_win_ocr_command(job->tool, job->via_python, job->language, jobs, job->input_has_text, job->forced,
                             job->pdf_path, job->tmp_path, cmd, sizeof(cmd));
        snprintf(text, sizeof(text), "> %s", cmd);
        line_cb(text, job);
        memset(&run, 0, sizeof(run));
        run.command_line = cmd;
        run.env_prepend = job->env;
        run.cancel = job->cancel;
        run.merge_stderr = 1;
        run.on_line = line_cb;
        run.user = job;
        run.stdout_out = &output;
        rc = spdf_win_toolchain_run_capture(&run);
        if (rc == SPDF_WIN_TC_CANCELLED) {
            free(output);
            finish(job, 0, 1, "OCR canceled.");
            return 0;
        }
        if (rc == SPDF_WIN_TC_SPAWN_FAILED) {
            snprintf(text, sizeof(text), "Could not start OCRmyPDF: %s", run.error);
            free(output);
            finish(job, 0, 0, text);
            return 0;
        }
        if (rc != 0) {
            char message[2048];
            spdf_win_ocr_failure_message(output, message, sizeof(message));
            free(output);
            finish(job, 0, 0, message);
            return 0;
        }
        free(output);

        /* Process success is not document success (journal item 37). */
        status(job, "Validating OCR output...");
        has = output_has_text(job->tmp_path, err, sizeof(err));
        verdict = spdf_win_ocr_validation_verdict(1, has, job->input_has_text, job->forced);
        switch (verdict) {
            case SPDF_WIN_OCR_SWAP:
                status(job, "OCR output contains selectable text.");
                finish(job, 1, 0, "OCR complete.");
                return 0;
            case SPDF_WIN_OCR_RETRY_FORCE:
                job->forced = 1;
                status(job, "No selectable text was detected; retrying with forced image OCR...");
                continue;
            case SPDF_WIN_OCR_FAIL_ERROR:
                snprintf(text, sizeof(text), "%s", err[0] ? err : "Could not inspect the OCR output.");
                finish(job, 0, 0, text);
                return 0;
            case SPDF_WIN_OCR_FAIL_NO_TEXT:
            default:
                finish(job, 0, 0,
                       "OCRmyPDF completed, but no selectable text was detected in the output PDF. "
                       "The original file was left unchanged.");
                return 0;
        }
    }
}

SpdfWinOcrJob* spdf_win_ocr_start(const SpdfWinOcrRequest* req, const SpdfWinOcrCallbacks* callbacks) {
    SpdfWinOcrJob* job;
    char tess_dir[SPDF_WIN_TC_PATH] = "", gs_dir[SPDF_WIN_TC_PATH] = "", parent[SPDF_WIN_TC_PATH] = "";
    const char* scripts = "";
    if (!req || !req->pdf_path || !req->language || !req->tools || !req->roots) return NULL;
    job = (SpdfWinOcrJob*)calloc(1, sizeof(*job));
    if (!job) return NULL;
    if (callbacks) job->cb = *callbacks;
    snprintf(job->pdf_path, sizeof(job->pdf_path), "%s", req->pdf_path);
    snprintf(job->language, sizeof(job->language), "%s", req->language);
    snprintf(job->language_label, sizeof(job->language_label), "%s", req->language_label ? req->language_label : "");
    job->input_has_text = req->input_has_text;
    spdf_win_ocr_temp_path(req->pdf_path, (unsigned)GetTickCount() ^ (unsigned)GetCurrentProcessId(), job->tmp_path,
                           sizeof(job->tmp_path));
    /* The console script when it exists, else the module through python. */
    if (spdf_win_toolchain_has(req->tools, SPDF_WIN_TOOL_OCRMYPDF)) {
        snprintf(job->tool, sizeof(job->tool), "%s", req->tools->path[SPDF_WIN_TOOL_OCRMYPDF]);
    } else if (spdf_win_toolchain_has(req->tools, SPDF_WIN_TOOL_PYTHON)) {
        snprintf(job->tool, sizeof(job->tool), "%s", req->tools->path[SPDF_WIN_TOOL_PYTHON]);
        job->via_python = 1;
    } else {
        free(job);
        return NULL;
    }
    if (spdf_win_toolchain_has(req->tools, SPDF_WIN_TOOL_TESSERACT))
        spdf_win_toolchain_dirname(req->tools->path[SPDF_WIN_TOOL_TESSERACT], tess_dir, sizeof(tess_dir));
    if (spdf_win_toolchain_has(req->tools, SPDF_WIN_TOOL_GHOSTSCRIPT))
        spdf_win_toolchain_dirname(req->tools->path[SPDF_WIN_TOOL_GHOSTSCRIPT], gs_dir, sizeof(gs_dir));
    if (req->roots->user_scripts[0]) scripts = req->roots->user_scripts;
    /* TESSDATA_PREFIX replaces tesseract's search path, so the downloaded-data
     * directory is completed with what tesseract ships before it is named. */
    if (spdf_win_toolchain_tessdata_complete(req->roots, req->tools->path[SPDF_WIN_TOOL_TESSERACT], req->language,
                                             parent, sizeof(parent))) {
        /* Tesseract 4+: TESSDATA_PREFIX names the tessdata directory itself,
         * not its parent as Tesseract 3 (and the GTK port's variable) did --
         * it looked for <parent>/osd.traineddata and found nothing. */
        size_t n = strlen(parent);
        snprintf(parent + n, sizeof(parent) - n, "\\tessdata");
    } else {
        parent[0] = '\0';
    }
    spdf_win_ocr_env(tess_dir, gs_dir, scripts, parent, job->env, sizeof(job->env));
    job->cancel = CreateEventW(NULL, TRUE, FALSE, NULL);
    job->thread = CreateThread(NULL, 0, ocr_thread, job, 0, NULL);
    if (!job->thread) {
        CloseHandle(job->cancel);
        free(job);
        return NULL;
    }
    return job;
}

void spdf_win_ocr_cancel(SpdfWinOcrJob* job) {
    if (job && job->cancel) SetEvent(job->cancel);
}

void spdf_win_ocr_free(SpdfWinOcrJob* job) {
    if (!job) return;
    if (job->thread) {
        WaitForSingleObject(job->thread, INFINITE);
        CloseHandle(job->thread);
    }
    if (job->cancel) CloseHandle(job->cancel);
    free(job);
}

/* --- the host's two file operations ---------------------------------------- */

int spdf_win_ocr_write_backup(const char* pdf_path, char* backup_out, size_t out_bytes, char* err, size_t err_len) {
    wchar_t wsrc[SPDF_WIN_TC_PATH], wdst[SPDF_WIN_TC_PATH];
    if (!wide(pdf_path, wsrc, SPDF_WIN_TC_PATH)) return 0;
    for (int index = 0; index < 1000; ++index) {
        if (!spdf_win_ocr_backup_candidate(pdf_path, index, backup_out, out_bytes) ||
            !wide(backup_out, wdst, SPDF_WIN_TC_PATH))
            break;
        if (GetFileAttributesW(wdst) != INVALID_FILE_ATTRIBUTES) continue; /* taken: try _2, _3... */
        if (CopyFileW(wsrc, wdst, TRUE)) return 1;
        snprintf(err, err_len, "Could not create OCR backup (%lu).", (unsigned long)GetLastError());
        return 0;
    }
    snprintf(err, err_len, "Could not find a free backup name.");
    return 0;
}

int spdf_win_ocr_install_output(const char* output_path, const char* pdf_path, char* err, size_t err_len) {
    wchar_t wsrc[SPDF_WIN_TC_PATH], wdst[SPDF_WIN_TC_PATH];
    DWORD last = 0;
    if (!wide(output_path, wsrc, SPDF_WIN_TC_PATH) || !wide(pdf_path, wdst, SPDF_WIN_TC_PATH)) return 0;
    /* An antivirus scanner commonly holds a freshly written PDF for a moment;
     * a sharing violation right after the write is transient, so retry. */
    for (int attempt = 0; attempt < 10; ++attempt) {
        if (MoveFileExW(wsrc, wdst, MOVEFILE_REPLACE_EXISTING | MOVEFILE_COPY_ALLOWED | MOVEFILE_WRITE_THROUGH))
            return 1;
        last = GetLastError();
        if (last != ERROR_SHARING_VIOLATION && last != ERROR_ACCESS_DENIED && last != ERROR_LOCK_VIOLATION) break;
        Sleep(200);
    }
    snprintf(err, err_len, "Could not install OCR output over the original (%lu).", (unsigned long)last);
    return 0;
}
