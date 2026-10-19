#pragma once

/* Internal to spdf_win_search.cpp -- included by it, at the point where the
 * session struct is already complete, and by nobody else. Same arrangement and
 * the same reason as spdf_win_search_geometry.h beside it: the engine's file is
 * at its size cap and tools/file-size-limits.md asks for a focused file rather
 * than a raised one. What comes out here is the UI-THREAD API -- everything a
 * caller on the painting thread does to a session between frames -- while the
 * .cpp keeps the worker and the lifecycle, and the geometry header keeps the
 * two mappings to pixels.
 *
 * An internal header rather than a second translation unit precisely so the
 * session struct stays private to one .cpp.
 *
 * EVERY FUNCTION HERE IS UI-THREAD ONLY and none of them blocks: the lock is
 * taken only to move batches and titles the worker has already finished with,
 * and the list the accessors read is touched by no other thread.
 */

/* --- UI-thread API ------------------------------------------------------- */

static void reset_results(SpdfWinFindSession* s) {
    spdf_win_search_match_list_clear(&s->list);
    s->current = -1;
    s->mark_count = 0;
    s->active_mark = -1;
    s->page_mark_count = 0;
    s->error[0] = 0;
    s->started = 0;
    s->revision++;
    free_titles(s->titles, s->title_count);
    s->titles = NULL;
    s->title_count = 0;
    EnterCriticalSection(&s->lock);
    spdf_win_search_match_list_clear(&s->pending);
    s->pending_has_error = 0;
    s->pending_error[0] = 0;
    free_titles(s->pending_titles, s->pending_title_count);
    s->pending_titles = NULL;
    s->pending_title_count = 0;
    LeaveCriticalSection(&s->lock);
}

void spdf_win_find_set(SpdfWinFindSession* s, const char* utf8_path, const char* utf8_query, int regex) {
    Job* job;
    char* capped;
    HANDLE thread;
    int multiline = spdf_win_find_regex_multiline();

    if (!s) return;
    regex = regex ? 1 : 0;
    if (same_str(s->path, utf8_path) && same_str(s->query, utf8_query) && s->regex == regex &&
        s->regex_multiline == multiline)
        return;

    free(s->path);
    free(s->query);
    s->path = dup_str(utf8_path);
    s->query = dup_str(utf8_query);
    s->regex = regex;
    s->regex_multiline = multiline;

    InterlockedIncrement(&s->generation);
    reset_results(s);
    if (!s->path || !s->query || !s->query[0]) {
        InterlockedExchange(&s->finished_gen, InterlockedCompareExchange(&s->generation, 0, 0));
        return;
    }

    capped = spdf_win_search_dup_query(s->query);
    job = (Job*)calloc(1, sizeof(Job));
    if (!job || !capped) {
        free(capped);
        free(job);
        return;
    }
    job->session = s;
    job->generation = InterlockedCompareExchange(&s->generation, 0, 0);
    job->path = dup_str(s->path);
    job->query = capped;
    job->regex = regex;
    job->regex_multiline = multiline;
    if (!job->path) {
        free(job->query);
        free(job);
        return;
    }
    s->started = 1;
    InterlockedIncrement(&s->live_workers);
    thread = (HANDLE)_beginthreadex(NULL, 0, search_worker, job, 0, NULL);
    if (!thread) {
        InterlockedDecrement(&s->live_workers);
        s->started = 0;
        free(job->path);
        free(job->query);
        free(job);
        return;
    }
    CloseHandle(thread); /* detached: the generation counter is the join */
}

void spdf_win_find_restart(SpdfWinFindSession* s) {
    if (!s) return;
    /* Forgetting the path is what makes the next spdf_win_find_set() -- the
     * model builder calls it every paint -- see a changed input and rerun the
     * same query. The results go now rather than at that rerun, because they
     * describe pages that no longer look like that. */
    free(s->path);
    s->path = NULL;
    InterlockedIncrement(&s->generation);
    reset_results(s);
    InterlockedExchange(&s->finished_gen, InterlockedCompareExchange(&s->generation, 0, 0));
}

int spdf_win_find_poll(SpdfWinFindSession* s) {
    long gen;
    int changed = 0;
    if (!s) return 0;
    gen = InterlockedCompareExchange(&s->generation, 0, 0);
    EnterCriticalSection(&s->lock);
    if (s->pending_titles_gen == gen && s->pending_titles) {
        free_titles(s->titles, s->title_count);
        s->titles = s->pending_titles;
        s->title_count = s->pending_title_count;
        s->pending_titles = NULL;
        s->pending_title_count = 0;
        changed = 1;
    }
    if (s->pending_gen == gen) {
        if (spdf_win_search_match_list_count(&s->pending) > 0) {
            spdf_win_search_match_list_steal_into(&s->list, &s->pending);
            changed = 1;
        }
        if (s->pending_has_error) {
            s->pending_has_error = 0;
            strncpy(s->error, s->pending_error, sizeof(s->error) - 1);
            s->error[sizeof(s->error) - 1] = 0;
            spdf_win_search_match_list_clear(&s->list);
            s->current = -1;
            changed = 1;
        }
    }
    LeaveCriticalSection(&s->lock);
    if (changed) {
        /* Only pick a current match if the reader has not already stepped to
         * one: indices are stable because batches only append, so recomputing
         * would yank the view away from their choice (GTK4 deliver_idle). */
        if (s->current < 0 && spdf_win_search_match_list_count(&s->list) > 0) s->current = 0;
        s->revision++;
        rebuild_marks(s);
    }
    return changed;
}

