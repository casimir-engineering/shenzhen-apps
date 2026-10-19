/* spdf_win_recents.h — recently opened documents, the reopen-closed ring, and
 * the per-document store behind them (documents.yaml).
 *
 * THE SCHEMA IS THE OTHER TWO FRONTENDS', NOT A NEW ONE. macOS and Linux share
 * these files -- a user who syncs %APPDATA%\ShenzhenPDF with
 * ~/Library/Application Support/ShenzhenPDF must find them meaningful -- so the
 * writer here produces what portable/linux/gtk4/spdf_state.c's documents_to_json
 * produces and what ShenzhenPDFMac.mm's writeStateObject:toFile:@"documents.yaml"
 * produces, member for member, sorted the way NSJSONWritingSortedKeys sorts:
 *
 *   documents.yaml   { "<path>": { "path", "showMinimap", "showSidebar",
 *                                  "title", "updatedAt" }, ... }
 *
 * plus any member this build does not model (the mac's page-geometry cache),
 * which is carried through verbatim rather than dropped.
 *
 * WHERE THE MRU LIST LIVES. Both other frontends persist the ordered
 * "recently opened" list as settings.yaml's "recentlyOpened" array (10 entries,
 * MRU first). settings.yaml is written by the windows track's settings module,
 * which this module must not write over -- two read-modify-write cycles of the
 * same file in one process would each lose the other's keys. So:
 *
 *   - the order is kept HERE, in memory, and DERIVED on load: settings.yaml's
 *     "recentlyOpened" is read (read-only) and seeds the list in its own order
 *     so a list written by the mac or GTK app is honoured; documents.yaml's
 *     "updatedAt" stamps fill in behind it, newest first;
 *   - every open stamps documents.yaml, which IS written here, so the order
 *     survives a relaunch even before the settings writer learns the key;
 *   - spdf_win_recents_merge_recently_opened() hands the settings writer a
 *     version of its JSON with "recentlyOpened" filled in, so the shared key is
 *     written once, by the file's one writer.
 *
 * Files are read and written through spdf_win_state.h's public entry points,
 * which is what gives them the YAML codec, the atomic replace and the
 * "unreadable is not absent" rule (spdf_win_state_read_status). Nothing here
 * opens a file itself.
 *
 * Process-wide state, loaded lazily on first use -- like the GTK SpdfState's
 * documents/favorites, which "load lazily on first use" so the launch path does
 * not pay for them. Not thread-safe; UI thread only.
 */
#ifndef SPDF_WIN_RECENTS_H
#define SPDF_WIN_RECENTS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* SPDF_STATE_MAX_RECENT_DOCUMENTS / kRecentDocumentLimit: 10 on both. */
#define SPDF_WIN_RECENTS_MAX 10
/* SPDF_STATE_MAX_CLOSED_DOCUMENTS: the reopen ring is in-memory only, on all
 * three frontends. */
#define SPDF_WIN_RECENTS_CLOSED_MAX 10
#define SPDF_WIN_RECENTS_PATH_MAX 1024
#define SPDF_WIN_RECENTS_TITLE_MAX 256

/* A documents.yaml record, as far as this build models it. `extra` is the raw
 * JSON of every other member ("key":value pairs, comma-separated, or empty),
 * kept so a rewrite here never drops the mac's geometry cache. */
typedef struct SpdfWinDocRecord {
    char path[SPDF_WIN_RECENTS_PATH_MAX];
    char title[SPDF_WIN_RECENTS_TITLE_MAX];
    int show_sidebar;
    int show_minimap;
    int has_show_sidebar;
    int has_show_minimap;
    long long updated_at; /* seconds since the epoch */
} SpdfWinDocRecord;

/* Forget everything in memory; the next call reloads from the state directory.
 * For tests (after spdf_win_paths_set_state_dir_override) and nothing else. */
void spdf_win_recents_reset(void);

/* --- the MRU list --------------------------------------------------------- */

int spdf_win_recents_count(void);
/* MRU first. NULL for a bad index. Valid until the next mutation. */
const char* spdf_win_recents_path(int index);

/* A document was opened: move (or insert) it at the front, stamp its
 * documents.yaml record and write the file. `title` may be NULL (the path's
 * last component is used). Shadow copies (spdf_win_watcher_is_shadow_path) and
 * empty paths are ignored -- as they are by spdf_win_favorites_add(). */
void spdf_win_recents_note_opened(const char* path, const char* title);

/* Drop a path from the list (it no longer exists, say). Does not touch its
 * documents.yaml record. */
void spdf_win_recents_remove(const char* path);

/* The dedupe rule, exposed for the palette and the favorites store: the same
 * file spelled two ways is one entry. Separators are normalised and ASCII case
 * is folded, which is what Windows itself considers the same path. */
int spdf_win_recents_path_equal(const char* a, const char* b);

/* --- the reopen-closed ring ----------------------------------------------- */

void spdf_win_recents_note_closed(const char* path);
/* Most recently closed first; copies into out and returns 1, or 0 when the
 * ring is empty. */
int spdf_win_recents_pop_closed(char* out, size_t out_cap);
int spdf_win_recents_closed_count(void);

/* --- per-document view state ---------------------------------------------- */

/* Returns 1 and fills `out` when documents.yaml has a record for path. */
int spdf_win_recents_document_lookup(const char* path, SpdfWinDocRecord* out);
/* Upsert the panel visibility for a document (stamps updatedAt, writes). */
void spdf_win_recents_document_update(const char* path, const char* title, int show_sidebar, int show_minimap);

/* --- the shared settings key ---------------------------------------------- */

/* Return a copy of `settings_json` (a JSON object) with the top-level
 * "recentlyOpened" member replaced by -- or inserted as -- this module's MRU
 * list, in sorted-key position. The settings writer calls this right before it
 * hands its JSON to spdf_win_state_write_json(). malloc'd; NULL when
 * settings_json is not an object or on allocation failure. An empty or NULL
 * input is treated as "{}". */
char* spdf_win_recents_merge_recently_opened(const char* settings_json);

/* The documents.yaml payload this module would write right now, as JSON.
 * malloc'd. For tests, which compare it against the shared codec. */
char* spdf_win_recents_documents_json(void);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_RECENTS_H */
