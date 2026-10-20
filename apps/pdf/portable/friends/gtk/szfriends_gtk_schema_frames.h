/* The field tables of the protocol's frames and of a reply's results (PROTOCOL.md § Frames, § Results); internal,
 * included by szfriends_gtk_schema.c only, after the views' tables and before szfriends_gtk_named_types, which lists
 * them. */

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
