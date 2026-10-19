/* The launch-path spawn (szfriends_gtk.h): connect-or-spawn on a GTask worker thread.
 *
 * WHY a worker thread: the brief's launch gate allows the host no Friends work on the main thread before first
 * paint, and szfriends_spawn_helper() refuses the main thread on macOS so a host that forgot fails loudly. The task
 * is never waited for; the client library spawns again by itself if this one lost a race. */

#include "gtk/szfriends_gtk.h"

#include "client/szfriends_client.h"

#include <gio/gio.h>

static void spawn_in_thread(GTask *task, gpointer source, gpointer data, GCancellable *cancellable) {
    (void)source, (void)cancellable;
    pid_t pid = 0;
    szfriends_status status = szfriends_spawn_helper(data, NULL, &pid);
    g_task_return_int(task, status);
}

void szfriends_gtk_spawn_helper_async(const char *helper_path) {
    if (!helper_path || !*helper_path) return;
    GTask *task = g_task_new(NULL, NULL, NULL, NULL);
    g_task_set_name(task, "szfriends-spawn-helper");
    g_task_set_task_data(task, g_strdup(helper_path), g_free);
    g_task_run_in_thread(task, spawn_in_thread);
    g_object_unref(task);
}
