// The guest script against a fake Tauri page: which windows get the bridge, how its calls reach the plugin's
// commands, events in order through the join channel, and dropped files' paths only from the system's own report
// on desktops, their bytes staged on phones, and on a Mac the drags of files the page sees over its window.
//
//   node --test portable/friends/tauri/guest/bridge.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(new URL("./bridge.js", import.meta.url), "utf8");
// Values made inside the page's realm, compared as plain data.
const plain = (value) => JSON.parse(JSON.stringify(value));

function page(label, { stagedDropLimit = 0, webview = null, dropPaths = null, dragOver = false } = {}) {
  const calls = [];
  const listeners = {};
  const callbacks = new Map();
  let nextCallback = 1;
  const window = {
    __TAURI_INTERNALS__: {
      metadata: { currentWindow: { label }, currentWebview: { label } },
      transformCallback(callback) {
        const id = nextCallback++;
        callbacks.set(id, callback);
        return id;
      },
      async invoke(command, args, options) {
        calls.push({ command, args, options });
        if (command === "plugin:szfriends|drop_paths") return dropPaths;
        if (command === "plugin:szfriends|image") {
          const header = new TextEncoder().encode(JSON.stringify({ type: "image/png", width: 2, height: 3 }));
          const buffer = new ArrayBuffer(4 + header.length + 2);
          new DataView(buffer).setUint32(0, header.length, false);
          new Uint8Array(buffer, 4).set(header);
          new Uint8Array(buffer, 4 + header.length).set([7, 9]);
          return buffer;
        }
        return { command };
      },
    },
    ...(webview ? { chrome: { webview } } : {}),
    addEventListener(type, listener) {
      (listeners[type] ??= []).push(listener);
    },
  };
  const context = vm.createContext({ window, crypto, TextDecoder, TextEncoder, ArrayBuffer, DataView, Uint8Array });
  const script = source
    .replace("__SZFRIENDS_WINDOWS__", '["main"]')
    .replace("__SZFRIENDS_STAGED_DROP_LIMIT__", String(stagedDropLimit))
    .replace("__SZFRIENDS_DRAG_OVER__", String(dragOver));
  vm.runInContext(script, context);
  return { window, calls, callbacks, listeners };
}

test("only the windows the plugin serves get the bridge, and it cannot be replaced", () => {
  assert.equal(page("viewer-2").window.shenzhenFriends, undefined);
  const { window } = page("main");
  assert.equal(typeof window.shenzhenFriends.join, "function");
  assert.throws(() => {
    "use strict";
    window.shenzhenFriends = {};
  });
  for (const method of ["join", "status", "subscribe", "send", "setEnabled", "image", "animal", "animals",
    "pathsForFiles", "classify", "stage", "token", "openFile", "showFile", "openSettings", "openURL", "shareable"])
    assert.equal(typeof window.shenzhenFriends[method], "function", method);
});

test("calls reach the plugin's commands; events arrive in order through the join channel", async () => {
  const { window, calls, callbacks } = page("main");
  const bridge = window.shenzhenFriends;
  const seen = [];
  bridge.subscribe((event) => seen.push(event.kind));
  await bridge.join();
  const join = calls.find((call) => call.command === "plugin:szfriends|join");
  const id = Number(String(join.args.events.toJSON()).replace("__CHANNEL__:", ""));
  const deliver = callbacks.get(id);
  deliver({ index: 1, message: { kind: "badge", data: null } });
  deliver({ index: 0, message: { kind: "status", status: {} } });
  assert.deepEqual(seen, ["status", "badge"], "in order");
  await bridge.send("accept_offer", { transfer_id: "t_1" });
  assert.deepEqual(plain(calls.at(-1)), {
    command: "plugin:szfriends|send",
    args: { kind: "accept_offer", fields: { transfer_id: "t_1" } },
  });
  const image = await bridge.image("thumbnail", "/s/thumbnails/a.png", 2, 3);
  assert.equal(image.type, "image/png");
  assert.deepEqual(Array.from(image.bytes), [7, 9]);
  await bridge.stage("Gear box.sz3d", new Uint8Array([1, 2, 3]));
  const stage = calls.at(-1);
  assert.equal(stage.command, "plugin:szfriends|stage");
  assert.deepEqual(Array.from(stage.args), [1, 2, 3]);
  assert.equal(stage.options.headers["szfriends-name"], "Gear%20box.sz3d");
});

test("a desktop asks the plugin for the paths the system reported, by name and size", async () => {
  const files = [{ name: "a.stl", size: 3 }, { name: "b.stl", size: 4 }];
  const found = page("main", { dropPaths: ["/x/a.stl", "/x/b.stl"] });
  assert.deepEqual(plain(await found.window.shenzhenFriends.pathsForFiles(files)), ["/x/a.stl", "/x/b.stl"]);
  assert.deepEqual(plain(found.calls.at(-1)), {
    command: "plugin:szfriends|drop_paths",
    args: { files: [{ name: "a.stl", size: 3 }, { name: "b.stl", size: 4 }], ticket: null },
  });
  assert.equal(found.window.shenzhenFriends.stagedDropLimit, undefined, "a desktop stages no drop");
  const unmatched = page("main", { dropPaths: null });
  assert.deepEqual(plain(await unmatched.window.shenzhenFriends.pathsForFiles(files)), [null, null]);
  const short = page("main", { dropPaths: ["/x/a.stl"] });
  assert.deepEqual(plain(await short.window.shenzhenFriends.pathsForFiles(files)), [null, null], "all or none");
});

test("on Windows the dropped files go to WebView2 first, under the ticket the question carries", async () => {
  const posted = [];
  const webview = { postMessageWithAdditionalObjects: (message, objects) => posted.push({ message, objects }) };
  const { window, calls } = page("main", { webview, dropPaths: ["C:\\x\\a.stl"] });
  const files = [{ name: "a.stl", size: 3 }];
  assert.deepEqual(plain(await window.shenzhenFriends.pathsForFiles(files)), ["C:\\x\\a.stl"]);
  assert.equal(posted.length, 1);
  assert.equal(posted[0].objects[0], files[0], "the page's own File objects");
  const ticket = calls.at(-1).args.ticket;
  assert.match(ticket, /^[0-9a-f]{24}$/);
  assert.equal(posted[0].message, `szfriends-drop:${ticket}`);
});

test("a phone gives no paths and says how much of a dropped file it stages", async () => {
  const { window, calls } = page("main", { stagedDropLimit: 250000000 });
  assert.deepEqual(plain(await window.shenzhenFriends.pathsForFiles([{ name: "a.stl", size: 3 }])), [null]);
  assert.equal(calls.length, 0, "nothing asked");
  assert.equal(window.shenzhenFriends.stagedDropLimit, 250000000);
});

test("a Mac says when files are dragged over its window, at most every 200 ms; elsewhere it says nothing", () => {
  const files = { dataTransfer: { types: ["Files"] } };
  const mac = page("main", { dragOver: true });
  for (const type of ["dragenter", "dragover"]) mac.listeners[type][0](files);
  mac.listeners.dragover[0]({ dataTransfer: { types: ["text/plain"] } });
  const asked = mac.calls.filter((c) => c.command === "plugin:szfriends|drag_over");
  assert.equal(asked.length, 1, "once within 200 ms, and only for files");
  const elsewhere = page("main");
  assert.equal(elsewhere.listeners.dragover, undefined);
});
