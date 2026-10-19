/* Shenzhen Friends fake helper: the scripting queue and the observation functions other threads call.
 *
 * Scripting calls validate their JSON here, on the caller's thread, so a malformed script fails at the call that
 * made it; the fake's thread then applies queued commands in order (szfriends_fake_helper.c). */

#include "client/fake/szfriends_fake_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

void szf_fake_free_command(szf_fake_command *command) {
    free(command->name);
    free(command->json);
    free(command->bytes);
    free(command);
}

szfriends_status szf_fake_enqueue(szfriends_fake_helper *fake, szf_fake_command *command) {
    if (!command) return SZFRIENDS_ERR_NO_MEMORY;
    pthread_mutex_lock(&fake->mutex);
    if (fake->commands_tail) fake->commands_tail->next = command;
    else fake->commands = command;
    fake->commands_tail = command;
    pthread_mutex_unlock(&fake->mutex);
    if (write(fake->wake[1], "x", 1) < 0) {
        /* The pipe is full, so the thread is already due to wake and will see the queue. */
    }
    return SZFRIENDS_OK;
}

void szf_fake_set_frame_hook(szfriends_fake_helper *fake, szf_fake_frame_hook hook, void *data) {
    if (!fake) return;
    pthread_mutex_lock(&fake->mutex);
    fake->frame_hook = hook;
    fake->frame_hook_data = data;
    pthread_mutex_unlock(&fake->mutex);
}

szf_fake_command *szf_fake_command_new(szf_fake_command_kind kind, const char *name, const char *json) {
    szf_fake_command *command = (szf_fake_command *)calloc(1, sizeof *command);
    if (!command) return NULL;
    command->kind = kind;
    command->name = name ? strdup(name) : NULL;
    command->json = json ? strdup(json) : NULL;
    if ((name && !command->name) || (json && !command->json)) {
        szf_fake_free_command(command);
        return NULL;
    }
    return command;
}

szfriends_status szfriends_fake_helper_set_view_data(szfriends_fake_helper *fake, const char *view,
                                                     const char *data_json) {
    cJSON *data;
    if (!fake || !view || !data_json) return SZFRIENDS_ERR_INVALID_ARGUMENT;
    data = cJSON_Parse(data_json);
    if (!cJSON_IsObject(data)) {
        cJSON_Delete(data);
        return SZFRIENDS_ERR_INVALID_ARGUMENT;
    }
    cJSON_Delete(data);
    return szf_fake_enqueue(fake, szf_fake_command_new(SZF_FAKE_VIEW_DATA, view, data_json));
}

szfriends_status szfriends_fake_helper_set_view_fixture(szfriends_fake_helper *fake, const char *view,
                                                        const char *fixture_name) {
    char path[SZFRIENDS_PATH_CAP * 2];
    char *text, *data_text;
    cJSON *frame, *data;
    const cJSON *frame_view;
    szfriends_status status;
    if (!fake || !view || !fixture_name || strchr(fixture_name, '/')) return SZFRIENDS_ERR_INVALID_ARGUMENT;
    snprintf(path, sizeof path, "%s/snapshots/%s", fake->fixtures_dir, fixture_name);
    text = szf_fake_read_file(path, NULL);
    if (!text) return SZFRIENDS_ERR_IO;
    frame = cJSON_Parse(text);
    free(text);
    frame_view = cJSON_GetObjectItemCaseSensitive(frame, "view");
    data = cJSON_GetObjectItemCaseSensitive(frame, "data");
    if (!cJSON_IsString(frame_view) || strcmp(frame_view->valuestring, view) != 0 || !cJSON_IsObject(data)) {
        cJSON_Delete(frame);
        return SZFRIENDS_ERR_INVALID_ARGUMENT;
    }
    data_text = cJSON_PrintUnformatted(data);
    cJSON_Delete(frame);
    if (!data_text) return SZFRIENDS_ERR_NO_MEMORY;
    status = szfriends_fake_helper_set_view_data(fake, view, data_text);
    free(data_text);
    return status;
}

