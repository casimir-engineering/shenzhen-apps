/* The field tables of szfriends_gtk_snapshot_devices.h (PROTOCOL.md § Devices, § Joining); internal, included by
 * szfriends_gtk_schema.c only, after the action table and before the list's and the profile's, which use them. */

#define T SZFriendsGtkDeviceRename
static const SZFriendsGtkField device_rename_fields[] = {STR(T, label), STR(T, placeholder), STR(T, button_label),
                                                         INT(T, max_bytes)};
#undef T
TYPE(static, device_rename, "type.device_rename", SZFriendsGtkDeviceRename);
#define T SZFriendsGtkDeviceRow
static const SZFriendsGtkField device_row_fields[] = {
    STR(T, device_id), STR(T, name), STR(T, system), STR(T, last_connected), STR(T, detail), BOOL(T, this_computer),
    ENUM(T, state, device_states), STR(T, accessibility_label), OBJN(T, rename, device_rename),
    OBJN(T, remove, action)};
#undef T
TYPE(static, device_row, "type.device_row", SZFriendsGtkDeviceRow);
#define T SZFriendsGtkProfileDevices
static const SZFriendsGtkField profile_devices_fields[] = {STR(T, title), STR(T, note), ARR(T, rows, device_row)};
#undef T
TYPE(static, profile_devices, NULL, SZFriendsGtkProfileDevices);
#define T SZFriendsGtkDeviceRemoved
static const SZFriendsGtkField device_removed_fields[] = {STR(T, title), STR(T, body), OBJ(T, action, action)};
#undef T
TYPE(static, device_removed, "type.device_removed", SZFriendsGtkDeviceRemoved);
#define T SZFriendsGtkJoinRequest
static const SZFriendsGtkField join_request_fields[] = {
    STR(T, join_id), ENUM(T, state, join_request_states), STR(T, title), STR(T, subtitle), STRN(T, code),
    STRN(T, code_accessibility_label), STRN(T, code_note), ARR(T, actions, action), STR(T, accessibility_label)};
#undef T
TYPE(static, join_request, "type.join_request", SZFriendsGtkJoinRequest);
#define T SZFriendsGtkJoinIdField
static const SZFriendsGtkField join_id_field_fields[] = {STR(T, placeholder), STR(T, button)};
#undef T
TYPE(static, join_id_field, "type.join_id_field", SZFriendsGtkJoinIdField);
#define T SZFriendsGtkJoinCodeField
static const SZFriendsGtkField join_code_field_fields[] = {INT(T, length), STR(T, placeholder), STR(T, button),
                                                           BOOL(T, enabled)};
#undef T
TYPE(static, join_code_field, "type.join_code_field", SZFriendsGtkJoinCodeField);
#define T SZFriendsGtkJoinSnapshot
static const SZFriendsGtkField szfriends_gtk_type_join_snapshot_fields[] = {
    ENUM(T, state, join_states), STR(T, title), STRN(T, message), STRN(T, friends_id),
    OBJN(T, id_field, join_id_field), OBJN(T, code_field, join_code_field), STRN(T, error), ARR(T, actions, action)};
#undef T
TYPE(, szfriends_gtk_type_join_snapshot, "snapshot.join", SZFriendsGtkJoinSnapshot);
