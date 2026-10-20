// The Friends panel's behaviour against the pinned PROTOCOL fixtures: intents sent for actions, the drag strings,
// the composer's chips, resubscribing after a reconnect, the panel's own words, and staging the open model.
// friends-views.test.ts checks that every fixture renders.
import { describe, expect, it } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import type { Action } from "../src/friends/protocol";
import {
  actionIntent,
  CLIENT_ACTIONS,
  dropLabel,
  fill,
} from "../src/friends/actions";
import { FriendsStore } from "../src/friends/store";
import { serializeParts } from "../src/friends/Composer";
import {
  MAX_STAGED_NAME_BYTES,
  STAGE_FAILED,
  stagedProjectName,
  stageProject,
} from "../src/friends/staging";

import {
  escape,
  fakeBridge,
  json,
  pageFor,
  render,
  snapshots,
  status,
  welcome,
} from "./friends-harness";

describe("Friends view details", () => {
  it("sends each fixture action as its intent with the right ids, and client-side ones never", () => {
    const actions: Action[] = [];
    const walk = (value: unknown) => {
      if (Array.isArray(value)) value.forEach(walk);
      else if (value && typeof value === "object") {
        const record = value as Record<string, unknown>;
        if (
          typeof record.action === "string" &&
          typeof record.style === "string"
        )
          actions.push(record as unknown as Action);
        Object.values(record).forEach(walk);
      }
    };
    for (const file of snapshots) walk(json(`snapshots/${file}`).data);
    const context = {
      conversation_id: "c_1",
      transfer_id: "t_1",
      item_id: "m_1",
      kind: "id_changed",
      nearby_id: "n_1",
    };
    for (const action of actions) {
      if (CLIENT_ACTIONS.has(action.action)) {
        expect(actionIntent(action, context), action.action).toBeNull();
        continue;
      }
      const intent = actionIntent(action, context);
      expect(intent, action.action).not.toBeNull();
      expect(intent!.type).toBe(action.action);
    }
    expect(
      actionIntent(
        { action: "cancel_message", label: "", style: "link" },
        context,
      ),
    ).toEqual({ type: "cancel_message", fields: { message_id: "m_1" } });
    expect(
      actionIntent(
        { action: "reset_friends", label: "", style: "destructive" },
        {},
      ),
    ).toEqual({ type: "reset_friends", fields: { confirm: "reset" } });
    const mention = actions.find(
      (action) => action.action === "add_from_mention",
    )!;
    expect(actionIntent(mention, {})!.fields).toEqual({
      friends_id: mention.friends_id,
      identity_key: mention.identity_key,
      name: mention.name,
    });
  });

  it("fills only the drag strings' placeholders, with the named forms when every name is known", () => {
    const strings = welcome.strings;
    expect(dropLabel(strings, ["Gearbox.sz3d"])).toBe(
      fill(strings.drop_send_file, { name: "Gearbox.sz3d" }),
    );
    expect(dropLabel(strings, ["a.stl", "b.stl", "c.stl"])).toBe(
      fill(strings.drop_send_file_and_more, { name: "a.stl", count: "2" }),
    );
    expect(dropLabel(strings, [null, "b.stl"])).toBe(
      fill(strings.drop_send_many, { count: "2" }),
    );
    expect(dropLabel(strings, [null])).toBe(strings.drop_send_one);
    expect(dropLabel(null, ["a"])).toBeNull();
  });

  it("writes one U+FFFC per mention chip, in order", () => {
    expect(
      serializeParts([
        { text: "Ask " },
        { mention: "c_mei", label: "@Mei" },
        { text: " and " },
        { mention: "c_kenji", label: "@Kenji" },
      ]),
    ).toEqual({
      text: "Ask ￼ and ￼",
      mentions: [{ conversation_id: "c_mei" }, { conversation_id: "c_kenji" }],
    });
  });

  it("subscribes again after a reconnect and drops snapshots of a void subscription", async () => {
    const frame = json("snapshots/list.json");
    const bridge = fakeBridge({ list: frame });
    const store = new FriendsStore(bridge, status);
    const release = store.hold("list", {
      type: "subscribe",
      fields: { view: "list" },
    });
    await new Promise((resolve) => setTimeout(resolve, 0));
    const first = store.subscriptionId("list");
    expect(first).toBe("s_1");
    store.setStatus({
      ...status,
      state: "waiting",
      text: "Reconnecting to Friends…",
    });
    expect(store.subscriptionId("list")).toBeUndefined();
    store.handle({
      kind: "snapshot",
      frame: { ...frame, subscription: first!, rev: 99, data: { stale: true } },
    });
    expect(store.data<{ stale?: boolean }>("list")?.stale).toBeUndefined();
    store.setStatus(status);
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(store.subscriptionId("list")).toBe("s_2");
    release();
    expect(bridge.sent.at(-1)).toEqual({
      type: "unsubscribe",
      fields: { subscription: "s_2" },
    });
  });

  it("the composer's hint, the history and the request card come from the snapshot", async () => {
    const frame = json("snapshots/conversation-request-lena.json");
    const setup = pageFor("conversation-request-lena.json", frame)!;
    const { html } = await render(setup.byView, setup.holds, setup.page);
    expect(html).toContain(escape(frame.data.request.title));
    // A pending request replaces the history and the composer.
    expect(html).not.toContain("szf-composer");
  });
});

