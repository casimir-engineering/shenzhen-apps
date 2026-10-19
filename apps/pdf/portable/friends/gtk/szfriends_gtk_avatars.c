/* The animal set's manifest, which picture an avatar draws, and reading a photo (szfriends_gtk_avatars.h).
 * Display-free. */

#include "gtk/szfriends_gtk_avatars.h"
#include "gtk/szfriends_gtk_link_private.h"

#include <errno.h>
#include <fcntl.h>
#include <glib/gstdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* A real manifest is a few kilobytes; anything near this is damage, and reading it whole would waste memory. */
#define SZFRIENDS_GTK_MANIFEST_MAX_BYTES (1024 * 1024)
/* Indexes travel as u16 in the PROFILE session frame, so no set can exceed this. */
#define SZFRIENDS_GTK_ANIMAL_MAX_COUNT 65536

struct _SZFriendsGtkAnimalSet {
    gint64 version;
    GPtrArray *names, *colors, *svgs;
};

void szfriends_gtk_animal_set_free(SZFriendsGtkAnimalSet *set) {
    if (!set) return;
    g_ptr_array_unref(set->names);
    g_ptr_array_unref(set->colors);
    g_ptr_array_unref(set->svgs);
    g_free(set);
}

gboolean szfriends_gtk_parse_hex_color(const char *hex, GdkRGBA *rgba) {
    if (!hex || strlen(hex) != 7 || hex[0] != '#') return FALSE;
    guint value = 0;
    for (int i = 1; i < 7; i++) {
        int digit = g_ascii_xdigit_value(hex[i]);
        if (digit < 0) return FALSE;
        value = value * 16 + (guint)digit;
    }
    if (rgba) *rgba = (GdkRGBA){((value >> 16) & 255) / 255.0f, ((value >> 8) & 255) / 255.0f, (value & 255) / 255.0f,
                                1.0f};
    return TRUE;
}

/* A relative path that stays inside the manifest's directory: no absolute paths, no "..", no empty parts. */
static char *contained_path(const char *directory, JsonObject *animal, const char *key) {
    const char *relative = json_object_get_string_member_with_default(animal, key, NULL);
    if (!relative || !*relative || relative[0] == '/') return NULL;
    char **parts = g_strsplit(relative, "/", -1);
    gboolean safe = TRUE;
    for (char **part = parts; *part; part++)
        if (!**part || strcmp(*part, "..") == 0 || strcmp(*part, ".") == 0) safe = FALSE;
    g_strfreev(parts);
    return safe ? g_build_filename(directory, relative, NULL) : NULL;
}

static gboolean manifest_integer(JsonObject *object, const char *key, gint64 *out) {
    JsonNode *node = json_object_get_member(object, key);
    if (!node || !JSON_NODE_HOLDS_VALUE(node) || json_node_get_value_type(node) != G_TYPE_INT64) return FALSE;
    *out = json_node_get_int(node);
    return TRUE;
}

static gboolean fail(GError **error, const char *path, const char *problem) {
    g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_INVAL, "Animal set manifest %s: %s", path, problem);
    return FALSE;
}

static gboolean read_animals(SZFriendsGtkAnimalSet *set, JsonArray *animals, const char *directory, const char *path,
                             GError **error) {
    for (guint i = 0; i < json_array_get_length(animals); i++) {
        JsonNode *node = json_array_get_element(animals, i);
        JsonObject *animal = JSON_NODE_HOLDS_OBJECT(node) ? json_node_get_object(node) : NULL;
        gint64 index = -1;
        /* Indexes are positions: an animal's index is permanent, so the array never skips or reorders one. */
        if (!animal || !manifest_integer(animal, "index", &index) || index != (gint64)i)
            return fail(error, path, "an animal has the wrong \"index\"");
        const char *name = json_object_get_string_member_with_default(animal, "name", NULL);
        const char *color = json_object_get_string_member_with_default(animal, "color", NULL);
        if (!name || !*name) return fail(error, path, "an animal needs a \"name\"");
        if (!szfriends_gtk_parse_hex_color(color, NULL) || strspn(color + 1, "0123456789abcdef") != 6)
            return fail(error, path, "an animal needs a \"color\" like #5a4a7a");
        char *svg = contained_path(directory, animal, "svg"), *pdf = contained_path(directory, animal, "pdf");
        gboolean ok = svg && pdf;
        g_free(pdf);
        if (!ok) {
            g_free(svg);
            return fail(error, path, "an animal needs relative \"svg\" and \"pdf\" paths inside the set");
        }
        g_ptr_array_add(set->names, g_strdup(name));
        g_ptr_array_add(set->colors, g_strdup(color));
        g_ptr_array_add(set->svgs, svg);
    }
    return TRUE;
}

