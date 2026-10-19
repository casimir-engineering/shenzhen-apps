/* spdf_win_translate_run.cpp -- the runners of spdf_win_translate.h: one text
 * through Argos (the selection panel, synchronous on a worker), and the
 * whole-document job -- per-line text through the core, whole pages batched
 * through Argos spawns, "<stem>_<lang>.pdf" written with the translated text
 * overlaid per line plus chapter titles and comments
 * (spdf_save_translated_copy_full), cancellable between and during spawns.
 *
 * Port of translate_doc_thread / translate_collect_items / translate_run_argos
 * in portable/linux/gtk4/spdf_translate.c, without the cairo fallback (see the
 * header). */
#include "spdf_win_translate.h"

#include <windows.h>

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "shenzhen_pdf_core.h"

#define MAX_TRANSLATE_TEXT_BYTES (16 * 1024 * 1024) /* GTK3 cap */

/* --- one text through Argos ---------------------------------------------------- */

static size_t scripts_env(const char* scripts_dir, char* env, size_t cap) {
    size_t n;
    if (!scripts_dir || !*scripts_dir || cap < 8) {
        if (cap >= 2) env[0] = env[1] = '\0';
        return cap >= 2 ? 1 : 0;
    }
    n = (size_t)snprintf(env, cap, "PATH=%s", scripts_dir);
    if (n + 2 > cap) {
        env[0] = env[1] = '\0';
        return 1;
    }
    env[n + 1] = '\0';
    return n + 2;
}

int spdf_win_translate_text(const char* argos_path, const char* scripts_dir, const char* from_lang, const char* to_lang,
                            const char* text, void* cancel, char** translated_out, char* err, size_t err_len) {
    char cmd[SPDF_WIN_TC_CMD], env[SPDF_WIN_TC_ENV];
    char* out = NULL;
    char* errs = NULL;
    SpdfWinToolchainRun run;
    int rc;

    if (translated_out) *translated_out = NULL;
    if (err && err_len) err[0] = '\0';
    if (!argos_path || !*argos_path || !from_lang || !to_lang || !text) {
        if (err) snprintf(err, err_len, "Argos Translate is not available.");
        return 0;
    }
    spdf_win_translate_argos_cmd(argos_path, from_lang, to_lang, cmd, sizeof(cmd));
    scripts_env(scripts_dir, env, sizeof(env));
    memset(&run, 0, sizeof(run));
    run.command_line = cmd;
    run.env_prepend = env;
    run.stdin_text = text;
    run.cancel = cancel;
    run.stdout_out = &out;
    run.stderr_out = &errs;
    rc = spdf_win_toolchain_run_capture(&run);
    if (rc == SPDF_WIN_TC_CANCELLED) {
        free(out);
        free(errs);
        if (err) snprintf(err, err_len, "Translation canceled.");
        return -1;
    }
    if (rc == SPDF_WIN_TC_SPAWN_FAILED) {
        if (err) snprintf(err, err_len, "Could not start Argos Translate: %s", run.error);
        free(out);
        free(errs);
        return 0;
    }
    if (rc != 0 || !out || !out[0]) {
        const char* detail = errs && *errs ? errs : out && *out ? out : "Argos Translate exited with an error.";
        if (err) snprintf(err, err_len, "%s", detail);
        free(out);
        free(errs);
        return 0;
    }
    {
        size_t n = strlen(out) + 1;
        char* cleaned = (char*)malloc(n);
        if (cleaned) spdf_win_toolchain_strip_argos_diagnostics(out, cleaned, n);
        free(out);
        free(errs);
        if (!cleaned) {
            if (err) snprintf(err, err_len, "out of memory");
            return 0;
        }
        if (translated_out) *translated_out = cleaned;
        else free(cleaned);
    }
    return 1;
}

/* --- the whole-document job ---------------------------------------------------- */

typedef struct doc_item {
    int kind; /* 0 body, 1 outline, 2 comment */
    int page;
    int index; /* outline pre-order index / visible comment index */
    spdf_rect bounds;
    float font_size;
} doc_item;

struct SpdfWinTranslateDocJob {
    SpdfWinTranslateDocCallbacks cb;
    char pdf_path[SPDF_WIN_TC_PATH];
    char output_path[SPDF_WIN_TC_PATH];
    char tmp_path[SPDF_WIN_TC_PATH];
    char from_lang[32];
    char to_lang[32];
    char argos[SPDF_WIN_TC_PATH];
    char scripts[SPDF_WIN_TC_PATH];
    HANDLE cancel;
    HANDLE thread;
    /* collected items */
    doc_item* items;
    char** src;
    int count, cap;
};

static void progress(SpdfWinTranslateDocJob* job, double fraction, const char* message) {
    if (job->cb.on_progress) job->cb.on_progress(fraction, message, job->cb.user);
    if (job->cb.on_line && message) job->cb.on_line(message, job->cb.user);
}

