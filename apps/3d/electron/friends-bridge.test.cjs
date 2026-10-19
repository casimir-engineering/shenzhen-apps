// The Friends bridge in the main process: what the renderer may send (validate.cjs) and where the helper's frames
// go (router.cjs). The helper files the panel may read and the lock are in friends-files.test.cjs, the host's
// lifecycle and IPC with a fake client addon in friends-host.test.cjs. No helper, socket or Electron runs here;
// electron/friends-smoke.mjs drives the real ones.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {
  validateIntent,
  INTENT_TYPES,
  FriendsFieldError,
  externalURL,
  settingsURL,
  linkPayload,
} = require("./friends/validate.cjs");
const {
  FriendsRouter,
  HOST,
  MAX_SUBSCRIPTIONS_PER_WINDOW,
} = require("./friends/router.cjs");

const fixtures = path.join(__dirname, "../tests/fixtures/friends");
const intents = fs
  .readFileSync(path.join(fixtures, "intents.jsonl"), "utf8")
  .split("\n")
  .filter(Boolean)
  .map((line) => JSON.parse(line));
const fieldsOf = ({ type: _type, id: _id, ...fields }) => fields;
const rejects = (type, fields, field) =>
  assert.throws(
    () => validateIntent(type, fields),
    (error) =>
      error instanceof FriendsFieldError &&
      (field === undefined || error.field === field),
  );

test("every PROTOCOL intent example the panel sends passes, as the same JSON", () => {
  // Shenzhen 3D sends plain files only, and has no assistant: those examples are refused, below.
  const usesRevision = (fields) =>
    JSON.stringify(fields).includes('"revision":{') ||
    "via_assistant" in fields ||
    fields.view === "message_status";
  let checked = 0;
  for (const intent of intents) {
    if (!INTENT_TYPES.includes(intent.type) || usesRevision(intent)) continue;
    const fields = fieldsOf(intent);
    assert.deepEqual(
      JSON.parse(validateIntent(intent.type, fields)),
      fields,
      intent.type,
    );
    checked++;
  }
  assert.ok(checked >= 40, `only ${checked} intents checked`);
  const covered = new Set(intents.map((intent) => intent.type));
  for (const type of INTENT_TYPES)
    assert.ok(covered.has(type), `no fixture for ${type}`);
});

test("intents the bridge owns, assistant intents and file revisions never come from the renderer", () => {
  for (const type of [
    "hello",
    "disable",
    "assistant_open_scope",
    "assistant_search",
    "assistant_read",
    "nonsense",
  ])
    rejects(type, {}, "type");
  const withRevision = intents.find(
    (intent) =>
      intent.type === "send_files" &&
      JSON.stringify(intent).includes("revision"),
  );
  rejects("send_files", fieldsOf(withRevision));
  const viaAssistant = intents.find((intent) => "via_assistant" in intent);
  rejects(viaAssistant.type, fieldsOf(viaAssistant), "via_assistant");
  rejects(
    "subscribe",
    { view: "message_status", params: { message_ids: ["m_1"] } },
    "view",
  );
});