int spdf_win_find_searching(const SpdfWinFindSession* s) {
    if (!s || !s->started) return 0;
    return InterlockedCompareExchange((volatile long*)&s->finished_gen, 0, 0) !=
           InterlockedCompareExchange((volatile long*)&s->generation, 0, 0);
}

int spdf_win_find_match_count(const SpdfWinFindSession* s) {
    return s ? (int)spdf_win_search_match_list_count(&s->list) : 0;
}

int spdf_win_find_match_index(const SpdfWinFindSession* s) { return s ? s->current : -1; }

const char* spdf_win_find_error(const SpdfWinFindSession* s) { return s && s->error[0] ? s->error : NULL; }

const char* spdf_win_find_query(const SpdfWinFindSession* s) { return s && s->query && s->query[0] ? s->query : NULL; }

unsigned spdf_win_find_revision(const SpdfWinFindSession* s) { return s ? s->revision : 0u; }

int spdf_win_find_step(SpdfWinFindSession* s, int delta) {
    int count;
    if (!s) return -1;
    count = (int)spdf_win_search_match_list_count(&s->list);
    if (count <= 0) return s->current = -1;
    if (s->current < 0) s->current = delta >= 0 ? 0 : count - 1;
    else {
        /* Wraparound, as GTK3 find_step does. The modulo is written so a
         * negative delta larger than count still lands in range. */
        s->current = ((s->current + delta) % count + count) % count;
    }
    s->revision++;
    rebuild_marks(s);
    return s->current;
}

int spdf_win_find_set_current(SpdfWinFindSession* s, int index) {
    int count;
    if (!s) return 0;
    count = (int)spdf_win_search_match_list_count(&s->list);
    if (index < 0 || index >= count || index == s->current) return 0;
    s->current = index;
    s->revision++;
    rebuild_marks(s);
    return 1;
}

int spdf_win_find_current_target(const SpdfWinFindSession* s, int* out_page, spdf_rect* out_rect) {
    const SpdfWinSearchMatch* m;
    if (!s || s->current < 0) return 0;
    m = spdf_win_search_match_list_get(&s->list, (unsigned)s->current);
    if (!m) return 0;
    if (out_page) *out_page = m->page;
    if (out_rect) *out_rect = m->rect;
    return 1;
}

int spdf_win_find_match_at(const SpdfWinFindSession* s, int index, SpdfWinFindMatchInfo* out) {
    const SpdfWinSearchMatch* m;
    if (!s || index < 0) return 0;
    m = spdf_win_search_match_list_get(&s->list, (unsigned)index);
    if (!m) return 0;
    if (out) {
        out->page = m->page;
        out->rect = m->rect;
        out->snippet = m->snippet ? m->snippet : "";
        out->chapter_index = m->chapter_index;
    }
    return 1;
}

int spdf_win_find_chapter_count(const SpdfWinFindSession* s) { return s ? s->title_count : 0; }

const char* spdf_win_find_chapter_title(const SpdfWinFindSession* s, int chapter_index) {
    if (!s || !s->titles || chapter_index < 0 || chapter_index >= s->title_count) return NULL;
    return s->titles[chapter_index] ? s->titles[chapter_index] : "";
}

const float* spdf_win_find_marks(const SpdfWinFindSession* s, int* out_count, int* out_active) {
    if (out_count) *out_count = s ? s->mark_count : 0;
    if (out_active) *out_active = s ? s->active_mark : -1;
    return s ? s->marks : NULL;
}

const SpdfWinFindPageMark* spdf_win_find_page_marks(const SpdfWinFindSession* s, int* out_count, int* out_active) {
    if (out_count) *out_count = s ? s->page_mark_count : 0;
    if (out_active) *out_active = s && s->current >= 0 && s->current < s->page_mark_count ? s->current : -1;
    return s ? s->page_marks : NULL;
}

/* The paint thread's windows, for the repaint side channel described on the
 * `windows` field. Exported rather than done inline in the model builder so the
 * session's internals stay inside this translation unit. Idempotent, and a
 * no-op in a headless process, where the painting thread owns no windows. */
void spdf_win_find_note_paint_thread(SpdfWinFindSession* s) {
    if (!s || s->noted_paint_thread) return;
    s->noted_paint_thread = 1;
    EnterCriticalSection(&s->lock);
    s->window_count = 0;
    EnumThreadWindows(GetCurrentThreadId(), collect_window, (LPARAM)s);
    LeaveCriticalSection(&s->lock);
}
