// System notifications in Shenzhen 3D's panel (PROTOCOL.md § Notifications): set_focus sent only when the
// conversation in front changes, the list's notifications card with Turn On and Not Now, Settings' Notifications
// switches, and a notification's URL opening the dropdown on its conversation. Hidden: no window, no DOM.
import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import type { Action, Snapshot } from "../src/friends/protocol";
import type { SettingsData } from "../src/friends/protocol";
import { actionIntent } from "../src/friends/actions";
import { FriendsStore } from "../src/friends/store";
import { runAction, type PanelContext } from "../src/friends/parts";
import {
  notificationSwitches,
  setNotification,
  stackFor,
  watchWindowFocus,
} from "../src/friends/FriendsPanel";
import { pendingOpen, routeEvent } from "../src/friends/status";
import {
  escape,
  fakeBridge,
  json,
  pageFor,
  render,
  status,
} from "./friends-harness";

const own = (file: string): Snapshot =>
  JSON.parse(
    readFileSync(
      path.resolve(__dirname, "fixtures/notif-views-3d", file),
      "utf8",
    ),
  );
const withNotifications = {
  ...status,
  capabilities: [...status.capabilities, "notifications"],
};
const offline = { ...withNotifications, state: "connecting" as const };
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const focusSent = (bridge: ReturnType<typeof fakeBridge>) =>
  bridge.sent
    .filter((intent) => intent.type === "set_focus")
    .map((intent) => intent.fields?.conversation_id);
function panelFor(store: FriendsStore): PanelContext {
  return {
    store,
    bridge: store.bridge,
    report: () => {},
    openConversation: () => {},
    confirm: async () => ({ option: false }),
    openJoin: () => {},
  };
}

describe("set_focus", () => {
  it("is sent only when the conversation in front changes, and again after a reconnect", async () => {
    const bridge = fakeBridge({});
    const store = new FriendsStore(bridge, withNotifications);
    store.setFocus("c_mei");
    store.setFocus("c_mei");
    store.setFocus(null);
    store.setFocus(null);
    store.setFocus("c_kenji");
    await tick();
    expect(focusSent(bridge)).toEqual(["c_mei", null, "c_kenji"]);
    // The helper forgets this connection's focus when it closes: the conversation still in front is said again.
    store.setStatus(offline);
    store.setFocus("c_mei");
    expect(focusSent(bridge)).toHaveLength(3);
    store.setStatus(withNotifications);
    await tick();
    expect(focusSent(bridge)).toEqual(["c_mei", null, "c_kenji", "c_mei"]);
    // Nothing in front when it reconnects: nothing to say.
    store.setFocus(null);
    store.setStatus(offline);
    store.setStatus(withNotifications);
    await tick();
    expect(focusSent(bridge)).toEqual([
      "c_mei",
      null,
      "c_kenji",
      "c_mei",
      null,
    ]);
  });

  it("is never sent to a helper that does not post notifications", async () => {
    const bridge = fakeBridge({});
    const store = new FriendsStore(bridge, status);
    store.setFocus("c_mei");
    store.setFocus(null);
    await tick();
    expect(focusSent(bridge)).toEqual([]);
  });

  it("follows the window: visible and focused, or not", () => {
    let hasFocus = true;
    const doc = Object.assign(new EventTarget(), {
      visibilityState: "visible" as DocumentVisibilityState,
      hasFocus: () => hasFocus,
    });
    const win = new EventTarget();
    const seen: boolean[] = [];
    const stop = watchWindowFocus((focused) => seen.push(focused), doc, win);
    hasFocus = false;
    win.dispatchEvent(new Event("blur"));
    hasFocus = true;
    win.dispatchEvent(new Event("focus"));
    doc.visibilityState = "hidden";
    doc.dispatchEvent(new Event("visibilitychange"));
    expect(seen).toEqual([true, false, true, false]);
    stop();
    doc.visibilityState = "visible";
    win.dispatchEvent(new Event("focus"));
    expect(seen).toHaveLength(4);
  });
});

describe("the list's notifications card", () => {
  const frame = json("snapshots/views-notifications-list.json") as Snapshot;
  const banner = (frame.data as { banner: { action: Action; dismiss: Action } })
    .banner;

  it("shows its text with Turn On and Not Now", async () => {
    const view = pageFor("views-notifications-list.json", frame)!;
    const { html } = await render(view.byView, view.holds, view.page);
    expect(html).toContain(
      escape("Get a notification when friends send you a message or a file."),
    );
    expect(html).toContain(">Turn On<");
    expect(html).toContain(">Not Now<");
  });

  it("Turn On sends allow_notifications and Not Now dismisses the notifications card", async () => {
    const context = { kind: "notifications" };
    expect(actionIntent(banner.action, context)).toEqual({
      type: "allow_notifications",
      fields: {},
    });
    expect(actionIntent(banner.dismiss, context)).toEqual({
      type: "dismiss_banner",
      fields: { kind: "notifications" },
    });
    // The action's own kind wins; id_changed's notice carries none and takes its banner's.
    expect(
      actionIntent(banner.dismiss, { kind: "id_changed" })?.fields,
    ).toEqual({ kind: "notifications" });
    expect(
      actionIntent(
        { action: "dismiss_banner", label: "OK", style: "secondary" },
        { kind: "id_changed" },
      )?.fields,
    ).toEqual({ kind: "id_changed" });
    const bridge = fakeBridge({});
    const panel = panelFor(new FriendsStore(bridge, withNotifications));
    await runAction(panel, banner.action, context);
    await runAction(panel, banner.dismiss, context);
    expect(bridge.sent).toEqual([
      { type: "allow_notifications", fields: {} },
      { type: "dismiss_banner", fields: { kind: "notifications" } },
    ]);
  });
});

