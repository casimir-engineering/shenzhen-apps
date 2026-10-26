// Where a conversation's history goes as items arrive (PROTOCOL.md § Views, conversation): to its end when the person
// sends something, from wherever they had scrolled; nowhere when they read above while the friend's messages arrive
// below, which a pill over the bottom counts instead (the static strings new_message and new_messages). Pure, so the
// rule is tested without a layout; ConversationPage applies it to the scroller.
import type { Strings } from "./protocol";

type Item = { item_id: string; kind: string; direction?: string | null };

export type Follow = {
  /** The newest item of the last snapshot. */
  newest: string | null;
  /** The friend's items that arrived below while the person read above, and the first of them. */
  unseen: number;
  firstUnseen: string | null;
};

export const NO_FOLLOW: Follow = { newest: null, unseen: 0, firstUnseen: null };

/** A snapshot's items against the last: whether to go to the end (the person sent something), and the new count. */
export function noteItems(
  follow: Follow,
  items: readonly Item[],
  atBottom: boolean,
): { follow: Follow; toEnd: boolean } {
  const newest = items.length ? items[items.length - 1].item_id : null;
  const index = follow.newest
    ? items.findIndex((item) => item.item_id === follow.newest)
    : -1;
  // The first snapshot, or a history replaced (another conversation, a search): nothing arrived below.
  if (index < 0) return { follow: { ...follow, newest }, toEnd: false };
  const arrived = items.slice(index + 1);
  if (arrived.some((item) => item.direction === "out"))
    return { follow: { newest, unseen: 0, firstUnseen: null }, toEnd: true };
  if (atBottom) return { follow: { ...follow, newest }, toEnd: false };
  const fromFriend = arrived.filter(
    (item) =>
      item.direction === "in" &&
      (item.kind === "message" || item.kind === "transfer"),
  );
  return {
    follow: {
      newest,
      unseen: follow.unseen + fromFriend.length,
      firstUnseen: follow.firstUnseen ?? fromFriend[0]?.item_id ?? null,
    },
    toEnd: false,
  };
}

/** The pill's words: the helper's, or nothing (PROTOCOL.md § Static strings: never invent text). */
export function pillTitle(strings: Strings, unseen: number): string | null {
  if (unseen === 1) return strings.new_message || null;
  if (unseen > 1)
    return strings.new_messages
      ? strings.new_messages.replace("{count}", String(unseen))
      : null;
  return null;
}
