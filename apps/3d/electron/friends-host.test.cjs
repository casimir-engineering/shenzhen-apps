// The Friends host (host.cjs) with a fake client addon: its lifecycle, its IPC with the renderer, received files and
// staged projects, and the preload's bridge. No helper, socket or Electron runs here; electron/friends-smoke.mjs
// drives the real ones.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const fsp = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const { EventEmitter } = require("node:events");
const { createFriendsHost } = require("./friends/host.cjs");

const snapshot = (subscription, view, rev, data = {}) => ({
  type: "snapshot",
  subscription,
  view,
  rev,
  data,
});
const reply = (re, result) => ({ type: "reply", re, ok: true, result });

function fakeAddon() {
  const clients = [];
  return {
    clients,
    prepare: async () => ({ team: null }),
    defaultStateDir: () => "/tmp/friends-home",
    createClient(config, onEvents) {
      const client = {
        config,
        sent: [],
        stops: [],
        closed: false,
        next: 1,
        start() {
          return "ok";
        },
        stop(disabling) {
          this.stops.push(disabling);
          return "ok";
        },
        close() {
          this.closed = true;
        },
        send(type, json) {
          const id = String(++this.next);
          this.sent.push({ type, id, fields: JSON.parse(json) });
          return { status: "ok", id };
        },
        emit(events, stateText = "") {
          onEvents(Object.assign(events, { stateText }));
        },
        frame(frame) {
          this.emit([{ type: "frame", json: JSON.stringify(frame) }]);
        },
      };
      clients.push(client);
      return client;
    },
  };
}
function fakeContents(id) {
  const contents = new EventEmitter();
  contents.id = id;
  contents.received = [];
  contents.mainFrame = { url: "app://local/" };
  contents.isDestroyed = () => false;
  contents.send = (channel, event) => contents.received.push([channel, event]);
  return contents;
}
const invoke = (host, contents, method, value) =>
  host.handle(
    { sender: contents, senderFrame: contents.mainFrame },
    method,
    value,
  );

async function hostFixture(t) {
  const userData = await fsp.mkdtemp(path.join(os.tmpdir(), "szf3d-host-"));
  t.after(() => fsp.rm(userData, { recursive: true, force: true }));
  const addon = fakeAddon();
  const opened = [];
  const host = createFriendsHost({
    app: {
      isPackaged: true,
      getPath: () => userData,
      getVersion: () => "0.1.9",
      getLocale: () => "en-GB",
    },
    BrowserWindow: { getFocusedWindow: () => null },
    shell: { openExternal: async () => {}, showItemInFolder: () => {} },
    trusted: (url) => url === "app://local/",
    openFormats: new Set(["sz3d", "stl"]),
    openFiles: (files) => opened.push(files),
    loadAddon: () => addon,
    located: {
      helperApp: "/nowhere/Shenzhen Friends.app",
      helperExecutable:
        "/nowhere/Shenzhen Friends.app/Contents/MacOS/Shenzhen Friends",
      animals: "/nowhere/animals",
      addon: "/nowhere/friends-link.node",
    },
  });
  t.after(() => host.dispose());
  return { host, addon, userData, opened };
}
const until = async (condition) => {
  for (let i = 0; i < 200 && !condition(); i++)
    await new Promise((resolve) => setTimeout(resolve, 5));
  assert.ok(condition());
};