szfriends_status szfriends_fake_helper_set_reply(szfriends_fake_helper *fake, const char *intent,
                                                 const char *reply_json) {
    if (!fake || !intent) return SZFRIENDS_ERR_INVALID_ARGUMENT;
    if (reply_json) {
        cJSON *reply = cJSON_Parse(reply_json);
        bool ok = cJSON_IsObject(reply);
        cJSON_Delete(reply);
        if (!ok) return SZFRIENDS_ERR_INVALID_ARGUMENT;
    }
    return szf_fake_enqueue(fake, szf_fake_command_new(SZF_FAKE_REPLY, intent, reply_json));
}

szfriends_status szfriends_fake_helper_send_goodbye(szfriends_fake_helper *fake, const char *goodbye_json) {
    cJSON *frame;
    bool ok;
    if (!fake || !goodbye_json) return SZFRIENDS_ERR_INVALID_ARGUMENT;
    frame = cJSON_Parse(goodbye_json);
    ok = cJSON_IsObject(frame);
    cJSON_Delete(frame);
    if (!ok) return SZFRIENDS_ERR_INVALID_ARGUMENT;
    return szf_fake_enqueue(fake, szf_fake_command_new(SZF_FAKE_GOODBYE, NULL, goodbye_json));
}

szfriends_status szfriends_fake_helper_send_raw(szfriends_fake_helper *fake, const void *bytes, size_t length) {
    szf_fake_command *command;
    if (!fake || (!bytes && length)) return SZFRIENDS_ERR_INVALID_ARGUMENT;
    command = szf_fake_command_new(SZF_FAKE_RAW, NULL, NULL);
    if (!command) return SZFRIENDS_ERR_NO_MEMORY;
    command->bytes = (char *)malloc(length ? length : 1);
    if (!command->bytes) {
        szf_fake_free_command(command);
        return SZFRIENDS_ERR_NO_MEMORY;
    }
    if (length) memcpy(command->bytes, bytes, length);
    command->length = length;
    return szf_fake_enqueue(fake, command);
}

szfriends_status szfriends_fake_helper_drop_clients(szfriends_fake_helper *fake) {
    if (!fake) return SZFRIENDS_ERR_INVALID_ARGUMENT;
    return szf_fake_enqueue(fake, szf_fake_command_new(SZF_FAKE_DROP, NULL, NULL));
}

szfriends_status szfriends_fake_helper_hold_replies(szfriends_fake_helper *fake, bool hold) {
    if (!fake) return SZFRIENDS_ERR_INVALID_ARGUMENT;
    return szf_fake_enqueue(fake, szf_fake_command_new(hold ? SZF_FAKE_HOLD : SZF_FAKE_RELEASE, NULL, NULL));
}

size_t szfriends_fake_helper_client_count(szfriends_fake_helper *fake) {
    size_t count;
    if (!fake) return 0;
    pthread_mutex_lock(&fake->mutex);
    count = fake->client_count;
    pthread_mutex_unlock(&fake->mutex);
    return count;
}

size_t szfriends_fake_helper_frame_count(szfriends_fake_helper *fake) {
    size_t count;
    if (!fake) return 0;
    pthread_mutex_lock(&fake->mutex);
    count = fake->frame_count;
    pthread_mutex_unlock(&fake->mutex);
    return count;
}

char *szfriends_fake_helper_copy_frame(szfriends_fake_helper *fake, size_t index) {
    char *copy = NULL;
    if (!fake) return NULL;
    pthread_mutex_lock(&fake->mutex);
    if (index < fake->frame_count) copy = strdup(fake->frames[index]);
    pthread_mutex_unlock(&fake->mutex);
    return copy;
}

int64_t szfriends_fake_helper_idle_ms(szfriends_fake_helper *fake) {
    int64_t idle;
    if (!fake) return -2;
    pthread_mutex_lock(&fake->mutex);
    if (fake->client_count > 0) idle = -1;
    else if (!fake->ever_had_client) idle = -2;
    else idle = (int64_t)(szfriends_monotonic_ms() - fake->last_left_ms);
    pthread_mutex_unlock(&fake->mutex);
    return idle;
}

bool szfriends_fake_helper_stepped_aside(szfriends_fake_helper *fake) {
    bool stepped;
    if (!fake) return false;
    pthread_mutex_lock(&fake->mutex);
    stepped = fake->stepped_aside;
    pthread_mutex_unlock(&fake->mutex);
    return stepped;
}
