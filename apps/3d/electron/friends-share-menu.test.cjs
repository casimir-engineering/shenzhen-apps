// File ▸ Copy Download Link (electron/friends/share-menu.cjs) and its wiring in the host: added after first paint,
// shown only while the helper announces `links`, enabled only for a focused window with a model open, and its choice
// sent to that window alone. Electron's Menu is faked with the few calls the module makes.
const test = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");
const fsp = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const { createShareMenu, ITEM_ID } = require("./friends/share-menu.cjs");
const { createFriendsHost } = require("./friends/host.cjs");

function fakeItem(template) {
  const item = { ...template };
  if (Array.isArray(template.submenu))
    item.submenu = fakeMenu(template.submenu.map(fakeItem));
  return item;
}
function fakeMenu(items) {
  return {
    items,
    insert(index, item) {
      items.splice(index, 0, item);
    },
    getMenuItemById(id) {
      for (const item of items) {
        if (item.id === id) return item;
        const found = item.submenu?.getMenuItemById(id);
        if (found) return found;
      }
      return null;
    },
  };
}
function fakeElectronMenu() {
  const app = fakeMenu([
    fakeItem({
      id: "file",
      label: "File",
      submenu: [
        { label: "New Window" },
        { id: "open", label: "Open…" },
        { type: "separator" },
        { role: "close" },
      ],
    }),
  ]);
  return {
    app,
    sets: 0,
    getApplicationMenu: () => app,
    setApplicationMenu(menu) {
      assert.equal(menu, app);
      this.sets++;
    },
    buildFromTemplate: (template) => fakeMenu(template.map(fakeItem)),
  };
}
const fileLabels = (Menu) =>
  Menu.app.getMenuItemById("file").submenu.items.map((item) => item.label);
const choose = (Menu, label) =>
  Menu.app
    .getMenuItemById(ITEM_ID)
    .submenu.items.find((item) => item.label === label)
    .click();

test("Copy Download Link is added hidden after Open…, once, with 7, 1 and 30 days", () => {
  const Menu = fakeElectronMenu();
  const share = createShareMenu({
    Menu,
    focusedId: () => 1,
    choose: () => {},
  });
  share.install();
  share.install();
  assert.deepEqual(fileLabels(Menu), [
    "New Window",
    "Open…",
    "Copy Download Link",
    undefined,
    undefined,
  ]);
  assert.equal(Menu.sets, 1, "the changed menu is set again once");
  const item = Menu.app.getMenuItemById(ITEM_ID);
  assert.deepEqual(
    item.submenu.items.map((choice) => choice.label),
    ["For 7 Days", "For 1 Day", "For 30 Days"],
  );
  assert.equal(item.visible, false);
  assert.equal(item.enabled, false);
});

test("it shows while links are offered, works for the focused window with a model open, and asks only it", () => {
  const Menu = fakeElectronMenu();
  let focused = 1;
  const asked = [];
  const share = createShareMenu({
    Menu,
    focusedId: () => focused,
    choose: (owner, days) => asked.push([owner, days]),
  });
  share.install();
  const item = Menu.app.getMenuItemById(ITEM_ID);
  share.setShareable(1, true);
  assert.equal(item.visible, false, "hidden while the helper offers no links");
  choose(Menu, "For 1 Day");
  share.setOffers(true);
  assert.deepEqual([item.visible, item.enabled], [true, true]);
  choose(Menu, "For 30 Days");
  focused = 2;
  share.refresh();
  assert.equal(item.enabled, false, "the focused window has no model open");
  choose(Menu, "For 7 Days");
  focused = 1;
  share.forget(1);
  assert.equal(item.enabled, false, "a closed or reloaded window");
  share.setOffers(false);
  assert.equal(item.visible, false);
  assert.deepEqual(asked, [[1, 30]]);
});

// ---- Through the host, with a fake client addon -----------------------------------------------------------------

