/* Field tables for every struct in szfriends_gtk_snapshot.h, in the order of PROTOCOL.md's § Schemas blocks.
 * Leaves come first so no table refers to one not yet defined. */

#include "gtk/szfriends_gtk_schema.h"

#include <string.h>

/* Every entry checks at compile time that its kind matches the C type of the struct member it names, so a table can
 * never write a pointer into a gboolean or read a struct as a string. */
#define MEMBER(T, f) __typeof__(((T *)0)->f)
#define SAME(T, f, C) __builtin_types_compatible_p(MEMBER(T, f), C)
#define CHECKED(T, f, ok) (offsetof(T, f) + 0 * sizeof(char[(ok) ? 1 : -1]))
#define FIELD(T, f, kind, type, enums, ok) {#f, SZFRIENDS_GTK_FIELD_##kind, CHECKED(T, f, ok), type, enums, 0}
#define STR(T, f) FIELD(T, f, STRING, NULL, NULL, SAME(T, f, char *))
#define STRN(T, f) FIELD(T, f, STRING_NULL, NULL, NULL, SAME(T, f, char *))
#define BOOL(T, f) FIELD(T, f, BOOL, NULL, NULL, SAME(T, f, gboolean))
#define INT(T, f) FIELD(T, f, INT, NULL, NULL, SAME(T, f, gint64))
#define OPTINT(T, f) FIELD(T, f, OPT_INT, NULL, NULL, SAME(T, f, SZFriendsGtkOptInt))
#define NUM(T, f) FIELD(T, f, NUMBER, NULL, NULL, SAME(T, f, double))
#define ENUM(T, f, e) FIELD(T, f, ENUM, NULL, &e, sizeof(MEMBER(T, f)) == sizeof(int) && !SAME(T, f, gboolean))
#define OBJ(T, f, t) FIELD(T, f, OBJECT, &t, NULL, SAME(T, f, t##_ctype))
#define OBJN(T, f, t) FIELD(T, f, OBJECT_NULL, &t, NULL, SAME(T, f, t##_ctype *))
#define ARR(T, f, t) {#f, SZFRIENDS_GTK_FIELD_ARRAY, CHECKED(T, f, SAME(T, f, t##_ctype *)), &t, NULL, \
                      CHECKED(T, n_##f, SAME(T, n_##f, gsize))}
#define STRS(T, f) FIELD(T, f, STRINGS, NULL, NULL, SAME(T, f, char **))
#define MAP(T, f) FIELD(T, f, STRING_MAP, NULL, NULL, SAME(T, f, GHashTable *))
#define JSONOBJ(T, f) FIELD(T, f, JSON_OBJECT, NULL, NULL, SAME(T, f, JsonObject *))
/* Also names the table's C type, so later tables can check members that hold this struct. */
#define TYPE(storage, var, block, T)                                                                             \
    typedef T var##_ctype;                                                                                       \
    storage const SZFriendsGtkType var = {block, sizeof(T), var##_fields, G_N_ELEMENTS(var##_fields)}
#define NAMES(var, ...)                                                                                          \
    static const char *const var##_list[] = {__VA_ARGS__};                                                       \
    static const SZFriendsGtkEnumNames var = {var##_list, G_N_ELEMENTS(var##_list)}

#include "gtk/szfriends_gtk_schema_names.h"

/* ---- Shared objects ---- */

#define T SZFriendsGtkAvatar
static const SZFriendsGtkField avatar_fields[] = {ENUM(T, kind, avatar_kinds), STR(T, initials), STR(T, color),
                                                  INT(T, set), INT(T, index), STR(T, path)};
#undef T
TYPE(static, avatar, "type.avatar", SZFriendsGtkAvatar);
#define T SZFriendsGtkRoute
static const SZFriendsGtkField route_fields[] = {ENUM(T, kind, route_kinds), ENUM(T, method, route_methods),
                                                 STRN(T, label)};
#undef T
TYPE(static, route, "type.route", SZFriendsGtkRoute);
#define T SZFriendsGtkConfirm
static const SZFriendsGtkField confirm_fields[] = {STR(T, title), STR(T, body), STR(T, confirm_label),
                                                   STR(T, cancel_label), BOOL(T, destructive)};
#undef T
TYPE(static, confirm, "type.confirm", SZFriendsGtkConfirm);
#define T SZFriendsGtkArm
static const SZFriendsGtkField arm_fields[] = {STR(T, label), STR(T, accessibility_label), INT(T, seconds)};
#undef T
TYPE(static, arm, "type.arm", SZFriendsGtkArm);
#define T SZFriendsGtkAction
static const SZFriendsGtkField action_fields[] = {
    ENUM(T, action, actions), STR(T, label), ENUM(T, style, styles), STRN(T, note), OBJN(T, confirm, confirm),
    OBJN(T, arm, arm), STR(T, path), ENUM(T, settings_target, settings_targets), STR(T, friends_id),
    STR(T, identity_key), STR(T, name), STR(T, payload), STR(T, link_id), STR(T, device_id), STR(T, join_id)};
#undef T
TYPE(static, action, "type.action", SZFriendsGtkAction);
#define T SZFriendsGtkSegment
static const SZFriendsGtkField segment_fields[] = {STR(T, text), STRN(T, url), BOOL(T, emphasis), BOOL(T, match),
                                                   OPTINT(T, mention)};
#undef T
TYPE(static, segment, "type.segment", SZFriendsGtkSegment);
#define T SZFriendsGtkBack
static const SZFriendsGtkField back_fields[] = {INT(T, badge_count), STR(T, badge_label), STR(T, accessibility_label)};
#undef T
TYPE(static, back, "type.back", SZFriendsGtkBack);
#define T SZFriendsGtkFooter
static const SZFriendsGtkField footer_fields[] = {OBJ(T, avatar, avatar), STRN(T, name), STR(T, name_placeholder),
                                                  STR(T, id_label), STRN(T, id_note), STR(T, friends_id),
                                                  STR(T, add_label)};
#undef T
TYPE(static, footer, "type.footer", SZFriendsGtkFooter);
#define T SZFriendsGtkEmpty
static const SZFriendsGtkField empty_fields[] = {ENUM(T, kind, empty_kinds), STR(T, title), STRN(T, body)};
#undef T
TYPE(static, empty, "type.empty", SZFriendsGtkEmpty);

#include "gtk/szfriends_gtk_schema_devices.h"

/* ---- badge, list ---- */

#define T SZFriendsGtkBadgeSnapshot
static const SZFriendsGtkField szfriends_gtk_type_badge_snapshot_fields[] = {INT(T, count), STR(T, label),
                                                                             STR(T, accessibility_label)};
#undef T
TYPE(, szfriends_gtk_type_badge_snapshot, "snapshot.badge", SZFriendsGtkBadgeSnapshot);
#define T SZFriendsGtkBanner
static const SZFriendsGtkField banner_fields[] = {ENUM(T, kind, banner_kinds), STR(T, text), OBJN(T, action, action)};
#undef T
TYPE(static, banner, "type.banner", SZFriendsGtkBanner);
#define T SZFriendsGtkNamePrompt
static const SZFriendsGtkField name_prompt_fields[] = {STR(T, title), STR(T, placeholder), STR(T, note),
                                                       STRN(T, join_label)};
#undef T
TYPE(static, name_prompt, "type.name_prompt", SZFriendsGtkNamePrompt);
#define T SZFriendsGtkRowAction
static const SZFriendsGtkField row_action_fields[] = {ENUM(T, action, row_actions), ENUM(T, icon, row_icons),
                                                      STRN(T, title), STR(T, label), OBJN(T, arm, arm)};
#undef T
TYPE(static, row_action, "type.row_action", SZFriendsGtkRowAction);
#define T SZFriendsGtkWaiting
static const SZFriendsGtkField waiting_fields[] = {ENUM(T, kind, waiting_kinds), STR(T, label)};
#undef T
TYPE(static, waiting, "type.waiting", SZFriendsGtkWaiting);
#define T SZFriendsGtkListRow
static const SZFriendsGtkField list_row_fields[] = {
    STR(T, conversation_id), OBJ(T, avatar, avatar), STR(T, title), STR(T, subtitle), STR(T, time_label),
    OBJ(T, route, route), BOOL(T, unread), OBJN(T, waiting, waiting), BOOL(T, blocked), BOOL(T, id_confirmed),
    STRN(T, id_confirmed_label), ENUM(T, style, row_styles), STRN(T, drop_label), STRN(T, drop_refusal),
    STR(T, accessibility_label), ARR(T, actions, row_action), BOOL(T, mentionable), ENUM(T, kind, row_kinds)};
#undef T
TYPE(static, list_row, "type.list_row", SZFriendsGtkListRow);
#define T SZFriendsGtkListSnapshot
static const SZFriendsGtkField szfriends_gtk_type_list_snapshot_fields[] = {
    STR(T, query), OBJN(T, banner, banner), OBJN(T, name_prompt, name_prompt), ARR(T, rows, list_row),
    OBJN(T, empty, empty), OBJ(T, footer, footer), ENUM(T, state, list_states), OBJN(T, removed, device_removed),
    ARR(T, join_requests, join_request)};
#undef T
TYPE(, szfriends_gtk_type_list_snapshot, "snapshot.list", SZFriendsGtkListSnapshot);

/* ---- nearby ---- */

#define T SZFriendsGtkVisibility
static const SZFriendsGtkField visibility_fields[] = {
    ENUM(T, state, visibility_states), STRN(T, title), STRN(T, body), STRN(T, remaining_label),
    STRN(T, remaining_accessibility_label), STRN(T, deadline), OBJN(T, action, action)};
#undef T
TYPE(static, visibility, "type.visibility", SZFriendsGtkVisibility);
#define T SZFriendsGtkMethodStatus
static const SZFriendsGtkField method_state_fields[] = {ENUM(T, method, nearby_methods),
                                                        ENUM(T, state, method_states), STR(T, label)};
#undef T
TYPE(static, method_state, "type.method_state", SZFriendsGtkMethodStatus);
#define T SZFriendsGtkAlert
static const SZFriendsGtkField alert_fields[] = {STR(T, title), STR(T, body), OBJN(T, action, action)};
#undef T
TYPE(static, alert, "type.alert", SZFriendsGtkAlert);
#define T SZFriendsGtkNote
static const SZFriendsGtkField note_fields[] = {STR(T, text), OBJN(T, action, action)};
#undef T
TYPE(static, note, "type.note", SZFriendsGtkNote);
#define T SZFriendsGtkStatus
static const SZFriendsGtkField status_fields[] = {ENUM(T, kind, status_kinds), STR(T, label)};
#undef T
TYPE(static, status, "type.status", SZFriendsGtkStatus);
#define T SZFriendsGtkNearbyPerson
static const SZFriendsGtkField nearby_person_fields[] = {
    STRN(T, nearby_id), STRN(T, conversation_id), OBJ(T, avatar, avatar), STR(T, title), STR(T, subtitle),
    STRN(T, status_label), OBJN(T, action, action), STR(T, accessibility_label)};
#undef T
TYPE(static, nearby_person, "type.nearby_person", SZFriendsGtkNearbyPerson);
#define T SZFriendsGtkNearbySnapshot
static const SZFriendsGtkField szfriends_gtk_type_nearby_snapshot_fields[] = {
    STR(T, query), OBJ(T, visibility, visibility), ARR(T, methods, method_state), OBJN(T, alert, alert),
    OBJN(T, note, note), OBJN(T, status, status), ARR(T, people, nearby_person), OBJN(T, empty, empty),
    OBJ(T, footer, footer)};
#undef T
TYPE(, szfriends_gtk_type_nearby_snapshot, "snapshot.nearby", SZFriendsGtkNearbySnapshot);

/* ---- conversation ---- */

#define T SZFriendsGtkHeader
static const SZFriendsGtkField header_fields[] = {STR(T, title), STRN(T, subtitle), OBJ(T, route, route),
                                                  OBJ(T, avatar, avatar), BOOL(T, details_available),
                                                  STR(T, accessibility_label)};
#undef T
TYPE(static, header, "type.header", SZFriendsGtkHeader);
#define T SZFriendsGtkMessageStatus
static const SZFriendsGtkField message_status_fields[] = {ENUM(T, state, message_states), STR(T, label)};
#undef T
TYPE(static, message_status, "type.message_status", SZFriendsGtkMessageStatus);
#define T SZFriendsGtkFileInfo
static const SZFriendsGtkField file_info_fields[] = {STR(T, name), STR(T, kind_label), STR(T, size_label),
                                                     INT(T, size_bytes), STRN(T, path), STRN(T, type_identifier),
                                                     STRN(T, extension)};
#undef T
TYPE(static, file_info, "type.file_info", SZFriendsGtkFileInfo);
#define T SZFriendsGtkThumbnail
static const SZFriendsGtkField thumbnail_fields[] = {STR(T, path), INT(T, width), INT(T, height),
                                                     ENUM(T, source, thumbnail_sources)};
#undef T
TYPE(static, thumbnail, "type.thumbnail", SZFriendsGtkThumbnail);
#define T SZFriendsGtkMentionCard
static const SZFriendsGtkField mention_card_fields[] = {STR(T, title), STR(T, id_label), STRN(T, status_label),
                                                        STRN(T, conversation_id), ARR(T, actions, action)};
#undef T
TYPE(static, mention_card, "type.mention_card", SZFriendsGtkMentionCard);
#define T SZFriendsGtkMention
static const SZFriendsGtkField mention_fields[] = {STR(T, url), ENUM(T, kind, mention_kinds), STR(T, label),
                                                   STRN(T, tooltip), STRN(T, conversation_id),
                                                   OBJN(T, card, mention_card)};
#undef T
TYPE(static, mention, "type.mention", SZFriendsGtkMention);
#define T SZFriendsGtkProgress
static const SZFriendsGtkField progress_fields[] = {NUM(T, fraction), BOOL(T, determinate),
                                                    STR(T, accessibility_label)};
#undef T
TYPE(static, progress, "type.progress", SZFriendsGtkProgress);
#define T SZFriendsGtkConversationItem
static const SZFriendsGtkField item_fields[] = {
    ENUM(T, kind, item_kinds), STR(T, item_id), STR(T, label), STRN(T, time_label), ENUM(T, direction, directions),
    STR(T, text), ENUM(T, text_format, text_formats), ARR(T, segments, segment),
    OBJN(T, status, message_status), STRN(T, assistant_label), STR(T, transfer_id), OBJ(T, file, file_info),
    STR(T, meta_label), ENUM(T, state, transfer_states), STR(T, status_label), STRN(T, route_note),
    OBJN(T, progress, progress), OBJN(T, thumbnail, thumbnail), ARR(T, actions, action), ARR(T, mentions, mention),
    BOOL(T, highlighted), STR(T, accessibility_label)};
#undef T
TYPE(static, item, "type.item", SZFriendsGtkConversationItem);
#define T SZFriendsGtkRequestCard
static const SZFriendsGtkField request_card_fields[] = {
    ENUM(T, direction, request_directions), OBJ(T, avatar, avatar), STR(T, title), STR(T, subtitle),
    STRN(T, code_prompt), STRN(T, comparison_code), STRN(T, comparison_code_accessibility_label),
    ARR(T, actions, action), STRN(T, footnote)};
#undef T
TYPE(static, request_card, "type.request_card", SZFriendsGtkRequestCard);
#define T SZFriendsGtkComposer
static const SZFriendsGtkField composer_fields[] = {
    BOOL(T, visible), BOOL(T, enabled), STR(T, placeholder), ARR(T, hint, segment), STR(T, send_label),
    STRN(T, note), BOOL(T, accepts_drops), INT(T, max_text_bytes), STRN(T, mention_note)};
#undef T
TYPE(static, composer, "type.composer", SZFriendsGtkComposer);
#define T SZFriendsGtkConversationSnapshot
static const SZFriendsGtkField szfriends_gtk_type_conversation_snapshot_fields[] = {
    STR(T, conversation_id), OBJ(T, header, header), OBJ(T, back, back), STR(T, search_placeholder),
    BOOL(T, has_earlier), ARR(T, items, item), STRN(T, highlight_item_id), OBJN(T, request, request_card),
    OBJ(T, composer, composer)};
#undef T
TYPE(, szfriends_gtk_type_conversation_snapshot, "snapshot.conversation", SZFriendsGtkConversationSnapshot);

/* ---- details ---- */

#define T SZFriendsGtkVerification
static const SZFriendsGtkField verification_fields[] = {ENUM(T, state, verification_states), STR(T, label),
                                                        STRN(T, body), STRN(T, comparison_code),
                                                        OBJN(T, action, action)};
#undef T
TYPE(static, verification, "type.verification", SZFriendsGtkVerification);
#define T SZFriendsGtkAutoAccept
static const SZFriendsGtkField auto_accept_fields[] = {BOOL(T, available), BOOL(T, enabled), STR(T, title),
                                                       STR(T, body)};
#undef T
TYPE(static, auto_accept, "type.auto_accept", SZFriendsGtkAutoAccept);
#define T SZFriendsGtkReceived
static const SZFriendsGtkField received_fields[] = {STR(T, label), INT(T, count), OBJN(T, action, action)};
#undef T
TYPE(static, received, "type.received", SZFriendsGtkReceived);
#define T SZFriendsGtkKeyChange
static const SZFriendsGtkField key_change_fields[] = {STR(T, title), STR(T, body), ARR(T, actions, action)};
#undef T
TYPE(static, key_change, "type.key_change", SZFriendsGtkKeyChange);
#define T SZFriendsGtkDetailsSnapshot
static const SZFriendsGtkField szfriends_gtk_type_details_snapshot_fields[] = {
    STR(T, conversation_id), STR(T, title), OBJ(T, back, back), OBJ(T, avatar, avatar), OBJ(T, route, route),
    STRN(T, friends_id), STRN(T, id_label), BOOL(T, id_confirmed), STRN(T, id_confirmed_label),
    STRN(T, copy_id_accessibility_label), OBJ(T, verification, verification), OBJ(T, auto_accept, auto_accept),
    OBJN(T, received, received), OBJN(T, key_change, key_change), ARR(T, actions, action)};
#undef T
TYPE(, szfriends_gtk_type_details_snapshot, "snapshot.details", SZFriendsGtkDetailsSnapshot);

/* ---- profile ---- */

#define T SZFriendsGtkProfileName
static const SZFriendsGtkField profile_name_fields[] = {STR(T, label), STRN(T, value), STR(T, placeholder),
                                                        INT(T, max_length)};
#undef T
TYPE(static, profile_name, NULL, SZFriendsGtkProfileName);
#define T SZFriendsGtkProfilePicture
static const SZFriendsGtkField profile_picture_fields[] = {OBJ(T, avatar, avatar), STR(T, choose_label),
                                                           STR(T, own_picture_label), INT(T, animal_set),
                                                           OPTINT(T, selected_index)};
#undef T
TYPE(static, profile_picture, NULL, SZFriendsGtkProfilePicture);
#define T SZFriendsGtkProfileId
static const SZFriendsGtkField profile_id_fields[] = {STR(T, label), STR(T, friends_id), ENUM(T, state, id_states),
                                                      STRN(T, note), STR(T, copy_label), STRN(T, qr_label),
                                                      STRN(T, qr_payload)};
#undef T
TYPE(static, profile_id, NULL, SZFriendsGtkProfileId);
#define T SZFriendsGtkProfileAdd
static const SZFriendsGtkField profile_add_fields[] = {STR(T, label), STR(T, placeholder), STR(T, button_label),
                                                       STR(T, hint)};
#undef T
TYPE(static, profile_add, NULL, SZFriendsGtkProfileAdd);
#define T SZFriendsGtkFriendLink
static const SZFriendsGtkField friend_link_fields[] = {STR(T, label), STR(T, url), STR(T, note), STR(T, copy_label),
                                                       OBJ(T, reset, action)};
#undef T
TYPE(static, friend_link, NULL, SZFriendsGtkFriendLink);
#define T SZFriendsGtkDownloadLink
static const SZFriendsGtkField download_link_fields[] = {STR(T, link_id), STR(T, file_name), STR(T, downloads_label),
                                                         STR(T, expires_label), OBJ(T, revoke, action)};
#undef T
TYPE(static, download_link, NULL, SZFriendsGtkDownloadLink);
/* "friend" is the protocol's name; the member is friend_link, since `friend` is reserved in C++. */
#define T SZFriendsGtkProfileLinks
static const SZFriendsGtkField profile_links_fields[] = {
    STR(T, title), {"friend", SZFRIENDS_GTK_FIELD_OBJECT, CHECKED(T, friend_link, SAME(T, friend_link,
                    friend_link_ctype)), &friend_link, NULL, 0},
    STR(T, downloads_label), STRN(T, downloads_empty), ARR(T, downloads, download_link)};
#undef T
TYPE(static, profile_links, NULL, SZFriendsGtkProfileLinks);
#define T SZFriendsGtkProfileSnapshot
static const SZFriendsGtkField szfriends_gtk_type_profile_snapshot_fields[] = {
    STR(T, title), OBJ(T, back, back), OBJ(T, name, profile_name), OBJ(T, picture, profile_picture),
    OBJ(T, id, profile_id), OBJ(T, add, profile_add), OBJN(T, links, profile_links),
    OBJN(T, devices, profile_devices)};
#undef T
TYPE(, szfriends_gtk_type_profile_snapshot, "snapshot.profile", SZFriendsGtkProfileSnapshot);

/* ---- settings, message_status ---- */

#define T SZFriendsGtkSettingsName
static const SZFriendsGtkField settings_name_fields[] = {STR(T, label), STR(T, note), STRN(T, value),
                                                         STR(T, placeholder)};
#undef T
TYPE(static, settings_name, NULL, SZFriendsGtkSettingsName);
#define T SZFriendsGtkSettingsId
static const SZFriendsGtkField settings_id_fields[] = {STR(T, label), STR(T, note), STR(T, friends_id),
                                                       STR(T, copy_label)};
#undef T
TYPE(static, settings_id, NULL, SZFriendsGtkSettingsId);
#define T SZFriendsGtkSettingsReceived
static const SZFriendsGtkField settings_received_fields[] = {STR(T, label), STR(T, note), OBJ(T, action, action)};
#undef T
TYPE(static, settings_received, NULL, SZFriendsGtkSettingsReceived);
#define T SZFriendsGtkSettingsFriend
static const SZFriendsGtkField settings_friend_fields[] = {STR(T, conversation_id), STR(T, title),
                                                           OBJ(T, avatar, avatar), BOOL(T, enabled)};
#undef T
TYPE(static, settings_friend, NULL, SZFriendsGtkSettingsFriend);
#define T SZFriendsGtkSettingsAutoAccept
static const SZFriendsGtkField settings_auto_accept_fields[] = {STR(T, label), STR(T, note), STR(T, action_label),
                                                                ARR(T, friends, settings_friend)};
#undef T
TYPE(static, settings_auto_accept, NULL, SZFriendsGtkSettingsAutoAccept);
#define T SZFriendsGtkSettingsConfirmed
static const SZFriendsGtkField settings_confirmed_fields[] = {STR(T, label), STR(T, note), STR(T, action_label),
                                                              OBJ(T, confirm, confirm)};
#undef T
TYPE(static, settings_confirmed, NULL, SZFriendsGtkSettingsConfirmed);
#define T SZFriendsGtkSettingsNearby
static const SZFriendsGtkField settings_nearby_fields[] = {STR(T, label), STR(T, note), OBJN(T, action, action)};
#undef T
TYPE(static, settings_nearby, NULL, SZFriendsGtkSettingsNearby);
#define T SZFriendsGtkSettingsSnapshot
static const SZFriendsGtkField szfriends_gtk_type_settings_snapshot_fields[] = {
    OBJ(T, name, settings_name), OBJ(T, id, settings_id), OBJ(T, received, settings_received),
    OBJ(T, auto_accept, settings_auto_accept), OBJ(T, history, settings_confirmed),
    OBJ(T, reset, settings_confirmed), OBJN(T, nearby, settings_nearby)};
#undef T
TYPE(, szfriends_gtk_type_settings_snapshot, "snapshot.settings", SZFriendsGtkSettingsSnapshot);
#define T SZFriendsGtkMessageEntry
static const SZFriendsGtkField message_entry_fields[] = {STR(T, message_id), OBJ(T, status, message_status)};
#undef T
TYPE(static, message_entry, NULL, SZFriendsGtkMessageEntry);
#define T SZFriendsGtkMessageStatusSnapshot
static const SZFriendsGtkField szfriends_gtk_type_message_status_snapshot_fields[] = {
    ARR(T, messages, message_entry)};
#undef T
TYPE(, szfriends_gtk_type_message_status_snapshot, "snapshot.message_status", SZFriendsGtkMessageStatusSnapshot);

/* ---- frames ---- */

#define T SZFriendsGtkVersion
static const SZFriendsGtkField version_fields[] = {INT(T, major), INT(T, minor)};
#undef T
TYPE(static, version, NULL, SZFriendsGtkVersion);
#define T SZFriendsGtkHelperInfo
static const SZFriendsGtkField helper_info_fields[] = {STR(T, version), INT(T, build_number),
                                                       OBJ(T, protocol, version), INT(T, pid)};
#undef T
TYPE(static, helper_info, NULL, SZFriendsGtkHelperInfo);
#define T SZFriendsGtkLimits
static const SZFriendsGtkField limits_fields[] = {INT(T, max_frame_bytes), INT(T, max_message_bytes),
                                                  INT(T, max_files_per_send), INT(T, max_subscriptions)};
#undef T
TYPE(static, limits, NULL, SZFriendsGtkLimits);
#define T SZFriendsGtkWelcome
static const SZFriendsGtkField szfriends_gtk_type_welcome_fields[] = {
    STR(T, re), OBJ(T, protocol, version), OBJ(T, helper, helper_info), ENUM(T, handover, handovers),
    STRS(T, capabilities), OBJ(T, limits, limits), MAP(T, strings)};
#undef T
TYPE(, szfriends_gtk_type_welcome, "frame.welcome", SZFriendsGtkWelcome);
#define T SZFriendsGtkError
static const SZFriendsGtkField szfriends_gtk_type_error_fields[] = {STR(T, code), STRN(T, message),
                                                                    BOOL(T, retryable), JSONOBJ(T, details)};
#undef T
TYPE(, szfriends_gtk_type_error, "type.error", SZFriendsGtkError);
#define T SZFriendsGtkReply
static const SZFriendsGtkField szfriends_gtk_type_reply_fields[] = {
    STRN(T, re), BOOL(T, ok), JSONOBJ(T, result), OBJN(T, error, szfriends_gtk_type_error)};
#undef T
TYPE(, szfriends_gtk_type_reply, "frame.reply", SZFriendsGtkReply);
#define T SZFriendsGtkSuccessor
static const SZFriendsGtkField successor_fields[] = {STR(T, version), INT(T, build_number)};
#undef T
TYPE(static, successor, NULL, SZFriendsGtkSuccessor);
#define T SZFriendsGtkGoodbye
static const SZFriendsGtkField szfriends_gtk_type_goodbye_fields[] = {
    ENUM(T, reason, goodbye_reasons), STRN(T, message), OBJN(T, successor, successor),
    OBJN(T, error, szfriends_gtk_type_error)};
#undef T
TYPE(, szfriends_gtk_type_goodbye, "frame.goodbye", SZFriendsGtkGoodbye);
#define T SZFriendsGtkSnapshotFrame
static const SZFriendsGtkField szfriends_gtk_type_snapshot_frame_fields[] = {
    STR(T, subscription), STR(T, view), INT(T, rev), JSONOBJ(T, data)};
#undef T
TYPE(, szfriends_gtk_type_snapshot_frame, "frame.snapshot", SZFriendsGtkSnapshotFrame);

/* ---- results (a reply's `result`) ---- */

#define T SZFriendsGtkSubscribeResult
static const SZFriendsGtkField szfriends_gtk_type_subscribe_result_fields[] = {STR(T, subscription),
                                                                               STR(T, conversation_id)};
#undef T
TYPE(, szfriends_gtk_type_subscribe_result, "result.open_conversation", SZFriendsGtkSubscribeResult);
#define T SZFriendsGtkSendResult
static const SZFriendsGtkField szfriends_gtk_type_send_result_fields[] = {STR(T, message_id), STRS(T, transfer_ids)};
#undef T
TYPE(, szfriends_gtk_type_send_result, "result.send_message", SZFriendsGtkSendResult);
#define T SZFriendsGtkAddByIdResult
static const SZFriendsGtkField szfriends_gtk_type_add_by_id_result_fields[] = {STR(T, conversation_id),
                                                                               STR(T, message)};
#undef T
TYPE(, szfriends_gtk_type_add_by_id_result, "result.add_by_id", SZFriendsGtkAddByIdResult);
#define T SZFriendsGtkVisibilityResult
static const SZFriendsGtkField szfriends_gtk_type_visibility_result_fields[] = {STR(T, deadline)};
#undef T
TYPE(, szfriends_gtk_type_visibility_result, "result.start_visibility", SZFriendsGtkVisibilityResult);
#define T SZFriendsGtkSearchHit
static const SZFriendsGtkField search_hit_fields[] = {
    STR(T, conversation_id), STR(T, message_id), STR(T, conversation_title), OBJ(T, avatar, avatar),
    STR(T, sender_label), STR(T, time_label), ARR(T, excerpt, segment)};
#undef T
TYPE(static, search_hit, NULL, SZFriendsGtkSearchHit);
#define T SZFriendsGtkSearchResult
static const SZFriendsGtkField szfriends_gtk_type_search_result_fields[] = {
    ARR(T, results, search_hit), BOOL(T, more), STRN(T, empty_label)};
#undef T
TYPE(, szfriends_gtk_type_search_result, "result.search_messages", SZFriendsGtkSearchResult);
#define T SZFriendsGtkLinkCard
static const SZFriendsGtkField link_card_fields[] = {ENUM(T, kind, link_card_kinds), STR(T, title), STRN(T, subtitle),
                                                     STRN(T, note), OBJN(T, avatar, avatar), ARR(T, actions, action)};
#undef T
TYPE(static, link_card, NULL, SZFriendsGtkLinkCard);
#define T SZFriendsGtkOpenLinkResult
static const SZFriendsGtkField szfriends_gtk_type_open_link_result_fields[] = {OBJ(T, card, link_card)};
#undef T
TYPE(, szfriends_gtk_type_open_link_result, "result.open_link", SZFriendsGtkOpenLinkResult);
#define T SZFriendsGtkDownloadLinkResult
static const SZFriendsGtkField szfriends_gtk_type_download_link_result_fields[] = {STR(T, url), STR(T, link_id),
                                                                                   STR(T, message)};
#undef T
TYPE(, szfriends_gtk_type_download_link_result, "result.make_download_link", SZFriendsGtkDownloadLinkResult);

const SZFriendsGtkType *const szfriends_gtk_named_types[] = {
    &avatar, &route, &confirm, &arm, &action, &segment, &back, &footer, &empty,
    &szfriends_gtk_type_badge_snapshot, &banner, &name_prompt, &row_action, &waiting, &list_row,
    &szfriends_gtk_type_list_snapshot, &visibility, &method_state, &alert, &note, &status, &nearby_person,
    &szfriends_gtk_type_nearby_snapshot, &header, &message_status, &file_info, &thumbnail, &mention_card, &mention,
    &progress, &item, &request_card,
    &composer, &szfriends_gtk_type_conversation_snapshot, &verification, &auto_accept, &received, &key_change,
    &szfriends_gtk_type_details_snapshot, &szfriends_gtk_type_profile_snapshot, &szfriends_gtk_type_settings_snapshot,
    &szfriends_gtk_type_message_status_snapshot, &szfriends_gtk_type_welcome, &szfriends_gtk_type_error,
    &szfriends_gtk_type_reply, &szfriends_gtk_type_goodbye, &szfriends_gtk_type_snapshot_frame,
    &szfriends_gtk_type_subscribe_result, &szfriends_gtk_type_send_result, &szfriends_gtk_type_add_by_id_result,
    &szfriends_gtk_type_visibility_result, &szfriends_gtk_type_search_result, &szfriends_gtk_type_open_link_result,
    &szfriends_gtk_type_download_link_result, &device_rename, &device_row, &device_removed, &join_request,
    &join_id_field, &join_code_field, &szfriends_gtk_type_join_snapshot, NULL};

const SZFriendsGtkType *szfriends_gtk_view_type(const char *view) {
    static const struct { const char *view; const SZFriendsGtkType *type; } views[] = {
        {"badge", &szfriends_gtk_type_badge_snapshot}, {"list", &szfriends_gtk_type_list_snapshot},
        {"nearby", &szfriends_gtk_type_nearby_snapshot}, {"conversation", &szfriends_gtk_type_conversation_snapshot},
        {"details", &szfriends_gtk_type_details_snapshot}, {"profile", &szfriends_gtk_type_profile_snapshot},
        {"settings", &szfriends_gtk_type_settings_snapshot},
        {"message_status", &szfriends_gtk_type_message_status_snapshot}, {"join", &szfriends_gtk_type_join_snapshot}};
    for (gsize i = 0; view && i < G_N_ELEMENTS(views); i++)
        if (strcmp(views[i].view, view) == 0) return views[i].type;
    return NULL;
}

int szfriends_gtk_enum_value(const SZFriendsGtkEnumNames *enums, const char *name) {
    for (gsize i = 0; enums && name && i < enums->count; i++)
        if (enums->names[i] && strcmp(enums->names[i], name) == 0) return (int)i;
    return 0;
}

const char *szfriends_gtk_enum_name(const SZFriendsGtkEnumNames *enums, int value) {
    if (!enums || value < 0 || (gsize)value >= enums->count) return NULL;
    return enums->names[value];
}

const char *szfriends_gtk_action_name(SZFriendsGtkActionKind action) {
    return szfriends_gtk_enum_name(&actions, (int)action);
}