static int add_item(SpdfWinTranslateDocJob* job, const doc_item* item, char* text_owned) {
    if (job->count == job->cap) {
        int ncap = job->cap ? job->cap * 2 : 256;
        doc_item* ni = (doc_item*)realloc(job->items, sizeof(doc_item) * (size_t)ncap);
        char** ns = (char**)realloc(job->src, sizeof(char*) * (size_t)ncap);
        if (!ni || !ns) {
            free(ni);
            free(ns);
            free(text_owned);
            return 0;
        }
        job->items = ni;
        job->src = ns;
        job->cap = ncap;
    }
    job->items[job->count] = *item;
    job->src[job->count] = text_owned;
    job->count++;
    return 1;
}

static char* collapsed_dup(const char* text) {
    size_t n = text ? strlen(text) + 1 : 1;
    char* out = (char*)malloc(n);
    if (out) spdf_win_translate_collapse_whitespace(text, out, n);
    return out;
}

/* Body lines page by page, then outline titles, then comments -- each through
 * the core's per-item translate/skip filter (78072bf55). */
static int collect_items(SpdfWinTranslateDocJob* job, char* message, size_t message_len) {
    char err[1024] = "";
    spdf_document* doc = spdf_open(job->pdf_path, err, sizeof(err));
    spdf_translation_script source = spdf_translation_script_for_language(job->from_lang);
    spdf_translation_script target = spdf_translation_script_for_language(job->to_lang);
    spdf_outline outline;
    spdf_comments comments;
    int page_count;

    if (!doc) {
        snprintf(message, message_len, "%s", err[0] ? err : "Could not open document for translation.");
        return 0;
    }
    page_count = spdf_page_count(doc);
    for (int page = 0; page < page_count; ++page) {
        spdf_text_lines lines;
        memset(&lines, 0, sizeof(lines));
        if (WaitForSingleObject(job->cancel, 0) == WAIT_OBJECT_0) {
            spdf_close(doc);
            return -1;
        }
        if (!spdf_extract_page_text_lines(doc, page, &lines, err, sizeof(err))) {
            snprintf(message, message_len, "Could not extract text from page %d: %s", page + 1,
                     err[0] ? err : "Unknown error");
            spdf_free_text_lines(&lines);
            spdf_close(doc);
            return 0;
        }
        for (int i = 0; i < lines.count; ++i) {
            doc_item item;
            const char* text = lines.items[i].text;
            if (!text || !*text || !spdf_translation_should_translate(text, source, target)) continue;
            item.kind = 0;
            item.page = page;
            item.index = -1;
            item.bounds = lines.items[i].bounds;
            item.font_size = lines.items[i].font_size;
            add_item(job, &item, _strdup(text));
        }
        spdf_free_text_lines(&lines);
    }
    memset(&outline, 0, sizeof(outline));
    if (spdf_load_outline(doc, &outline, err, sizeof(err))) {
        for (int i = 0; i < outline.count; ++i) {
            char* title = collapsed_dup(outline.items[i].title);
            doc_item item;
            if (!title || !*title || !spdf_translation_should_translate(title, source, target)) {
                free(title);
                continue;
            }
            memset(&item, 0, sizeof(item));
            item.kind = 1;
            item.page = page_count;
            item.index = i;
            add_item(job, &item, title);
        }
        spdf_free_outline(&outline);
    }
    memset(&comments, 0, sizeof(comments));
    if (spdf_load_comments(doc, &comments, err, sizeof(err))) {
        for (int i = 0; i < comments.count; ++i) {
            char* body = collapsed_dup(comments.items[i].text);
            doc_item item;
            if (!body || !*body || comments.items[i].index < 0 ||
                !spdf_translation_should_translate(body, source, target)) {
                free(body);
                continue;
            }
            memset(&item, 0, sizeof(item));
            item.kind = 2;
            item.page = page_count + 1;
            item.index = comments.items[i].index;
            add_item(job, &item, body);
        }
        spdf_free_comments(&comments);
    }
    spdf_close(doc);
    return 1;
}