test("fields are checked for shape: opaque ids, extra keys, paths, tokens and sizes", () => {
  rejects("accept_offer", { transfer_id: "../etc" }, "transfer_id");
  rejects("accept_offer", { transfer_id: "t_1", type: "block" }, "type");
  rejects("accept_offer", { transfer_id: "t_1", id: "9" }, "id");
  rejects("accept_offer", { transfer_id: "t_1", extra: true }, "extra");
  rejects("accept_offer", ["t_1"], "fields");
  rejects("subscribe", { view: "details" }, "params");
  rejects(
    "subscribe",
    { view: "list", params: { conversation_id: "c_1" } },
    "params",
  );
  const file = (filePath) => ({
    conversation_id: "c_1",
    client_token: "a".repeat(32),
    files: [{ path: filePath }],
  });
  rejects("send_files", file("relative/file.stl"), "files[0].path");
  rejects("send_files", file("/a/../b.stl"), "files[0].path");
  rejects("send_files", file("/a/b.stl\0"), "files[0].path");
  rejects("send_files", file("/a/"), "files[0].path");
  assert.ok(validateIntent("send_files", file("/Users/someone/Gearbox.sz3d")));
  rejects(
    "send_files",
    { ...file("/a.stl"), client_token: "short" },
    "client_token",
  );
  rejects("send_files", { ...file("/a.stl"), files: [] }, "files");
  rejects(
    "send_message",
    {
      conversation_id: "c_1",
      text: "hi",
      client_token: "b".repeat(20),
      mentions: [{ conversation_id: "c_2", key: 1 }],
    },
    "mentions[0]",
  );
  rejects(
    "set_picture",
    { picture: { kind: "image", data_base64: "AAAA", path: "/a.png" } },
    "picture",
  );
  rejects(
    "set_picture",
    { picture: { kind: "image", data_base64: "not base64!" } },
    "picture.data_base64",
  );
  rejects("reset_friends", { confirm: "yes" }, "confirm");
  rejects(
    "make_download_link",
    { file: { path: "/a.sz3d" }, expires_days: 2 },
    "expires_days",
  );
  rejects("set_name", { name: "x".repeat(2000) }, "name");
});

test("links open only for the web and email, settings only for the four nearby targets", () => {
  assert.equal(
    externalURL("https://example.com/a?b=1"),
    "https://example.com/a?b=1",
  );
  assert.equal(externalURL("mailto:mei@example.com"), "mailto:mei@example.com");
  for (const url of [
    "file:///etc/passwd",
    "javascript:alert(1)",
    "szfriends:mention?ref=0",
    "https://user:pw@example.com/",
    "x-apple.systempreferences:foo",
  ])
    assert.equal(externalURL(url), null, url);
  assert.match(settingsURL("bluetooth"), /^x-apple\.systempreferences:/);
  assert.equal(settingsURL("../../evil"), null);
});

test("Friends link URLs are checked as PROTOCOL.md § Links says before anything is sent", () => {
  const download = Buffer.concat([
    Buffer.from([1]),
    Buffer.alloc(48, 7),
  ]).toString("base64url");
  assert.equal(
    linkPayload(`shenzhen3d://friends/link#d.${download}`),
    `d.${download}`,
  );
  const id = Buffer.from("amber-falcon"),
    name = Buffer.from("Mei Lin");
  const friend = Buffer.concat([
    Buffer.from([1]),
    Buffer.alloc(48, 3),
    Buffer.from([id.length]),
    id,
    Buffer.from([name.length]),
    name,
  ]).toString("base64url");
  assert.equal(
    linkPayload(`shenzhen3d://friends/link#f.${friend}`),
    `f.${friend}`,
  );
  for (const url of [
    `shenzhenpdf://friends/link#d.${download}`,
    `shenzhen3d://friends/other#d.${download}`,
    `shenzhen3d://friends/link?x=1#d.${download}`,
    `shenzhen3d://friends/link#d.${download}A`,
    `shenzhen3d://friends/link#d.${download}=`,
    `shenzhen3d://friends/link#x.${download}`,
    `shenzhen3d://friends/link#d.${Buffer.concat([Buffer.from([2]), Buffer.alloc(48)]).toString("base64url")}`,
    `shenzhen3d://friends/link#f.${friend.slice(0, -2)}`,
    `shenzhen3d://friends/link#d.${"A".repeat(600)}`,
  ])
    assert.equal(linkPayload(url), null, url);
});

function routerFixture() {
  const delivered = [],
    broadcast = [];
  const router = new FriendsRouter({
    deliver: (owner, event) => delivered.push([owner, event]),
    broadcast: (event) => broadcast.push(event),
  });
  return { router, delivered, broadcast };
}
const snapshot = (subscription, view, rev, data = {}) => ({
  type: "snapshot",
  subscription,
  view,
  rev,
  data,
});
const reply = (re, result) => ({ type: "reply", re, ok: true, result });