SZFriendsGtkAnimalSet *szfriends_gtk_animal_set_load(const char *path, GError **error) {
    char *text = NULL;
    gsize length = 0;
    GStatBuf info;
    if (!path || g_stat(path, &info) != 0 || info.st_size > SZFRIENDS_GTK_MANIFEST_MAX_BYTES) {
        fail(error, path ? path : "(none)", "missing or too large");
        return NULL;
    }
    if (!g_file_get_contents(path, &text, &length, error)) return NULL;
    JsonObject *manifest = szfriends_gtk_json_object_from_text(text, (gssize)length);
    g_free(text);
    if (!manifest) {
        fail(error, path, "not a JSON object");
        return NULL;
    }
    SZFriendsGtkAnimalSet *set = g_new0(SZFriendsGtkAnimalSet, 1);
    set->names = g_ptr_array_new_with_free_func(g_free);
    set->colors = g_ptr_array_new_with_free_func(g_free);
    set->svgs = g_ptr_array_new_with_free_func(g_free);
    JsonNode *list = json_object_get_member(manifest, "animals");
    JsonArray *animals = list && JSON_NODE_HOLDS_ARRAY(list) ? json_node_get_array(list) : NULL;
    gint64 count = -1;
    char *directory = g_path_get_dirname(path);
    gboolean ok = FALSE;
    if (!manifest_integer(manifest, "set", &set->version) || set->version < 1)
        fail(error, path, "\"set\" must be an integer of at least 1");
    else if (!animals || !json_array_get_length(animals) ||
             json_array_get_length(animals) > SZFRIENDS_GTK_ANIMAL_MAX_COUNT)
        fail(error, path, "\"animals\" must be a non-empty array of at most 65536 entries");
    else if (!manifest_integer(manifest, "count", &count) || count != (gint64)json_array_get_length(animals))
        fail(error, path, "\"count\" must equal the number of animals");
    else
        ok = read_animals(set, animals, directory, path, error);
    g_free(directory);
    json_object_unref(manifest);
    if (ok) return set;
    szfriends_gtk_animal_set_free(set);
    return NULL;
}

gint64 szfriends_gtk_animal_set_version(const SZFriendsGtkAnimalSet *set) {
    return set ? set->version : 0;
}

gsize szfriends_gtk_animal_set_count(const SZFriendsGtkAnimalSet *set) {
    return set ? set->names->len : 0;
}

static const char *at(const GPtrArray *array, gint64 index) {
    return array && index >= 0 && index < (gint64)array->len ? g_ptr_array_index(array, (guint)index) : NULL;
}

const char *szfriends_gtk_animal_set_name(const SZFriendsGtkAnimalSet *set, gint64 index) {
    return set ? at(set->names, index) : NULL;
}

const char *szfriends_gtk_animal_set_color(const SZFriendsGtkAnimalSet *set, gint64 index) {
    return set ? at(set->colors, index) : NULL;
}

const char *szfriends_gtk_animal_set_svg_path(const SZFriendsGtkAnimalSet *set, gint64 index) {
    return set ? at(set->svgs, index) : NULL;
}