static int write_translated(SpdfWinTranslateDocJob* job, char** result, char* message, size_t message_len) {
    char err[1024] = "";
    spdf_document* doc = spdf_open(job->pdf_path, err, sizeof(err));
    spdf_translated_line* lines;
    spdf_translated_text* titles;
    spdf_translated_text* bodies;
    char** retained;
    int line_count = 0, title_count = 0, body_count = 0, ok;

    if (!doc) {
        snprintf(message, message_len, "%s", err[0] ? err : "Could not reopen document to save translation.");
        return 0;
    }
    lines = (spdf_translated_line*)calloc((size_t)job->count + 1, sizeof(*lines));
    titles = (spdf_translated_text*)calloc((size_t)job->count + 1, sizeof(*titles));
    bodies = (spdf_translated_text*)calloc((size_t)job->count + 1, sizeof(*bodies));
    retained = (char**)calloc((size_t)job->count + 1, sizeof(char*));
    if (!lines || !titles || !bodies || !retained) {
        snprintf(message, message_len, "out of memory");
        ok = 0;
        goto out;
    }
    for (int i = 0; i < job->count; ++i) {
        const doc_item* item = &job->items[i];
        const char* text = result[i] && result[i][0] ? result[i] : " ";
        if (item->kind == 1) {
            char* title = collapsed_dup(text);
            if (!title || !*title) {
                free(title);
                continue;
            }
            retained[i] = title;
            titles[title_count].index = item->index;
            titles[title_count].text = title;
            title_count++;
        } else if (item->kind == 2) {
            char* body = collapsed_dup(text);
            if (!body || !*body) {
                free(body);
                continue;
            }
            retained[i] = body;
            bodies[body_count].index = item->index;
            bodies[body_count].text = body;
            body_count++;
        } else {
            lines[line_count].page_index = item->page;
            lines[line_count].bounds = item->bounds;
            lines[line_count].font_size = item->font_size;
            lines[line_count].opaque_background = SPDF_TRANSLATION_BACKGROUND_OPAQUE;
            lines[line_count].text = text;
            line_count++;
        }
    }
    ok = spdf_save_translated_copy_full(doc, job->tmp_path, lines, line_count, titles, title_count, bodies, body_count,
                                        err, sizeof(err));
    if (!ok) snprintf(message, message_len, "%s", err[0] ? err : "Could not write translated PDF.");
out:
    spdf_close(doc);
    for (int i = 0; retained && i < job->count; ++i) free(retained[i]);
    free(retained);
    free(lines);
    free(titles);
    free(bodies);
    return ok;
}

static void finish(SpdfWinTranslateDocJob* job, int success, int cancelled, const char* message) {
    wchar_t w[SPDF_WIN_TC_PATH];
    if (!success && MultiByteToWideChar(CP_UTF8, 0, job->tmp_path, -1, w, SPDF_WIN_TC_PATH)) DeleteFileW(w);
    if (job->cb.on_done) job->cb.on_done(success, cancelled, message, success ? job->output_path : "", job->cb.user);
}