test("the host attaches after first paint, says who it is, and routes a window's intents and views", async (t) => {
  const { host, addon } = await hostFixture(t);
  const window = fakeContents(1);
  assert.equal(
    (await invoke(host, window, "join")).attached,
    false,
    "nothing before the first paint",
  );
  host.firstPaint();
  await until(() => addon.clients.length === 1);
  const client = addon.clients[0];
  assert.equal(client.config.appName, "Shenzhen 3D");
  assert.deepEqual(client.config.capabilities, [
    "attach.items",
    "drop.files",
    "mentions",
  ]);
  assert.deepEqual(client.config.openFormats, ["sz3d", "stl"]);
  assert.equal(
    client.config.helperBuildNumber,
    0,
    "no embedded helper here, so it never wins a handover",
  );
  assert.equal(
    (await invoke(host, window, "send", { type: "ping" })).reply.error.code,
    "not_ready",
  );
  client.frame({
    type: "welcome",
    re: "1",
    strings: { button_label: "Friends" },
    capabilities: ["mentions"],
  });
  client.emit([{ type: "state", state: "ready" }]);
  assert.deepEqual(
    client.sent[0].fields,
    { view: "badge" },
    "the badge is the host's own subscription",
  );
  const status = window.received.at(-1)[1].status;
  assert.equal(status.state, "ready");
  assert.equal(status.strings.button_label, "Friends");
  const pending = invoke(host, window, "send", {
    type: "subscribe",
    fields: { view: "list" },
  });
  await until(() => client.sent.length === 2);
  const { id } = client.sent[1];
  client.frame(snapshot("s_9", "list", 1, { rows: [] }));
  client.frame(reply(id, { subscription: "s_9" }));
  const answer = await pending;
  assert.equal(answer.snapshot.subscription, "s_9");
  client.frame(snapshot("s_9", "list", 2, { rows: [] }));
  assert.equal(window.received.at(-1)[1].frame.rev, 2);
  // A reload: the page's subscription goes with it.
  window.emit("did-start-navigation", {
    isMainFrame: true,
    isSameDocument: false,
  });
  assert.deepEqual(client.sent.at(-1), {
    type: "unsubscribe",
    id: client.sent.at(-1).id,
    fields: { subscription: "s_9" },
  });
});

test("the host refuses other pages, unknown methods and malformed intents before the helper sees them", async (t) => {
  const { host, addon } = await hostFixture(t);
  const window = fakeContents(1);
  const stranger = fakeContents(2);
  stranger.mainFrame = { url: "https://example.com/" };
  await assert.rejects(invoke(host, stranger, "join"), /not allowed/);
  await assert.rejects(invoke(host, window, "eval"), /not allowed/);
  await assert.rejects(
    host.handle(
      { sender: window, senderFrame: { url: "app://local/" } },
      "join",
    ),
    /not allowed/,
    "a subframe",
  );
  host.firstPaint();
  await until(() => addon.clients.length === 1);
  addon.clients[0].emit([{ type: "state", state: "ready" }]);
  const before = addon.clients[0].sent.length;
  const refused = await invoke(host, window, "send", {
    type: "send_files",
    fields: {
      conversation_id: "c_1",
      client_token: "x".repeat(32),
      files: [{ path: "relative" }],
    },
  });
  assert.equal(refused.reply.error.code, "invalid_field");
  assert.equal(addon.clients[0].sent.length, before);
});

test("turning Friends off tells the helper, remembers the choice and answers waiting intents", async (t) => {
  const { host, addon, userData } = await hostFixture(t);
  const window = fakeContents(1);
  await invoke(host, window, "join");
  host.firstPaint();
  await until(() => addon.clients.length === 1);
  const client = addon.clients[0];
  client.emit([{ type: "state", state: "ready" }]);
  const waiting = invoke(host, window, "send", { type: "ping" });
  await until(() => client.sent.length === 2);
  const status = await invoke(host, window, "setEnabled", false);
  assert.equal(status.enabled, false);
  assert.deepEqual(client.stops, [true], "disable is sent");
  assert.equal(client.closed, true);
  assert.equal((await waiting).reply.error.code, "connection_lost");
  assert.deepEqual(
    JSON.parse(await fsp.readFile(path.join(userData, "friends.json"), "utf8")),
    { enabled: false },
  );
  await invoke(host, window, "setEnabled", true);
  await until(() => addon.clients.length === 2);
});