char *szfriends_gtk_animals_manifest_path(const SZFriendsGtkHost *host) {
    if (host && host->animals_manifest_path && *host->animals_manifest_path)
        return g_strdup(host->animals_manifest_path);
    const char *override = g_getenv("SZFRIENDS_AVATARS_MANIFEST");
    if (override && g_path_is_absolute(override) && szfriends_environment_overrides_allowed())
        return g_strdup(override);
    /* Host.app/Contents/Helpers/Shenzhen Friends.app/...: both apps ship the set once, in the host's Resources. */
    const char *helper = host ? host->helper_path : NULL;
    const char *helpers = helper ? strstr(helper, "/Contents/Helpers/") : NULL;
    if (!helpers) return NULL;
    char *contents = g_strndup(helper, (gsize)(helpers - helper) + strlen("/Contents"));
    char *path = g_build_filename(contents, "Resources", "Friends", "animals", "manifest.json", NULL);
    g_free(contents);
    return path;
}

SZFriendsGtkAnimalSet *szfriends_gtk_link_animal_set(SZFriendsGtkLink *link) {
    if (!link) return NULL;
    if (!link->animals_loaded) {
        link->animals_loaded = TRUE;
        char *path = szfriends_gtk_animals_manifest_path(&link->host);
        GError *error = NULL;
        link->animals = path ? szfriends_gtk_animal_set_load(path, &error) : NULL;
        if (error) g_warning("%s", error->message); /* a packaging bug; avatars draw initials meanwhile */
        g_clear_error(&error);
        g_free(path);
    }
    return link->animals;
}

/* ---- Photos ------------------------------------------------------------------------------------------ */

/* The helper writes 256 px JPEGs of at most 48 KiB (avatars/README.md § Photos); anything far larger is not one of
 * them, and a side over this bound would make a decode allocate far more than any avatar needs. */
#define SZFRIENDS_GTK_AVATAR_PHOTO_MAX_BYTES (256 * 1024)
#define SZFRIENDS_GTK_AVATAR_PHOTO_MAX_SIDE 1024

char *szfriends_gtk_avatar_pictures_dir(void) {
    char state[4096];
    return szfriends_default_state_dir(state, sizeof state) == SZFRIENDS_OK
               ? g_build_filename(state, "pictures", NULL) : NULL;
}

gboolean szfriends_gtk_avatar_photo_allowed(const char *path, const char *pictures_dir) {
    if (!path || !pictures_dir || !*pictures_dir) return FALSE;
    gsize prefix = strlen(pictures_dir);
    const char *name = path + prefix;
    /* Directly inside, by a name the helper chose: no subfolder, no "..", nothing an absolute path could reach. */
    return strncmp(path, pictures_dir, prefix) == 0 && name[0] == '/' && name[1] != '\0' && !strchr(name + 1, '/') &&
           strcmp(name + 1, ".") != 0 && strcmp(name + 1, "..") != 0;
}

static GdkTexture *refuse(GError **error, const char *path, const char *why) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "avatar photo %s: %s", path ? path : "(none)", why);
    return NULL;
}

static guint read16(const guint8 *bytes) {
    return (guint)bytes[0] << 8 | bytes[1];
}

