#ifndef SPDF_YAML_H
#define SPDF_YAML_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Strict YAML subset codec for ShenzhenPDF's human-readable state files
 * (settings/session/documents/favorites/bookmarks). Both frontends keep
 * building/consuming JSON internally and convert at the file boundary, so one
 * codec serves the AppKit and GTK apps.
 *
 * Supported YAML subset (everything the app emits, plus reasonable human
 * edits):
 *   - block mappings and block sequences, 2-space indentation on emit,
 *     any consistent deeper indentation on parse (a sequence may also sit at
 *     the same indent as its parent key, as humans commonly write)
 *   - scalars: double-quoted strings (\" \\ \/ \b \f \n \r \t \uXXXX escapes,
 *     UTF-16 surrogate pairs), single-quoted strings ('' for '), plain
 *     numbers (JSON grammar), true/false, null/~
 *   - empty containers as {} and []
 *   - full-line comments (# ...), trailing comments after values, blank
 *     lines, trailing whitespace, an optional leading --- document marker
 * NOT supported (never emitted): anchors, aliases, tags, non-empty flow
 * style, block scalars (| and >), multi-document streams.
 *
 * Emit rules keep files diffable: key order is preserved from the JSON input
 * (frontends emit sorted/fixed-order JSON), strings are always double-quoted,
 * numbers/bools pass through as verbatim tokens so a load/save cycle is
 * byte-stable.
 */

/* Convert strict JSON text to YAML text. When header_comment is non-NULL and
 * non-empty, the output starts with "# <header_comment>\n". Returns a
 * malloc'd NUL-terminated string the caller frees, or NULL when the JSON does
 * not parse. */
char* spdf_yaml_from_json(const char* json_text, const char* header_comment);

/* Convert YAML subset text to compact JSON text. Returns a malloc'd
 * NUL-terminated string the caller frees, or NULL when the YAML does not
 * parse (callers treat that exactly like today's corrupt-JSON path: as a
 * missing/ignored file). */
char* spdf_json_from_yaml(const char* yaml_text);

/* Build the standard header comment for a state file name ("settings.yaml",
 * a full path, or a bare stem all work): "ShenzhenPDF <stem> — edit while the
 * app is closed". Returns out for convenience. */
const char* spdf_state_header_for_file(const char* filename, char* out, size_t out_len);

/* One-shot migration of a single state file from JSON to YAML:
 *   - <yaml_path> already exists and is at least as new as <json_path>: do
 *     nothing (the YAML wins; JSON untouched). A <json_path> with a strictly
 *     newer mtime means a pre-YAML build wrote state after the YAML was
 *     created (downgrade then upgrade); it is re-migrated so the user's most
 *     recent state wins.
 *   - <json_path> missing: do nothing
 *   - otherwise parse the JSON, write the YAML atomically (temp + rename),
 *     then rename <json_path> to "<json_path>.migrated-backup"
 * Malformed JSON is left fully in place (matching the current behavior where
 * a corrupt state file is ignored and defaults apply). Returns 1 when a file
 * was migrated, 0 when there was nothing to do, -1 on error. The caller is
 * responsible for cross-process serialization (see spdf_state_migrate_dir).
 */
int spdf_state_migrate_file(const char* json_path, const char* yaml_path, const char* header_comment);

/* Migrate "<dir>/<stem>.json" to "<dir>/<stem>.yaml" for every stem, under an
 * exclusive flock on "<dir>/migration.lock" so the app's multiple processes
 * (one per window) cannot double-migrate or observe a half-written file.
 * Idempotent: a second call, or a second process, finds the YAML present and
 * does nothing. Returns the number of files migrated, or -1 when the lock
 * file cannot be created. */
int spdf_state_migrate_dir(const char* dir, const char* const* stems, int stem_count);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_YAML_H */
