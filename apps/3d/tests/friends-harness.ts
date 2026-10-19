// What the Friends panel's tests share: the pinned PROTOCOL fixtures (tests/fixtures/friends), a fake bridge that
// answers with them, the real store, a page rendered to markup with its panel context, and which page draws each
// snapshot.
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { createElement, type ReactElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { FriendsBridge, FriendsEvent } from "../src/friends/bridge";
import type { FriendsStatus, Snapshot } from "../src/friends/protocol";
import { FriendsStore } from "../src/friends/store";
import { Panel, type PanelContext } from "../src/friends/parts";
import { ListPage } from "../src/friends/ListPage";
import { ConversationPage } from "../src/friends/ConversationPage";
import { DetailsPage, JoinPage } from "../src/friends/MorePages";
import { ProfilePage } from "../src/friends/ProfilePage";
import { SettingsBody } from "../src/friends/FriendsPanel";

const root = path.resolve(__dirname, "fixtures/friends");
export const json = (file: string) =>
  JSON.parse(readFileSync(path.join(root, file), "utf8"));
export const welcome = json("frames/welcome.json");
export const snapshots = readdirSync(path.join(root, "snapshots")).filter(
  (name) => name.endsWith(".json"),
);
export const status: FriendsStatus = {
  available: true,
  enabled: true,
  attached: true,
  state: "ready",
  text: "",
  strings: welcome.strings,
  capabilities: welcome.capabilities,
  limits: welcome.limits,
  badge: null,
};

/** A bridge that answers each subscription with one fixture, as the main process hands over the first snapshot. */
export function fakeBridge(byView: Record<string, Snapshot>) {
  const sent: { type: string; fields?: Record<string, unknown> }[] = [];
  let next = 0;
  const bridge = {
    sent,
    async send(type: string, fields?: Record<string, unknown>) {
      sent.push({ type, fields });
      const view =
        type === "open_conversation"
          ? "conversation"
          : (fields?.view as string);
      const frame = byView[view];
      const subscription = `s_${++next}`;
      if ((type === "subscribe" || type === "open_conversation") && frame)
        return {
          reply: {
            type: "reply" as const,
            re: String(next),
            ok: true,
            result: { subscription },
          },
          snapshot: { ...frame, subscription },
        };
      return {
        reply: {
          type: "reply" as const,
          re: String(next),
          ok: true,
          result: {},
        },
      };
    },
    subscribe: (_listener: (event: FriendsEvent) => void) => () => {},
    pathsForFiles: () => [],
    image: async () => null,
    animal: async () => null,
    animals: async () => null,
  } as unknown as FriendsBridge & { sent: typeof sent };
  return bridge;
}

export async function render(
  byView: Record<string, Snapshot>,
  holds: [string, Record<string, unknown>][],
  page: ReactElement,
) {
  const bridge = fakeBridge(byView);
  const store = new FriendsStore(bridge, status);
  for (const [key, intent] of holds) store.hold(key, intent as never);
  await new Promise((resolve) => setTimeout(resolve, 0));
  const context: PanelContext = {
    store,
    bridge,
    report: () => {},
    openConversation: () => {},
    confirm: async () => true,
  };
  return {
    html: renderToStaticMarkup(
      createElement(Panel.Provider, { value: context }, page),
    ),
    bridge,
  };
}

export const escape = (text: string) =>
  text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#x27;");

export const list = json("snapshots/list.json");
export function pageFor(
  file: string,
  frame: Snapshot,
): {
  holds: [string, Record<string, unknown>][];
  page: ReactElement;
  byView: Record<string, Snapshot>;
} | null {
  const data = frame.data as Record<string, unknown>;
  const none = () => {};
  switch (frame.view) {
    case "list":
      return {
        byView: { list: frame },
        holds: [["list", { type: "subscribe", fields: { view: "list" } }]],
        page: createElement(ListPage, {
          tab: "friends",
          onTab: none,
          outgoing: null,
          onCancelOutgoing: none,
          onSent: none,
          onProfile: none,
          onJoin: none,
        }),
      };
    case "nearby":
      return {
        byView: { list, nearby: frame },
        holds: [
          ["list", { type: "subscribe", fields: { view: "list" } }],
          ["nearby", { type: "subscribe", fields: { view: "nearby" } }],
        ],
        page: createElement(ListPage, {
          tab: "nearby",
          onTab: none,
          outgoing: null,
          onCancelOutgoing: none,
          onSent: none,
          onProfile: none,
          onJoin: none,
        }),
      };
    case "conversation": {
      const id = data.conversation_id as string;
      return {
        byView: { conversation: frame },
        holds: [
          [
            `conversation:${id}:`,
            { type: "open_conversation", fields: { conversation_id: id } },
          ],
        ],
        page: createElement(ConversationPage, {
          conversationId: id,
          attach: null,
          onBack: none,
          onDetails: none,
        }),
      };
    }
    case "details": {
      const id = data.conversation_id as string;
      return {
        byView: { details: frame },
        holds: [
          [
            `details:${id}`,
            {
              type: "subscribe",
              fields: { view: "details", params: { conversation_id: id } },
            },
          ],
        ],
        page: createElement(DetailsPage, { conversationId: id, onBack: none }),
      };
    }
    case "profile":
      return {
        byView: { profile: frame },
        holds: [
          ["profile", { type: "subscribe", fields: { view: "profile" } }],
        ],
        page: createElement(ProfilePage, { onBack: none }),
      };
    case "settings":
      return {
        byView: { settings: frame },
        holds: [
          ["settings", { type: "subscribe", fields: { view: "settings" } }],
        ],
        page: createElement(SettingsBody),
      };
    case "join":
      return {
        byView: { join: frame },
        holds: [["join", { type: "subscribe", fields: { view: "join" } }]],
        page: createElement(JoinPage, { onBack: none }),
      };
    default:
      // badge is the header button's; message_status is for host surfaces Shenzhen 3D does not have.
      return null;
  }
}