describe("Settings' Notifications", () => {
  const settingsPage = async (frame: Snapshot) => {
    const view = pageFor("settings", frame)!;
    return (await render(view.byView, view.holds, view.page)).html;
  };

  it("shows the switches, notes and the action the helper sends, and nothing it leaves out", async () => {
    const mac = json("snapshots/views-notifications-settings.json") as Snapshot;
    const html = await settingsPage(mac);
    for (const text of [
      "Notifications",
      "Show notifications",
      "Show message text",
      "When this is off, notifications say who sent something, not what it says.",
      "Notifications from Shenzhen Friends are off in System Settings.",
      "Open System Settings",
    ])
      expect(html).toContain(escape(text));
    expect(html).toContain('name="enabled" checked=""');
    expect(html).not.toContain('name="preview" checked=""');
    expect(html).not.toContain('name="background"');

    const android = await settingsPage(
      own("notif-views-3d-settings-android.json"),
    );
    for (const text of [
      "Friends hasn’t asked to show notifications yet.",
      ">Allow<",
      "Stay reachable in the background",
      "uses more battery all day",
    ])
      expect(android).toContain(text.startsWith(">") ? text : escape(text));
    expect(android).toContain('name="background"');

    const quiet = await settingsPage(own("notif-views-3d-settings-quiet.json"));
    expect(quiet).toContain('data-szfriends="notifications"');
    expect(quiet).not.toContain('name="background"');
    expect(quiet).not.toContain("Open System Settings");
    expect(quiet).not.toContain('name="enabled" checked=""');
  });

  it("each switch sends set_notifications with that field alone", async () => {
    const data = own("notif-views-3d-settings-android.json")
      .data as SettingsData;
    expect(
      notificationSwitches(data.notifications!).map(({ field, value }) => [
        field,
        value,
      ]),
    ).toEqual([
      ["enabled", true],
      ["preview", true],
      ["background", false],
    ]);
    const bridge = fakeBridge({});
    const panel = panelFor(new FriendsStore(bridge, withNotifications));
    await setNotification(panel, "preview", false);
    await setNotification(panel, "background", true);
    expect(bridge.sent).toEqual([
      { type: "set_notifications", fields: { preview: false } },
      { type: "set_notifications", fields: { background: true } },
    ]);
    const allow = data.notifications!.action!;
    await runAction(panel, allow);
    expect(bridge.sent.at(-1)).toEqual({
      type: "allow_notifications",
      fields: {},
    });
    // Open System Settings is the host's, never an intent.
    const mac = (
      json("snapshots/views-notifications-settings.json") as Snapshot
    ).data as SettingsData;
    const opened: string[] = [];
    await runAction(
      {
        ...panel,
        bridge: {
          ...bridge,
          openSettings: async (target: string) => !!opened.push(target),
        },
      },
      mac.notifications!.action!,
    );
    expect(opened).toEqual(["notifications"]);
    expect(bridge.sent).toHaveLength(3);
  });
});

describe("a notification's URL", () => {
  it("opens the dropdown on its conversation, or on the list", () => {
    const opened: { conversation_id: string | null }[] = [];
    const stop = pendingOpen.listen((target) => opened.push(target));
    routeEvent({ kind: "open", conversation_id: "c_mei" });
    routeEvent({ kind: "open", conversation_id: null });
    stop();
    expect(opened).toEqual([
      { conversation_id: "c_mei" },
      { conversation_id: null },
    ]);
    expect(stackFor(opened[0])).toEqual([
      { kind: "list" },
      { kind: "conversation", id: "c_mei" },
    ]);
    expect(stackFor(opened[1])).toEqual([{ kind: "list" }]);
    // The panel's store takes the event without changing anything.
    const store = new FriendsStore(fakeBridge({}), withNotifications);
    const before = store.snapshotVersion();
    store.handle({ kind: "open", conversation_id: "c_mei" });
    expect(store.snapshotVersion()).toBe(before);
  });

  it("waits for the button when it arrives before Friends has loaded (a cold launch)", () => {
    routeEvent({ kind: "open", conversation_id: "c_kenji" });
    const opened: { conversation_id: string | null }[] = [];
    const stop = pendingOpen.listen((target) => opened.push(target));
    stop();
    expect(opened).toEqual([{ conversation_id: "c_kenji" }]);
  });
});
