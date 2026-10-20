// What the panel does with the view contract's values (protocol.ts): an action's intent and fields, the client-side
// actions, the drag strings' placeholders and the composer's byte count.
import type { Action, Strings } from "./protocol";

/** Intents that carry an action's own fields (PROTOCOL.md § Shared objects, Action), and which fields. */
export function actionIntent(
  action: Action,
  context: {
    conversation_id?: string;
    transfer_id?: string;
    item_id?: string;
    kind?: string;
    nearby_id?: string;
  },
): { type: string; fields: Record<string, unknown> } | null {
  const own = (keys: (keyof Action)[]) =>
    Object.fromEntries(keys.map((key) => [key, action[key]]));
  switch (action.action) {
    case "accept_request":
    case "decline_request":
    case "cancel_request":
    case "block":
    case "unblock":
    case "remove_friend":
    case "mark_verified":
    case "accept_key_change":
      return context.conversation_id
        ? {
            type: action.action,
            fields: { conversation_id: context.conversation_id },
          }
        : null;
    case "delete_history":
      return {
        type: action.action,
        fields: context.conversation_id
          ? { conversation_id: context.conversation_id }
          : {},
      };
    case "accept_offer":
    case "decline_offer":
    case "cancel_transfer":
    case "fetch_from_device":
      return context.transfer_id
        ? { type: action.action, fields: { transfer_id: context.transfer_id } }
        : null;
    case "cancel_message":
      return context.item_id
        ? { type: action.action, fields: { message_id: context.item_id } }
        : null;
    case "retry_item":
      return context.item_id
        ? { type: action.action, fields: { item_id: context.item_id } }
        : null;
    case "send_request":
      return context.nearby_id
        ? { type: action.action, fields: { nearby_id: context.nearby_id } }
        : null;
    case "dismiss_banner":
      return context.kind
        ? { type: action.action, fields: { kind: context.kind } }
        : null;
    case "start_visibility":
    case "stop_visibility":
    case "reset_friend_link":
    case "cancel_join":
    // Nearby's Allow and Try Again: the intent Friends sends when it opens (PROTOCOL.md § nearby).
    case "activate":
      return { type: action.action, fields: {} };
    case "reset_friends":
      return { type: action.action, fields: { confirm: "reset" } };
    case "add_from_mention":
      return {
        type: action.action,
        fields: own(["friends_id", "identity_key", "name"]),
      };
    case "add_from_link":
    case "receive_link":
      return { type: action.action, fields: own(["payload"]) };
    case "revoke_link":
      return { type: action.action, fields: own(["link_id"]) };
    case "revoke_device":
      return { type: action.action, fields: own(["device_id"]) };
    case "approve_join":
    case "deny_join":
      return { type: action.action, fields: own(["join_id"]) };
    case "join_profile":
      return { type: action.action, fields: own(["friends_id"]) };
    default:
      return null;
  }
}

/** Client-side actions: handled by the host, never sent (PROTOCOL.md § Intents, client-side actions). */
export const CLIENT_ACTIONS = new Set([
  "open_file",
  "show_file",
  "open_settings",
  "choose_received_folder",
]);

/** The drag strings' placeholders, the only formatting views do (PROTOCOL.md § Static strings). */
export function dropLabel(
  strings: Strings | null,
  names: (string | null)[],
): string | null {
  const count = names.length;
  if (!strings || count < 1) return null;
  const known = names.every((name): name is string => Boolean(name));
  if (count === 1)
    return known
      ? fill(strings.drop_send_file, { name: names[0]! })
      : (strings.drop_send_one ?? null);
  return known
    ? fill(strings.drop_send_file_and_more, {
        name: names[0]!,
        count: String(count - 1),
      })
    : fill(strings.drop_send_many, { count: String(count) });
}
export function fill(
  template: string | undefined,
  values: Record<string, string>,
): string | null {
  if (!template) return null;
  return template.replace(
    /\{(\w+)\}/g,
    (match, key: string) => values[key] ?? match,
  );
}

/** UTF-8 byte length, for the composer's max_text_bytes. */
export function utf8Length(text: string): number {
  return new TextEncoder().encode(text).length;
}