test("a snapshot sent before its subscription's reply reaches the window with that reply", async () => {
  const { router, delivered } = routerFixture();
  const pending = router.sent("5", 1, "subscribe", { view: "list" });
  router.frame(snapshot("s_1", "list", 1, { rows: [] }));
  assert.equal(delivered.length, 0);
  router.frame(reply("5", { subscription: "s_1" }));
  const { reply: answer, snapshot: first } = await pending;
  assert.equal(answer.result.subscription, "s_1");
  assert.equal(first.rev, 1);
  router.frame(snapshot("s_1", "list", 2));
  assert.deepEqual(
    delivered.map(([owner, event]) => [owner, event.frame.rev]),
    [[1, 2]],
  );
});

test("replies and snapshots go only to the window that asked; the badge goes to every window", async () => {
  const { router, delivered, broadcast } = routerFixture();
  const a = router.sent("1", 1, "open_conversation", {
    conversation_id: "c_1",
  });
  const b = router.sent("2", 2, "subscribe", { view: "list" });
  const badge = router.sent("3", HOST, "subscribe", { view: "badge" });
  router.frame(reply("2", { subscription: "s_2" }));
  router.frame(reply("1", { subscription: "s_1", conversation_id: "c_1" }));
  router.frame(
    snapshot("s_3", "badge", 1, {
      count: 2,
      label: "2",
      accessibility_label: "Friends, 2 waiting for you",
    }),
  );
  router.frame(reply("3", { subscription: "s_3" }));
  await Promise.all([a, b, badge]);
  router.frame(snapshot("s_1", "conversation", 1));
  router.frame(snapshot("s_2", "list", 1));
  assert.deepEqual(
    delivered.map(([owner, event]) => [owner, event.frame.subscription]),
    [
      [1, "s_1"],
      [2, "s_2"],
    ],
  );
  assert.deepEqual(broadcast, [
    {
      kind: "badge",
      data: {
        count: 2,
        label: "2",
        accessibility_label: "Friends, 2 waiting for you",
      },
    },
  ]);
  assert.equal(router.badge.count, 2);
});

test("a closed window's subscriptions are handed back and its waiting intents resolve as lost", async () => {
  const { router } = routerFixture();
  const sub = router.sent("1", 7, "subscribe", { view: "list" });
  router.frame(reply("1", { subscription: "s_1" }));
  await sub;
  const waiting = router.sent("2", 7, "accept_offer", { transfer_id: "t_1" });
  assert.deepEqual(router.dropOwner(7), ["s_1"]);
  assert.equal((await waiting).reply.error.code, "connection_lost");
  router.frame(snapshot("s_1", "list", 2));
});

test("leaving READY voids every subscription, and stopping answers every waiting intent", async () => {
  const { router, delivered, broadcast } = routerFixture();
  const sub = router.sent("1", 1, "subscribe", { view: "list" });
  router.frame(reply("1", { subscription: "s_1" }));
  await sub;
  router.badgeSnapshot({ data: { count: 1 } });
  router.connectionChanged("waiting");
  router.frame(snapshot("s_1", "list", 3));
  assert.equal(delivered.length, 0);
  assert.deepEqual(broadcast.at(-1), { kind: "badge", data: null });
  const waiting = router.sent("2", 1, "ping");
  router.stopped();
  assert.equal((await waiting).reply.error.code, "connection_lost");
});

test("a window holds a bounded number of subscriptions", async () => {
  const { router } = routerFixture();
  for (let index = 0; index < MAX_SUBSCRIPTIONS_PER_WINDOW; index++)
    router.sent(String(index), 1, "subscribe");
  assert.equal(router.mayAddSubscription(1), false);
  assert.equal(router.mayAddSubscription(2), true);
});