// The panel's own words: none, apart from the Settings switch and disclosure, which show while no helper runs
// (PROTOCOL.md § Principles). Every other visible string is a snapshot's or welcome.strings'.
describe("Friends copy", () => {
  it("has no hard-coded text outside the host's Settings words", () => {
    const directory = path.resolve(__dirname, "../src/friends");
    const allowed = [
      /^Enable Shenzhen Friends$/,
      // The Settings switch's tag: Friends is a beta, said where it is turned on, with or without a helper.
      /^Beta$/,
      /^Shenzhen 3D connects to the Friends server/,
      /^network address, your Friends ID/,
      /^files\.$/,
      // A link opened where Friends has no links: the app's own words, since the helper's refusal has none.
      /^Shenzhen 3D can’t open Friends links on this device yet\.\s+Open\s+the\s+link\s+on\s+a\s+computer\.$/,
    ];
    const found: string[] = [];
    for (const name of readdirSync(directory).filter((file) =>
      file.endsWith(".tsx"),
    )) {
      const source = readFileSync(path.join(directory, name), "utf8");
      // JSX text: after a tag's closing ">" (not a comparison or an arrow), up to the next tag.
      for (const match of source.matchAll(
        /(?<=[\w"'}]>)\s*([A-Za-z][^<>{}]*?)\s*</g,
      )) {
        const text = match[1].trim();
        if (
          /[A-Za-z]{2,}/.test(text) &&
          !allowed.some((pattern) => pattern.test(text)) &&
          !/[=;()]/.test(text)
        )
          found.push(`${name}: ${text}`);
      }
    }
    expect(found).toEqual([]);
  });
});

// The open model staged for Send project to a friend and `#`: the main process writes only a plain name of at most
// 200 bytes that does not start with a dot (electron/friends/host.cjs), so the name is made to fit first.
describe("Friends project staging", () => {
  const utf8 = (text: string) => new TextEncoder().encode(text).length;
  it("fits any model name to a name the main process accepts", () => {
    expect(stagedProjectName("Gearbox.sz3d")).toBe("Gearbox.sz3d");
    const long = "深圳精密齿轮箱装配体".repeat(7) + ".sz3d"; // 70 characters, 210 bytes before the extension
    const fitted = stagedProjectName(long);
    expect(utf8(fitted)).toBeLessThanOrEqual(MAX_STAGED_NAME_BYTES);
    expect(fitted.endsWith(".sz3d")).toBe(true);
    expect(fitted).not.toContain("�");
    expect(long.startsWith(fitted.slice(0, -5))).toBe(true);
    // Never splits a character made of several code points.
    const flags = stagedProjectName("🇨🇳".repeat(30) + ".sz3d");
    expect(utf8(flags)).toBeLessThanOrEqual(MAX_STAGED_NAME_BYTES);
    expect(flags.slice(0, -5).length % 4 === 0).toBe(true);
    expect(stagedProjectName(".hidden.sz3d")).toBe("hidden.sz3d");
    expect(stagedProjectName("...sz3d")).toBe("Model.sz3d");
    expect(stagedProjectName("a/b.sz3d")).toBe("a-b.sz3d");
  });

  it("stages the fitted name and says a failure in a plain sentence", async () => {
    const staged: string[] = [];
    const build = async () => ({
      blob: new Blob([new Uint8Array([1])]),
      name: "齿".repeat(80) + ".sz3d",
    });
    const errors: string[] = [];
    const file = await stageProject(
      {
        stage: async (name) => {
          staged.push(name);
          return `/out/${name}`;
        },
      },
      build,
      (message) => errors.push(message),
    );
    expect(utf8(staged[0]!)).toBeLessThanOrEqual(MAX_STAGED_NAME_BYTES);
    expect(file.display_name).toBe(staged[0]);
    expect(errors).toEqual([]);
    await expect(
      stageProject(
        {
          stage: async () => {
            throw Error(
              "Error invoking remote method 'shenzhen-friends': Error: Invalid project name",
            );
          },
        },
        build,
        (message) => errors.push(message),
      ),
    ).rejects.toThrow();
    expect(errors).toEqual([STAGE_FAILED]);
    expect(STAGE_FAILED).not.toMatch(/invoke|remote|method|Invalid|Error/);
  });
});