test("received files open in the viewer only if offered, in its formats; staged projects stay private", async (t) => {
  const { host, addon, opened, userData } = await hostFixture(t);
  const window = fakeContents(1);
  const file = path.join(userData, "Gearbox.stl");
  const notes = path.join(userData, "notes.txt");
  const elsewhere = path.join(userData, "Elsewhere.stl");
  await fsp.writeFile(file, "solid");
  await fsp.writeFile(notes, "x");
  await fsp.writeFile(elsewhere, "solid");
  assert.equal(
    await invoke(host, window, "openFile", file),
    false,
    "no snapshot has offered it yet",
  );
  host.firstPaint();
  await until(() => addon.clients.length === 1);
  const client = addon.clients[0];
  client.emit([{ type: "state", state: "ready" }]);
  const open = (path) => ({ action: "open_file", label: "Open", path });
  client.frame(
    snapshot("s_1", "conversation", 1, {
      items: [
        { kind: "transfer", direction: "in", actions: [open(file)] },
        { kind: "transfer", direction: "in", actions: [open(notes)] },
        {
          kind: "transfer",
          direction: "in",
          actions: [{ action: "show_file", label: "Show", path: elsewhere }],
        },
      ],
    }),
  );
  assert.equal(await invoke(host, window, "openFile", file), true);
  assert.deepEqual(opened, [[file]]);
  assert.equal(
    await invoke(host, window, "openFile", notes),
    false,
    "offered, but not a format the viewer opens",
  );
  assert.equal(
    await invoke(host, window, "openFile", elsewhere),
    false,
    "a file the helper offered only to show is not opened",
  );
  assert.equal(
    await invoke(host, window, "openFile", path.join(userData, "Other.stl")),
    false,
  );
  assert.equal(await invoke(host, window, "openFile", "relative.stl"), false);
  const staged = await invoke(host, window, "stage", {
    name: "Gearbox.sz3d",
    bytes: new Uint8Array([1, 2, 3]),
  });
  assert.ok(staged.startsWith(path.join(userData, "Friends/Outgoing")));
  assert.equal((await fsp.stat(staged)).mode & 0o777, 0o600);
  for (const name of ["../x.sz3d", ".hidden.sz3d", "a.exe", "a/b.sz3d"])
    await assert.rejects(
      invoke(host, window, "stage", { name, bytes: new Uint8Array(1) }),
      /Invalid project name/,
    );
  assert.match(await invoke(host, window, "token"), /^[0-9a-f]{32}$/);
});

test("the preload offers the Friends bridge on the Mac only, and only through shenzhen-friends", async () => {
  const vm = require("node:vm");
  const source = fs.readFileSync(path.join(__dirname, "preload.cjs"), "utf8");
  const load = (platform) => {
    const exposed = {},
      invoked = [];
    const ipcRenderer = Object.assign(new EventEmitter(), {
      send() {},
      sendSync() {},
      invoke: async (...args) => {
        invoked.push(args);
        return null;
      },
    });
    vm.runInNewContext(source, {
      process: { platform },
      require: () => ({
        contextBridge: {
          exposeInMainWorld: (name, value) => (exposed[name] = value),
        },
        ipcRenderer,
        webUtils: { getPathForFile: (file) => file.path ?? "" },
      }),
    });
    return { exposed, invoked, ipcRenderer };
  };
  assert.equal(load("linux").exposed.shenzhenFriends, undefined);
  const { exposed, invoked, ipcRenderer } = load("darwin");
  const friends = exposed.shenzhenFriends;
  await friends.send("ping", {});
  await friends.image("thumbnail", "/x.png", 1, 1);
  // Objects made inside the preload's context: compared by value.
  assert.deepEqual(JSON.parse(JSON.stringify(invoked)), [
    ["shenzhen-friends", "send", { type: "ping", fields: {} }],
    [
      "shenzhen-friends",
      "image",
      { kind: "thumbnail", path: "/x.png", width: 1, height: 1 },
    ],
  ]);
  assert.deepEqual(
    [...friends.pathsForFiles([{ path: "/a.stl" }, {}])],
    ["/a.stl", null],
  );
  const events = [];
  const stop = friends.subscribe((event) => events.push(event));
  ipcRenderer.emit("shenzhen-friends-event", {}, { kind: "badge", data: null });
  ipcRenderer.emit("shenzhen-friends-event", {}, "not an event");
  stop();
  ipcRenderer.emit("shenzhen-friends-event", {}, { kind: "badge", data: null });
  assert.deepEqual(events, [{ kind: "badge", data: null }]);
});
