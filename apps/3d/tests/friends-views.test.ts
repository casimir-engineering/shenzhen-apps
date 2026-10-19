// The Friends panel against the pinned PROTOCOL fixtures (tests/fixtures/friends, copied from shenzhen-pdf at the
// commit friends.lock names; scripts/friends/setup-friends.sh --check holds them to it). Each snapshot is delivered
// through the real store the way the main process delivers it, the page is rendered to markup, and every string the
// snapshot gives for display must appear: the helper decides the words, the panel only shows them.
import { describe, expect, it } from "vitest";
import type { Action, Snapshot } from "../src/friends/protocol";
import { actionIntent, CLIENT_ACTIONS } from "../src/friends/actions";
import { escape, json, pageFor, render, snapshots } from "./friends-harness";

// Display strings in a snapshot: what the panel must show. Subtrees shown only on demand (a confirmation, an armed
// pill, a mention's card, a drag) or never (paths, ids, the Markdown source of a message) are left out.
const DISPLAY = new Set([
  "title",
  "subtitle",
  "label",
  "body",
  "note",
  "placeholder",
  "button_label",
  "button",
  "add_label",
  "name_placeholder",
  "id_label",
  "id_note",
  "time_label",
  "status_label",
  "route_note",
  "meta_label",
  "send_label",
  "accessibility_label",
  "message",
  "error",
  "choose_label",
  "own_picture_label",
  "copy_label",
  "downloads_label",
  "expires_label",
  "file_name",
  "detail",
  "code",
  "footnote",
  "code_prompt",
  "comparison_code",
  "remaining_label",
  "action_label",
  "join_label",
  "hint",
  "downloads_empty",
  "copy_id_accessibility_label",
  "id_confirmed_label",
  "remaining_accessibility_label",
  "code_note",
  "code_accessibility_label",
  "kind_label",
  "name",
  "value",
]);
// Shown only in some states, by the rules PROTOCOL.md gives: the placeholder until a name is chosen, Add by ID
// unless this computer was removed, a row's route unless something waits for an answer or its buttons show, the
// composer only while visible, and a message's segments rather than the Markdown its sender typed.
function hidden(
  record: Record<string, unknown>,
  key: string,
  root: Record<string, unknown>,
) {
  if (key === "name_placeholder") return record.name !== null;
  if (key === "add_label") return root.state === "device_removed";
  if (key === "route" && "waiting" in record)
    return Boolean(record.waiting) || (record.actions as unknown[]).length > 0;
  if (key === "composer")
    return (
      !(record.composer as { visible: boolean }).visible ||
      Boolean(record.request)
    );
  if (key === "text") return record.kind === "message";
  return false;
}
const SKIP = new Set([
  "arm",
  "confirm",
  "card",
  "drop_label",
  "drop_refusal",
  "rename",
  "mentions",
  "mention_note",
  "file",
  "segments",
  "search_placeholder",
  "auto_accept_friends",
  "picture_avatar",
]);
function displayStrings(
  value: unknown,
  key = "",
  parent = "",
  root = value as Record<string, unknown>,
): string[] {
  if (SKIP.has(key) || (parent === "auto_accept" && key === "friends"))
    return [];
  if (Array.isArray(value))
    return value.flatMap((item) => displayStrings(item, "", key, root));
  if (value && typeof value === "object") {
    const record = value as Record<string, unknown>;
    if (
      key === "" &&
      typeof record.action === "string" &&
      typeof record.label === "string"
    ) {
      // An action: its label shows, its fields are sent, never shown.
      return CLIENT_ACTIONS.has(record.action) ||
        actionIntent(record as unknown as Action, {
          conversation_id: "c",
          transfer_id: "t",
          item_id: "i",
          kind: "k",
        })
        ? [record.label as string]
        : [];
    }
    return Object.entries(record).flatMap(([name, child]) =>
      hidden(record, name, root)
        ? []
        : displayStrings(child, name, key === "" ? parent : key, root),
    );
  }
  if (
    typeof value === "string" &&
    value &&
    (DISPLAY.has(key) || key === "text")
  )
    return [value];
  return [];
}
function expectShown(html: string, data: unknown, file: string) {
  const missing = [...new Set(displayStrings(data))].filter(
    (text) => !html.includes(escape(text)),
  );
  expect(missing, file).toEqual([]);
}

describe("Friends views render every PROTOCOL fixture", () => {
  for (const file of snapshots) {
    const frame = json(`snapshots/${file}`) as Snapshot;
    const setup = pageFor(file, frame);
    if (!setup) continue;
    it(file, async () => {
      const { html } = await render(setup.byView, setup.holds, setup.page);
      expectShown(html, frame.data, file);
      // Plain text only: nothing from a snapshot becomes markup.
      expect(html).not.toMatch(/<script|javascript:/i);
    });
  }

  it("covers every view the panel draws", () => {
    const views = new Set(
      snapshots.map((file) => json(`snapshots/${file}`).view),
    );
    for (const view of [
      "list",
      "nearby",
      "conversation",
      "details",
      "profile",
      "settings",
      "join",
    ])
      expect(views).toContain(view);
  });
});
