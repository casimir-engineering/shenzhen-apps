#pragma once

#include <adwaita.h>

#include "spdf_password.h"

G_BEGIN_DECLS

typedef struct _SpdfPasswordPrompt SpdfPasswordPrompt;
typedef void (*SpdfPasswordOpenReady)(spdf_document* document, SpdfPasswordCredential* credential, gboolean cancelled,
                                      const char* error, gpointer user_data);

/* Fully asynchronous active-document opener. The callback receives full
 * ownership of document and credential. The operation owns user_data until
 * every stale worker/dialog callback has drained. */
SpdfPasswordPrompt* spdf_password_open_async(GtkWindow* parent, const char* source_path, const char* open_path,
                                             SpdfPasswordCredential* credential, SpdfPasswordOpenReady ready,
                                             gpointer user_data, GDestroyNotify destroy);
void spdf_password_prompt_cancel(SpdfPasswordPrompt* prompt);
gboolean spdf_password_require_permission(GtkWindow* parent, spdf_document* document, int permission,
                                          const char* heading);
gboolean spdf_password_require_ocr(GtkWindow* parent, spdf_document* document);
void spdf_password_update_context_actions(GActionMap* actions, spdf_document* document, gboolean pdf,
                                          gboolean has_selection, gboolean has_annotation_target, gboolean has_comment,
                                          gboolean has_page);

G_END_DECLS