static DWORD WINAPI doc_thread(LPVOID param) {
    SpdfWinTranslateDocJob* job = (SpdfWinTranslateDocJob*)param;
    char message[2048] = "";
    char** result = NULL;
    SpdfWinTranslateBatchItem* batch = NULL;
    size_t total = 0;
    int rc, start = 0;

    progress(job, 0.02, "Extracting document text...");
    rc = collect_items(job, message, sizeof(message));
    if (rc < 0) {
        finish(job, 0, 1, "Translation canceled.");
        return 0;
    }
    if (!rc) {
        finish(job, 0, 0, message);
        return 0;
    }
    if (job->count == 0) {
        finish(job, 0, 0,
               "No text block, chapter title or comment in this document needs translation for the selected languages.");
        return 0;
    }
    for (int i = 0; i < job->count; ++i) total += strlen(job->src[i]) + 1;
    if (total > MAX_TRANSLATE_TEXT_BYTES) {
        finish(job, 0, 0, "The extracted text is too large to translate in this build.");
        return 0;
    }
    result = (char**)calloc((size_t)job->count, sizeof(char*));
    batch = (SpdfWinTranslateBatchItem*)calloc((size_t)job->count, sizeof(*batch));
    if (!result || !batch) {
        free(result);
        free(batch);
        finish(job, 0, 0, "out of memory");
        return 0;
    }
    for (int i = 0; i < job->count; ++i) {
        batch[i].kind = job->items[i].kind;
        batch[i].page = job->items[i].page;
    }
    while (start < job->count) {
        int end = spdf_win_translate_batch_end(batch, job->count, start, SPDF_WIN_TRANSLATE_BATCH_LINE_BUDGET);
        char scope[96], text[256], err[2048];
        char* input;
        char* translated = NULL;
        size_t len = 0, at = 0;
        int ok;

        if (WaitForSingleObject(job->cancel, 0) == WAIT_OBJECT_0) {
            snprintf(message, sizeof(message), "Translation canceled.");
            rc = -1;
            break;
        }
        spdf_win_translate_batch_scope(batch, job->count, start, end, scope, sizeof(scope));
        snprintf(text, sizeof(text), "Translating %s (%d of %d text items)...", scope, start, job->count);
        progress(job, 0.05 + 0.85 * ((double)start / (job->count > 0 ? job->count : 1)), text);
        for (int i = start; i < end; ++i) len += strlen(job->src[i]) + 1;
        input = (char*)malloc(len + 1);
        if (!input) {
            snprintf(message, sizeof(message), "out of memory");
            rc = 0;
            break;
        }
        for (int i = start; i < end; ++i) {
            size_t n = strlen(job->src[i]);
            memcpy(input + at, job->src[i], n);
            at += n;
            input[at++] = '\n';
        }
        input[at] = '\0';
        ok = spdf_win_translate_text(job->argos, job->scripts, job->from_lang, job->to_lang, input, job->cancel,
                                     &translated, err, sizeof(err));
        free(input);
        if (ok < 0) {
            snprintf(message, sizeof(message), "Translation canceled.");
            rc = -1;
            break;
        }
        if (!ok) {
            /* "Page 3: ..." / "Chapter titles: ..." prefix, as GTK and Mac. */
            if (scope[0]) scope[0] = (char)toupper((unsigned char)scope[0]);
            snprintf(message, sizeof(message), "%s: %s", scope, err);
            rc = 0;
            break;
        }
        spdf_win_translate_apply_batch_output(result, start, end, translated);
        free(translated);
        start = end;
        snprintf(text, sizeof(text), "Translated %s (%d of %d text items).", scope, start, job->count);
        progress(job, 0.05 + 0.85 * ((double)start / job->count), text);
        rc = 1;
    }
    if (rc > 0) {
        progress(job, 0.93, "Writing translated PDF...");
        rc = write_translated(job, result, message, sizeof(message));
    }
    if (rc > 0) {
        wchar_t wsrc[SPDF_WIN_TC_PATH], wdst[SPDF_WIN_TC_PATH];
        if (!MultiByteToWideChar(CP_UTF8, 0, job->tmp_path, -1, wsrc, SPDF_WIN_TC_PATH) ||
            !MultiByteToWideChar(CP_UTF8, 0, job->output_path, -1, wdst, SPDF_WIN_TC_PATH) ||
            !MoveFileExW(wsrc, wdst, MOVEFILE_REPLACE_EXISTING | MOVEFILE_COPY_ALLOWED)) {
            snprintf(message, sizeof(message), "Could not move translated PDF into place (%lu).",
                     (unsigned long)GetLastError());
            rc = 0;
        }
    }
    for (int i = 0; i < job->count; ++i) free(result[i]);
    free(result);
    free(batch);
    if (rc > 0) {
        progress(job, 1.0, "Translation complete.");
        finish(job, 1, 0, "Translated document written.");
    } else {
        finish(job, 0, rc < 0, message);
    }
    return 0;
}

SpdfWinTranslateDocJob* spdf_win_translate_doc_start(const SpdfWinTranslateDocRequest* req,
                                                     const SpdfWinTranslateDocCallbacks* callbacks) {
    SpdfWinTranslateDocJob* job;
    if (!req || !req->pdf_path || !req->from_lang || !req->to_lang || !req->argos_path) return NULL;
    job = (SpdfWinTranslateDocJob*)calloc(1, sizeof(*job));
    if (!job) return NULL;
    if (callbacks) job->cb = *callbacks;
    snprintf(job->pdf_path, sizeof(job->pdf_path), "%s", req->pdf_path);
    snprintf(job->from_lang, sizeof(job->from_lang), "%s", req->from_lang);
    snprintf(job->to_lang, sizeof(job->to_lang), "%s", req->to_lang);
    snprintf(job->argos, sizeof(job->argos), "%s", req->argos_path);
    snprintf(job->scripts, sizeof(job->scripts), "%s", req->scripts_dir ? req->scripts_dir : "");
    if (!spdf_win_translate_output_path(req->pdf_path, req->to_lang, job->output_path, sizeof(job->output_path)) ||
        !spdf_win_translate_temp_path(req->pdf_path, (unsigned)GetTickCount() ^ (unsigned)GetCurrentProcessId(),
                                      job->tmp_path, sizeof(job->tmp_path))) {
        free(job);
        return NULL;
    }
    job->cancel = CreateEventW(NULL, TRUE, FALSE, NULL);
    job->thread = CreateThread(NULL, 0, doc_thread, job, 0, NULL);
    if (!job->thread) {
        CloseHandle(job->cancel);
        free(job);
        return NULL;
    }
    return job;
}

void spdf_win_translate_doc_cancel(SpdfWinTranslateDocJob* job) {
    if (job && job->cancel) SetEvent(job->cancel);
}

void spdf_win_translate_doc_free(SpdfWinTranslateDocJob* job) {
    if (!job) return;
    if (job->thread) {
        WaitForSingleObject(job->thread, INFINITE);
        CloseHandle(job->thread);
    }
    if (job->cancel) CloseHandle(job->cancel);
    for (int i = 0; i < job->count; ++i) free(job->src[i]);
    free(job->src);
    free(job->items);
    free(job);
}