/* The size a PNG or JPEG declares, read before anything is decoded; FALSE for anything else or a damaged header. */
static gboolean declared_size(const guint8 *bytes, gsize size, guint *width, guint *height) {
    static const guint8 png[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
    if (size >= 24 && !memcmp(bytes, png, 8) && !memcmp(bytes + 12, "IHDR", 4)) {
        /* Widths past 65535 fail the side bound anyway; the high half must be zero. */
        if (read16(bytes + 16) || read16(bytes + 20)) return FALSE;
        *width = read16(bytes + 18), *height = read16(bytes + 22);
        return TRUE;
    }
    if (size < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return FALSE;
    /* JPEG: walk the marker segments to the first frame header (ITU T.81 B.1.1). */
    for (gsize at = 2; at + 4 <= size;) {
        if (bytes[at] != 0xFF) return FALSE;
        while (at < size && bytes[at] == 0xFF) at++; /* fill bytes */
        if (at >= size) return FALSE;
        guint8 marker = bytes[at++];
        if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) continue; /* stand alone, without a length */
        if (marker == 0xD8 || marker == 0xD9 || marker == 0xDA || at + 2 > size) return FALSE; /* no frame first */
        guint length = read16(bytes + at);
        if (length < 2 || at + length > size) return FALSE;
        gboolean frame = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
        if (frame) {
            if (length < 8) return FALSE;
            *height = read16(bytes + at + 3), *width = read16(bytes + at + 5);
            return TRUE;
        }
        at += length;
    }
    return FALSE;
}

GdkTexture *szfriends_gtk_avatar_photo_load(const char *path, const char *pictures_dir, GError **error) {
    if (!szfriends_gtk_avatar_photo_allowed(path, pictures_dir)) return refuse(error, path, "not in pictures/");
    /* No link followed, and a FIFO or device never blocks or streams: a regular file of bounded size only. */
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return refuse(error, path, g_strerror(errno));
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 24 ||
        info.st_size > SZFRIENDS_GTK_AVATAR_PHOTO_MAX_BYTES) {
        close(fd);
        return refuse(error, path, "not a regular file of a photo's size");
    }
    gsize size = (gsize)info.st_size, done = 0;
    guint8 *bytes = g_malloc(size);
    while (done < size) {
        ssize_t got = read(fd, bytes + done, size - done);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) break;
        done += (gsize)got;
    }
    close(fd);
    guint width = 0, height = 0;
    if (done != size || !declared_size(bytes, size, &width, &height) || width < 1 || height < 1 ||
        width > SZFRIENDS_GTK_AVATAR_PHOTO_MAX_SIDE || height > SZFRIENDS_GTK_AVATAR_PHOTO_MAX_SIDE) {
        g_free(bytes);
        return refuse(error, path, "not a JPEG or PNG of at most 1024 pixels a side");
    }
    GBytes *data = g_bytes_new_take(bytes, size);
    GdkTexture *texture = gdk_texture_new_from_bytes(data, error);
    g_bytes_unref(data);
    if (texture &&
        ((guint)gdk_texture_get_width(texture) != width || (guint)gdk_texture_get_height(texture) != height)) {
        g_object_unref(texture);
        return refuse(error, path, "decoded size differs from its header");
    }
    return texture;
}

SZFriendsGtkAvatarDraw szfriends_gtk_avatar_draw_kind(const SZFriendsGtkAvatar *avatar,
                                                      const SZFriendsGtkAnimalSet *set, const char **path) {
    const char *file = NULL;
    SZFriendsGtkAvatarDraw draw = SZFRIENDS_GTK_AVATAR_DRAW_INITIALS;
    if (avatar && avatar->kind == SZFRIENDS_GTK_AVATAR_ANIMAL) {
        /* Indexes are permanent across set versions, so any index this set has is the same animal. */
        file = szfriends_gtk_animal_set_svg_path(set, avatar->index);
        if (file && g_file_test(file, G_FILE_TEST_IS_REGULAR)) draw = SZFRIENDS_GTK_AVATAR_DRAW_ANIMAL;
    } else if (avatar && avatar->kind == SZFRIENDS_GTK_AVATAR_IMAGE) {
        /* Only the helper's own photos, judged by the path alone: the file is read off the main thread, and one
         * that cannot be read draws as initials meanwhile and after. */
        char *pictures = szfriends_gtk_avatar_pictures_dir();
        if (szfriends_gtk_avatar_photo_allowed(avatar->path, pictures)) {
            file = avatar->path;
            draw = SZFRIENDS_GTK_AVATAR_DRAW_PHOTO;
        }
        g_free(pictures);
    }
    if (path) *path = draw == SZFRIENDS_GTK_AVATAR_DRAW_INITIALS ? NULL : file;
    return draw;
}
