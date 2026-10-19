/* Shenzhen Friends GTK views: the field tables behind szfriends_gtk_snapshot.h (internal to gtk/).
 *
 * WHY tables rather than one hand-written parser per view: one generic walker then parses, frees and (in the suite)
 * re-serializes every struct, and the suite can compare each table with PROTOCOL.md's § Schemas blocks, so a field
 * the protocol adds cannot reach the GTK views unnoticed or be parsed into the wrong slot. Each table lists its
 * struct's fields in order; field i of a table owns bit i of the struct's `present` mask. */

#ifndef SZFRIENDS_GTK_SCHEMA_H
#define SZFRIENDS_GTK_SCHEMA_H

#include "gtk/szfriends_gtk_snapshot.h"

#include <stddef.h>

G_BEGIN_DECLS

typedef enum {
    SZFRIENDS_GTK_FIELD_STRING,      /* char *, "" when missing or not a string */
    SZFRIENDS_GTK_FIELD_STRING_NULL, /* char *, NULL for null (string|null) */
    SZFRIENDS_GTK_FIELD_BOOL,        /* gboolean */
    SZFRIENDS_GTK_FIELD_INT,         /* gint64 */
    SZFRIENDS_GTK_FIELD_OPT_INT,     /* SZFriendsGtkOptInt (integer|null) */
    SZFRIENDS_GTK_FIELD_NUMBER,      /* double */
    SZFRIENDS_GTK_FIELD_ENUM,        /* an enum stored as int; index into `enum_names` */
    SZFRIENDS_GTK_FIELD_OBJECT,      /* embedded struct of `type` */
    SZFRIENDS_GTK_FIELD_OBJECT_NULL, /* pointer to a struct of `type`, NULL for null (@x|null) */
    SZFRIENDS_GTK_FIELD_ARRAY,       /* pointer to contiguous structs of `type`, gsize count at `count_offset` */
    SZFRIENDS_GTK_FIELD_STRINGS,     /* char **, NULL-terminated */
    SZFRIENDS_GTK_FIELD_STRING_MAP,  /* GHashTable * of string -> string */
    SZFRIENDS_GTK_FIELD_JSON_OBJECT  /* JsonObject *, referenced (reply results, error details) */
} SZFriendsGtkFieldKind;

typedef struct {
    const char *const *names; /* index = enum value; names[0] is NULL when 0 means unknown */
    gsize count;
} SZFriendsGtkEnumNames;

typedef struct {
    const char *name;
    SZFriendsGtkFieldKind kind;
    gsize offset;
    const SZFriendsGtkType *type;      /* OBJECT, OBJECT_NULL and ARRAY */
    const SZFriendsGtkEnumNames *enums; /* ENUM */
    gsize count_offset;                /* ARRAY */
} SZFriendsGtkField;

struct _SZFriendsGtkType {
    const char *name; /* the PROTOCOL.md block it mirrors ("type.list_row"), NULL for an inline object */
    gsize size;
    const SZFriendsGtkField *fields;
    gsize n_fields;
};

/* The value index of `name` in `enums`, or 0 when absent; and back. */
int szfriends_gtk_enum_value(const SZFriendsGtkEnumNames *enums, const char *name);
const char *szfriends_gtk_enum_name(const SZFriendsGtkEnumNames *enums, int value);

/* For the suite's PROTOCOL.md comparison: every type with a block name, NULL-terminated. */
extern const SZFriendsGtkType *const szfriends_gtk_named_types[];

G_END_DECLS

#endif /* SZFRIENDS_GTK_SCHEMA_H */
