/* The file half of spdf_win_chapter_state.h: chapters.yaml read and written
 * through spdf_win_state.h, documents.yaml read as the mac-written fallback.
 * The JSON reasoning is all in the header, where a test can reach it; the
 * handing of these three functions to the content provider is
 * spdf_win_chapter_store_register.cpp's, so this unit links against the state
 * module alone and the provider against neither. */
#include "spdf_win_chapter_state.h"

#include "spdf_win_state.h"

#include <stdlib.h>
#include <string.h>

/* The record for `path` inside one file's JSON, decoded into keys. Returns 1
 * when the file has a record for the path AND that record carries the member. */
static int keys_from_file_json(const char* json, const char* path, char*** out_keys, int* out_count) {
    const char *v, *ve;
    char* record;
    int found;
    if (!json) return 0;
    if (!spdf_win_chapter_state_find_member(json, path, 1, NULL, NULL, &v, &ve)) return 0;
    record = (char*)malloc((size_t)(ve - v) + 1);
    if (!record) return 0;
    memcpy(record, v, (size_t)(ve - v));
    record[ve - v] = '\0';
    found = spdf_win_chapter_state_keys_from_record(record, out_keys, out_count);
    free(record);
    return found;
}

int spdf_win_chapter_state_load(const char* utf8_path, char*** out_keys, int* out_count) {
    char* json;
    int found;

    if (out_keys) *out_keys = NULL;
    if (out_count) *out_count = 0;
    if (!utf8_path || !utf8_path[0]) return 0;

    json = spdf_win_state_read_json(SPDF_WIN_CHAPTER_STATE_FILE);
    found = keys_from_file_json(json, utf8_path, out_keys, out_count);
    free(json);
    if (found) return 1;

    /* Nothing of ours: a record the mac app wrote into documents.yaml, if the
     * state directory came from one, is honoured -- same key names by design. */
    json = spdf_win_state_read_json(SPDF_WIN_STATE_DOCUMENTS);
    found = keys_from_file_json(json, utf8_path, out_keys, out_count);
    free(json);
    return found;
}

int spdf_win_chapter_state_save(const char* utf8_path, const char* const* keys, int count) {
    spdf_win_state_read_status status = SPDF_WIN_STATE_READ_ABSENT;
    char* json;
    char* merged;
    int ok;

    if (!utf8_path || !utf8_path[0]) return 0;
    json = spdf_win_state_read_json_checked(SPDF_WIN_CHAPTER_STATE_FILE, &status);
    if (status == SPDF_WIN_STATE_READ_FAILED) {
        /* Something is there and cannot be read right now. Writing over it
         * would trade every other document's memory for this one toggle. */
        free(json);
        return 0;
    }
    merged = spdf_win_chapter_state_merge(json, utf8_path, keys, count);
    free(json);
    if (!merged) return 0;
    ok = spdf_win_state_write_json(SPDF_WIN_CHAPTER_STATE_FILE, merged);
    free(merged);
    return ok;
}

void spdf_win_chapter_state_free_keys(char** keys, int count) {
    int i;
    if (!keys) return;
    for (i = 0; i < count; ++i) free(keys[i]);
    free(keys);
}
