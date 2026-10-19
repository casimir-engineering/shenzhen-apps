const { test } = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");
const { createScrollSource } = require("./scroll-source.cjs");
function fixture(options = {}) {
  let tick,
    active = 0,
    unrefs = 0;
  const queues = new Map(),
    windows = new Map(),
    drains = [];
  const native = {
    start: () => true,
    source: () => "gesture",
    drainRotations(handle) {
      const id = handle.readUInt32LE();
      drains.push(id);
      const rows = queues.get(id) || [];
      queues.set(id, []);
      return rows;
    },
  };
  const query = createScrollSource({
    app: { isPackaged: false },
    windows: { fromWebContents: (sender) => windows.get(sender) },
    trusted: (url) => url === "app://local/",
    platform: "darwin",
    loadNative: () => native,
    now: () => 10000,
    interval: (callback) => {
      tick = callback;
      active++;
      return {
        unref() {
          unrefs++;
        },
      };
    },
    clear: () => {
      active--;
    },
    ...options,
  });
  function sender(id, zoom = 1) {
    const sender = Object.assign(new EventEmitter(), {
      url: "app://local/",
      dead: false,
      sent: [],
      isDestroyed() {
        return this.dead;
      },
      getURL() {
        return this.url;
      },
      getZoomFactor: () => zoom,
      send(channel, value) {
        this.sent.push({ channel, value });
      },
    });
    const handle = Buffer.alloc(8);
    handle.writeUInt32LE(id);
    windows.set(sender, {
      isDestroyed: () => false,
      getNativeWindowHandle: () => handle,
      getContentSize: () => [200, 100],
    });
    return sender;
  }
  const row = (degrees = 2, clientX = 40, clientY = 30, epochMs = 10000) => ({
    degrees,
    clientX,
    clientY,
    epochMs,
  });
  return {
    query,
    sender,
    row,
    queues,
    drains,
    tick: () => tick(),
    active: () => active,
    unrefs: () => unrefs,
  };
}
test("rotation polling is subscription-only, unrefed, window-scoped and CSS zoom adjusted", () => {
  const f = fixture(),
    a = f.sender(1, 2),
    b = f.sender(2);
  assert.equal(f.active(), 0);
  f.queues.set(1, [f.row(50)]); // Predates subscribing; deliberately discarded.
  assert.equal(f.query.subscribeRotate(a, true), true);
  assert.equal(f.query.subscribeRotate(b, true), true);
  assert.equal(f.active(), 1);
  assert.equal(f.unrefs(), 1);
  f.queues.set(1, [f.row(3), f.row(-1)]);
  f.queues.set(2, [f.row(8)]);
  f.tick();
  assert.deepEqual(
    a.sent.map((r) => r.value),
    [f.row(3, 20, 15), f.row(-1, 20, 15)],
  );
  assert.deepEqual(
    b.sent.map((r) => r.value.degrees),
    [8],
  );
  assert(a.sent.every((r) => r.channel === "shenzhen-rotate"));
  f.tick();
  assert.equal(a.sent.length, 2); // Native drain does not replay.
  assert.equal(f.query(a, 10000), "gesture"); // Existing wheel query unaffected.
  f.query.subscribeRotate(a, false);
  assert.equal(f.active(), 1);
  f.query.subscribeRotate(b, false);
  assert.equal(f.active(), 0);
});
test("invalid, stale, future and outside-content rotation records are rejected", () => {
  const f = fixture(),
    a = f.sender(1);
  f.query.subscribeRotate(a, true);
  f.queues.set(1, [
    null,
    f.row(NaN),
    f.row(0),
    f.row(181),
    f.row(1, -1),
    f.row(1, 200),
    f.row(1, 40, 100),
    f.row(1, 40, 30, 7000),
    f.row(1, 40, 30, 10021),
    f.row(-0.25),
  ]);
  f.tick();
  assert.deepEqual(
    a.sent.map((r) => r.value.degrees),
    [-0.25],
  );
});
test("navigation, renderer exit, destroyed windows and disposal remove listeners and timers", () => {
  const f = fixture(),
    a = f.sender(1);
  for (let i = 0; i < 5; i++) {
    f.query.subscribeRotate(a, true);
    f.query.subscribeRotate(a, false);
  }
  assert.equal(a.listenerCount("destroyed"), 0);
  f.query.subscribeRotate(a, true);
  a.emit("did-start-navigation", {}, "app://local/#view", true, true);
  assert.equal(f.active(), 1);
  a.emit("did-start-navigation", {}, "app://local/", false, true);
  assert.equal(f.active(), 0);
  f.query.subscribeRotate(a, true);
  a.emit("render-process-gone");
  assert.equal(f.active(), 0);
  f.query.subscribeRotate(a, true);
  a.url = "https://untrusted.invalid/";
  f.tick();
  assert.equal(f.active(), 0);
  assert.equal(f.query.subscribeRotate(a, true), false);
  a.url = "app://local/";
  f.query.subscribeRotate(a, true);
  f.query.dispose();
  f.query.dispose();
  assert.equal(f.active(), 0);
  assert.equal(a.listenerCount("destroyed"), 0);
  assert.equal(f.query.subscribeRotate(a, true), false);
  assert.equal(f.query(a, 10000), null);
});
test("non-Mac or unavailable native addon creates no rotation polling", () => {
  for (const options of [
    { platform: "linux" },
    {
      loadNative() {
        throw Error("Unavailable");
      },
    },
  ]) {
    const f = fixture(options),
      a = f.sender(1);
    assert.equal(f.query.subscribeRotate(a, true), false);
    assert.equal(f.active(), 0);
    assert.equal(f.query(a, 10000), null);
  }
});
test("preload exposes a narrow validated subscription with independent cleanup", () => {
  const ipc = Object.assign(new EventEmitter(), {
    sent: [],
    send(...args) {
      this.sent.push(args);
    },
    sendSync() {
      return null;
    },
  });
  const exposed = {};
  vm.runInNewContext(
    fs.readFileSync(path.join(__dirname, "preload.cjs"), "utf8"),
    {
      require: () => ({
        contextBridge: {
          exposeInMainWorld: (name, value) => {
            exposed[name] = value;
          },
        },
        ipcRenderer: ipc,
        webUtils: {},
      }),
    },
  );
  const api = exposed.shenzhenScroll;
  assert.deepEqual(Object.keys(api), ["source", "subscribeRotate"]);
  const received = [],
    callback = (value) => received.push(value);
  const off1 = api.subscribeRotate(callback),
    off2 = api.subscribeRotate(callback);
  assert.deepEqual(ipc.sent, [["shenzhen-rotate-subscribe", true]]);
  const value = {
    degrees: 2,
    clientX: 20,
    clientY: 30,
    epochMs: 10000,
    pointer: "never expose",
  };
  ipc.emit("shenzhen-rotate", {}, value);
  assert.equal(received.length, 2);
  assert.equal(received[0].pointer, undefined);
  off1();
  off1();
  ipc.emit("shenzhen-rotate", {}, value);
  assert.equal(received.length, 3);
  for (const bad of [
    null,
    { ...value, degrees: NaN },
    { ...value, degrees: 0 },
    { ...value, degrees: 181 },
    { ...value, clientX: -1 },
  ])
    ipc.emit("shenzhen-rotate", {}, bad);
  assert.equal(received.length, 3);
  off2();
  assert.deepEqual(ipc.sent, [
    ["shenzhen-rotate-subscribe", true],
    ["shenzhen-rotate-subscribe", false],
  ]);
  const offBad = api.subscribeRotate("bad");
  offBad();
  assert.equal(ipc.sent.length, 2);
});
