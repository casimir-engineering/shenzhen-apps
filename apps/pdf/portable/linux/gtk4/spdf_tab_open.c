#include "spdf_internal.h"

#include "spdf_password_prompt.h"
#include "spdf_watcher.h"
#include "spdf_window.h"

typedef struct {
    SpdfWindow* win;
    char* canonical;
    SpdfWatcherResolution shadow;
    gboolean source_read_only;
    SpdfTabOpenReady ready;
    gpointer user_data;
    GDestroyNotify destroy;
    gboolean attached;
} SpdfTabOpenContext;

static void tab_open_context_free(gpointer data) {
    SpdfTabOpenContext* context = data;

    if (!context->attached) {
        g_free(context->canonical);
        g_free(context->shadow.working_path);
    }
    if (context->destroy) context->destroy(context->user_data);
    g_object_unref(context->win);
    g_free(context);
}

static void tab_password_ready(spdf_document* document, SpdfPasswordCredential* credential, gboolean cancelled,
                               const char* error, gpointer user_data) {
    SpdfTabOpenContext* context = user_data;
    SpdfTab* tab = NULL;

    if (document) {
        tab = spdf_tab_attach_opened(context->win, context->canonical, context->shadow.working_path,
                                     context->shadow.copy_file_size, context->shadow.copy_modified_at,
                                     context->source_read_only, document, credential);
        context->attached = TRUE;
        context->canonical = NULL;
        context->shadow.working_path = NULL;
    } else {
        spdf_password_credential_unref(credential);
    }
    if (context->ready) context->ready(tab, cancelled, error, context->user_data);
}

SpdfPasswordPrompt* spdf_tab_open_async(SpdfWindow* win, const char* path, SpdfTabOpenReady ready, gpointer user_data,
                                        GDestroyNotify destroy) {
    SpdfTabOpenContext* context;
    const char* open_path;

    g_return_val_if_fail(SPDF_IS_WINDOW(win), NULL);
    g_return_val_if_fail(path && *path, NULL);
    context = g_new0(SpdfTabOpenContext, 1);
    context->win = g_object_ref(win);
    context->canonical = g_canonicalize_filename(path, NULL);
    context->ready = ready;
    context->user_data = user_data;
    context->destroy = destroy;
    spdf_launch_mark("tab-open-begin");
    context->source_read_only = spdf_watcher_resolve_open(context->canonical, &context->shadow);
    spdf_launch_mark("tab-watcher-resolved");
    open_path = context->shadow.working_path ? context->shadow.working_path : context->canonical;
    return spdf_password_open_async(GTK_WINDOW(win), context->canonical, open_path, NULL, tab_password_ready, context,
                                    tab_open_context_free);
}
