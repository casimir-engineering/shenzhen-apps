/* The enum names of szfriends_gtk_schema.c's tables, as PROTOCOL.md spells them (internal; included by that file
 * only, after its NAMES macro). Index = the C enum's value; names[0] is NULL where 0 means unknown. */

NAMES(avatar_kinds, NULL, "animal", "image", "placeholder");
NAMES(route_kinds, NULL, "local", "online", "offline", "none", "connecting");
NAMES(route_methods, NULL, "lan", "p2p_wifi", "bluetooth", "internet", "relay");
NAMES(actions, NULL, "accept_request", "decline_request", "cancel_request", "block", "unblock", "remove_friend",
      "send_request", "add_from_mention", "accept_offer", "decline_offer", "cancel_transfer", "cancel_message",
      "retry_item", "mark_verified", "accept_key_change", "dismiss_banner", "start_visibility", "stop_visibility",
      "reset_friends", "delete_history", "open_file", "show_file", "open_settings", "add_from_link", "receive_link",
      "reset_friend_link", "revoke_link", "revoke_device", "fetch_from_device", "join_profile", "cancel_join",
      "approve_join", "deny_join", "activate", "choose_received_folder", "fetch_from_friend", "open_join",
      "allow_notifications", "boost_transfer", "skip_boost");
NAMES(action_thens, NULL, "open_join");
NAMES(confirm_option_names, NULL, "delete_history");
NAMES(styles, NULL, "primary", "secondary", "link", "destructive");
NAMES(settings_targets, NULL, "local_network_privacy", "bluetooth_privacy", "bluetooth", "wifi", "notifications");
/* Which banner a dismiss_banner action dismisses (PROTOCOL.md type.action `kind`); absent means id_changed. */
NAMES(dismiss_kinds, NULL, "id_changed", "notifications");
NAMES(empty_kinds, NULL, "searching", "nobody", "unavailable", "no_match");
NAMES(banner_kinds, NULL, "id_changed", "identity_unavailable", "update_required", "notifications");
NAMES(row_styles, "normal", "muted");
NAMES(row_icons, NULL, "accept", "decline", "block");
/* A row's buttons share SZFriendsGtkActionKind, but only these three may sit on a row (PROTOCOL.md type.row_action):
 * any other name there reads as unknown, so the row hides it. */
NAMES(row_actions, NULL, "accept_request", "decline_request", NULL, "block");
NAMES(waiting_kinds, NULL, "request", "offer", "key_change");
NAMES(visibility_states, NULL, "hidden", "visible", "unavailable");
NAMES(nearby_methods, NULL, "network", "bluetooth");
NAMES(method_states, NULL, "not_asked", "starting", "working", "denied", "radio_off", "unavailable");
NAMES(status_kinds, NULL, "searching");
NAMES(item_kinds, NULL, "day", "message", "transfer", "event");
NAMES(directions, NULL, "in", "out");
NAMES(text_formats, NULL, "markdown");
NAMES(message_states, NULL, "queued", "connecting", "sending", "delivered", "failed", "cancelled");
NAMES(transfer_states, NULL, "queued", "offered", "waiting_for_you", "sending", "receiving", "delivered", "received",
      "declined", "cancelled", "failed", "on_device", "fetching", "missing", "gone");
NAMES(request_directions, NULL, "incoming", "outgoing");
NAMES(verification_states, NULL, "verified", "unverified");
NAMES(id_states, NULL, "unreserved", "reserved", "changed", "unavailable");
NAMES(goodbye_reasons, NULL, "handover", "shutdown", "protocol_error", "reset", "too_many_clients");
NAMES(handovers, NULL, "none", "scheduled");
NAMES(mention_kinds, NULL, "friend", "you", "stranger");
NAMES(thumbnail_sources, NULL, "sender", "local");
NAMES(received_sources, NULL, "friend", "link", "device");

NAMES(link_card_kinds, NULL, "friend", "download");
/* Several computers (PROTOCOL.md § Devices, § Joining). */
NAMES(list_states, NULL, "normal", "device_removed");
NAMES(row_kinds, NULL, "person", "you");
NAMES(device_states, NULL, "connected", "not_connected", "never_connected");
NAMES(join_request_states, NULL, "waiting", "approved");
NAMES(join_states, NULL, "idle", "waiting", "checking", "wrong_code", "not_reached", "denied", "expired",
      "too_many_attempts", "joined", "unavailable");