function fakeAddon() {
  const clients = [];
  return {
    clients,
    prepare: async () => ({ team: null }),
    defaultStateDir: () => "/tmp/friends-home",
    createClient(config, onEvents) {
      const client = {
        next: 1,
        start: () => "ok",
        stop: () => "ok",
        close() {},
        send() {
          return { status: "ok", id: String(++this.next) };
        },
        emit(events) {
          onEvents(Object.assign(events, { stateText: "" }));
        },
        welcome(capabilities) {
          this.emit([
            {
              type: "frame",
              json: JSON.stringify({ type: "welcome", re: "1", capabilities }),
            },
          ]);
          this.emit([{ type: "state", state: "ready" }]);
        },
      };
      clients.push(client);
      return client;
    },
  };
}
function fakeContents(id) {
  const contents = new EventEmitter();
  Object.assign(contents, {
    id,
    received: [],
    mainFrame: { url: "app://local/" },
    isDestroyed: () => false,
    send: (channel, event) => contents.received.push([channel, event]),
  });
  return contents;
}

async function hostWithMenu(t, { located = true } = {}) {
  const userData = await fsp.mkdtemp(path.join(os.tmpdir(), "szf3d-share-"));
  t.after(() => fsp.rm(userData, { recursive: true, force: true }));
  const Menu = fakeElectronMenu();
  const addon = fakeAddon();
  const app = Object.assign(new EventEmitter(), {
    isPackaged: true,
    getPath: () => userData,
    getVersion: () => "0.1.9",
  });
  const focused = { webContents: { id: 1 } };
  const host = createFriendsHost({
    app,
    BrowserWindow: { getFocusedWindow: () => focused.webContents && focused },
    Menu,
    shell: {},
    trusted: (url) => url === "app://local/",
    openFormats: new Set(["sz3d"]),
    openFiles: () => {},
    loadAddon: () => addon,
    located: located
      ? {
          helperApp: "/nowhere/Shenzhen Friends.app",
          helperExecutable: "/nowhere/x",
          animals: "/nowhere/animals",
          addon: "/nowhere/friends-link.node",
        }
      : null,
  });
  t.after(() => host.dispose());
  const invoke = (contents, method, value) =>
    host.handle(
      { sender: contents, senderFrame: contents.mainFrame },
      method,
      value,
    );
  return { host, addon, Menu, app, focused, invoke };
}
const until = async (condition) => {
  for (let i = 0; i < 200 && !condition(); i++)
    await new Promise((resolve) => setTimeout(resolve, 5));
  assert.ok(condition());
};

test("the host shows Copy Download Link only while its helper announces links, for the focused window", async (t) => {
  const { host, addon, Menu, app, focused, invoke } = await hostWithMenu(t);
  const window = fakeContents(1);
  await invoke(window, "join");
  const item = Menu.app.getMenuItemById(ITEM_ID);
  assert.ok(item, "added when Friends loads");
  host.firstPaint();
  await until(() => addon.clients.length === 1);
  const client = addon.clients[0];
  client.welcome(["mentions"]);
  assert.equal(item.visible, false, "a helper without links");
  client.emit([{ type: "state", state: "waiting" }]);
  client.welcome(["mentions", "links"]);
  assert.equal(item.visible, true);
  assert.equal(item.enabled, false, "no model open yet");
  await invoke(window, "shareable", true);
  assert.equal(item.enabled, true);
  choose(Menu, "For 30 Days");
  assert.deepEqual(window.received.at(-1), [
    "shenzhen-friends-event",
    { kind: "copy_download_link", days: 30 },
  ]);
  focused.webContents = null;
  app.emit("browser-window-blur");
  assert.equal(item.enabled, false, "no focused window");
  focused.webContents = { id: 1 };
  app.emit("browser-window-focus");
  assert.equal(item.enabled, true);
  window.emit("did-start-navigation", { isMainFrame: true });
  assert.equal(item.enabled, false, "a reloaded page says again");
  client.emit([{ type: "state", state: "waiting" }]);
  assert.equal(item.visible, false, "the helper went away");
});

test("without Friends the File menu is left as it is", async (t) => {
  const { Menu, invoke } = await hostWithMenu(t, { located: false });
  await invoke(fakeContents(1), "join");
  assert.equal(Menu.app.getMenuItemById(ITEM_ID), null);
  assert.equal(Menu.sets, 0);
});
