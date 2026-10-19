#pragma once

#include <gio/gio.h>

#include "spdf_password.h"

G_BEGIN_DECLS

typedef struct _SpdfPasswordController SpdfPasswordController;
typedef void (*SpdfPasswordNeedsSecret)(SpdfPasswordController* controller, gboolean incorrect, gpointer user_data);
typedef void (*SpdfPasswordControllerReady)(spdf_document* document, SpdfPasswordCredential* credential,
                                            gboolean cancelled, const char* error, gpointer user_data);

SpdfPasswordController* spdf_password_controller_new(const char* source_path, const char* open_path,
                                                     SpdfPasswordCredential* credential,
                                                     SpdfPasswordNeedsSecret needs_secret,
                                                     SpdfPasswordControllerReady ready, gpointer user_data,
                                                     GDestroyNotify destroy);
void spdf_password_controller_start(SpdfPasswordController* controller);
void spdf_password_controller_submit(SpdfPasswordController* controller, const char* password);
void spdf_password_controller_cancel(SpdfPasswordController* controller);

G_END_DECLS
