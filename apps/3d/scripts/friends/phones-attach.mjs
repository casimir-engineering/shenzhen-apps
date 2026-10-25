#!/usr/bin/env node
// phones-attach.mjs — on an Android emulator, Shenzhen 3D's debug build with Friends sends files of any kind that a
// person picks in the system's own file picker, and files shared into the app from the Files app, to a friend on this
// Mac. Every press is the emulator's own touch input (`adb shell input`) on the real screens: the composer's paperclip,
// the system's document picker (DocumentsUI), the Files app, its share sheet and "Send to a friend".
//
//   node scripts/friends/phones-attach.mjs --serial emulator-5650 --tools <dir> [--shots <dir>]
//
// --tools names the core's built examples (`cargo build -p szfriends-helper --example befriend --example
// loopback-peer` in apps/pdf/portable/friends/core-rs: target/debug/examples). The phone (Ada) and the Mac's Friends
// service (Bo, `loopback-peer`) are test homes made friends with `befriend`, joined over the test network on loopback
// as phones-exchange.mjs joins them. Checked: the paperclip, named Attach files, opens the system's picker for any
// type; two files picked there become chips and Send gives Bo both, byte for byte; a file shared from the Files app
// with "Send to a friend" opens Friends on the list ("Send … to…"), a tap on Bo sends it, and it arrives whole.
import { execFileSync, spawn } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { android } from "./phones-exchange-android.mjs";

const argv = process.argv.slice(2);
const option = (name) => {
  const index = argv.indexOf(`--${name}`);
  return index >= 0 ? argv[index + 1] : undefined;
};
const serial = option("serial");
const tools = option("tools");
const shots = option("shots");
// Emulators only: a phone on USB is someone's.
if (!/^emulator-\d+$/.test(serial ?? "") || !tools) {
  console.error("usage: phones-attach.mjs --serial emulator-NNNN --tools <dir> [--shots <dir>]");
  process.exit(64);
}
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const checks = [];
const check = (line) => {
  checks.push(line);
  console.log(`ok ${line}`);
};
async function until(probe, what, ms = 60_000) {
  const begun = Date.now();
  while (Date.now() - begun < ms) {
    const value = await Promise.resolve()
      .then(probe)
      .catch(() => null);
    if (value) return value;
    await wait(300);
  }
  throw Error(`timed out waiting for ${what}`);
}

const work = await fs.mkdtemp(path.join(os.tmpdir(), "szf-attach-"));
const homePhone = path.join(work, "phone");
const homePeer = path.join(work, "peer");
const routes = path.join(work, "routes");
await fs.mkdir(routes, { mode: 0o700 });
const [boInPhone, adaInPeer] = execFileSync(path.join(tools, "befriend"), [homePhone, homePeer, "Ada", "Bo"], {
  encoding: "utf8",
})
  .trim()
  .split(/\s+/);

// The files on the phone, in its Downloads: kinds the viewer does not open, one of them several megabytes.
const stamp = Date.now().toString(36);
const files = {
  survey: { name: `Site survey ${stamp}.pdf`, bytes: Buffer.concat([Buffer.from("%PDF-1.7\n"), crypto.randomBytes(6e6)]) },
  notes: { name: `wiring notes ${stamp}.txt`, bytes: Buffer.from("Red to 12 V, black to ground.\n".repeat(200)) },
  curve: { name: `pump curve ${stamp}.csv`, bytes: Buffer.from("flow,head\n" + "1,2\n".repeat(50000)) },
};

// Bo: the Mac's Friends service, driven over its protocol.
function startPeer() {
  const child = spawn(path.join(tools, "loopback-peer"), [homePeer], {
    env: { ...process.env, SZFRIENDS_STATE_DIR: homePeer, SZFRIENDS_TEST_LOOPBACK: routes },
    stdio: ["pipe", "pipe", "inherit"],
  });
  const views = new Map();
  const replies = new Map();
  let sent = 0;
  readline.createInterface({ input: child.stdout }).on("line", (line) => {
    const frame = JSON.parse(line);
    if (frame.type === "snapshot") views.set(frame.subscription, frame.data);
    if (frame.type === "reply") replies.set(frame.re, frame);
  });
  const send = async (type, fields) => {
    const id = `p${++sent}`;
    child.stdin.write(`${JSON.stringify({ type, ...fields })}\n`);
    return until(() => replies.get(id), `the reply to ${type}`, 30_000);
  };
  return {
    send,
    async view(type, fields) {
      const reply = await send(type, fields);
      return () => views.get(reply.result?.subscription);
    },
    close: () => child.stdin.end(),
    exited: new Promise((resolve) => child.on("exit", resolve)),
  };
}

const phone = android(serial);
const adb = phone.adb;
const page = (expression) => phone.evaluate(`(async () => { ${expression} })()`);
const shot = async (name) => shots && (await phone.screenshot(path.join(shots, `attach-${name}.png`)));
const tap = ({ x, y }) => adb("shell", "input", "tap", String(x), String(y));
const press = ({ x, y }) => adb("shell", "input", "swipe", String(x), String(y), String(x), String(y), "900");

// What the system shows: every node of the window's view tree with its words and bounds.
function screen() {
  adb("shell", "uiautomator", "dump", "/data/local/tmp/szf-window.xml");
  const xml = adb("shell", "cat", "/data/local/tmp/szf-window.xml");
  const decode = (text) =>
    text.replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'");
  return [...xml.matchAll(/<node [^>]*>/g)].map(([node]) => {
    const value = (key) => decode(node.match(new RegExp(` ${key}="([^"]*)"`))?.[1] ?? "");
    const [left, top, right, bottom] = (value("bounds").match(/\d+/g) ?? [0, 0, 0, 0]).map(Number);
    return {
      text: value("text"),
      desc: value("content-desc"),
      id: value("resource-id"),
      pkg: value("package"),
      x: Math.round((left + right) / 2),
      y: Math.round((top + bottom) / 2),
      area: (right - left) * (bottom - top),
    };
  });
}
const named = (nodes, words) => nodes.find((n) => n.text === words || n.desc === words);
async function onScreen(words, what, ms = 30_000) {
  return until(() => named(screen(), words), what ?? words, ms);
}

// The page's helpers and where its elements are on the screen (the WebView's bounds from the view tree).
const helpers = `
  window.__szf = {
    panel: () => document.querySelector(".szf-panel"),
    row: (id) => document.querySelector('.szf-panel .szf-row[data-conversation-id="' + id + '"]'),
    rect: (element) => {
      if (!element) return null;
      const box = element.getBoundingClientRect();
      return { x: box.x + box.width / 2, y: box.y + box.height / 2, height: innerHeight };
    },
  };
  return true;`;
function webviewBounds() {
  adb("shell", "uiautomator", "dump", "/data/local/tmp/szf-window.xml");
  const xml = adb("shell", "cat", "/data/local/tmp/szf-window.xml");
  const node = xml.match(/class="android\.webkit\.WebView"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/);
  if (!node) throw Error("no WebView on the screen");
  const [, left, top, right, bottom] = node.map(Number);
  return { left, top, right, bottom };
}
async function screenPoint(expression, what) {
  const at = await until(() => page(`return __szf.rect(${expression});`), what);
  const bounds = webviewBounds();
  const scale = (bounds.bottom - bounds.top) / at.height;
  return { x: Math.round(bounds.left + at.x * scale), y: Math.round(bounds.top + at.y * scale) };
}

// Bo's side: the offers of `names` accepted, and each file as Bo received it.
async function receivedByBo(items, names) {
  for (const name of names) {
    const offer = await until(
      () => items().find((i) => i.kind === "transfer" && i.direction === "in" && i.file?.name === name),
      `the offer of ${name}`,
      120_000,
    );
    const ok = await peer.send("accept_offer", { transfer_id: offer.transfer_id });
    if (!ok.ok) throw Error(`accept_offer: ${JSON.stringify(ok.error)}`);
    const done = await until(
      () => items().find((i) => i.transfer_id === offer.transfer_id && i.state === "received"),
      `${name} received`,
      180_000,
    );
    const copy = done.actions?.find((a) => typeof a.path === "string")?.path;
    const file = Object.values(files).find((f) => f.name === name);
    if (!copy || !(await fs.readFile(copy)).equals(file.bytes)) throw Error(`${name} differs on Bo's side`);
  }
}

const peer = startPeer();
let failed = false;
try {
  await peer.send("activate", {});
  await until(async () => (await fs.readdir(routes)).some((n) => n.endsWith(".entry")), "the Mac's route");
  for (const file of Object.values(files)) {
    const local = path.join(work, file.name);
    await fs.writeFile(local, file.bytes);
    adb("push", local, `/sdcard/Download/${file.name}`);
  }
  await phone.install({ homePhone, routes, page: {}, work });
  await until(() => page(helpers), "the page");
  await until(async () => (await page("return (await window.shenzhenFriends.join()).state;")) === "ready", "Friends");
  if (!(await page("return Boolean(__szf.panel());")))
    tap(await screenPoint(`document.querySelector('[data-szfriends="button"]')`, "the Friends button"));
  tap(await screenPoint(`__szf.row(${JSON.stringify(boInPhone)}).querySelector(".szf-row-main")`, "Bo's row"));
  await until(() => page("return Boolean(document.querySelector('.szf-panel .szf-editor'));"), "the conversation");
  const conversation = await peer.view("open_conversation", { conversation_id: adaInPeer });
  const items = () => conversation()?.items ?? [];

  // Attach files: the paperclip, then the system's own picker.
  const label = await page(`const b = document.querySelector('.szf-panel .szf-attach');
    return b && b.getAttribute('aria-label') + '|' + b.title;`);
  if (label !== "Attach files|Attach files") throw Error(`the paperclip reads ${JSON.stringify(label)}`);
  await shot("1-conversation");
  tap(await screenPoint(`document.querySelector('.szf-panel .szf-attach')`, "the paperclip"));
  await until(() => screen().some((n) => n.pkg.includes("documentsui")), "the system's file picker");
  check("the paperclip, named Attach files, opens the system's file picker");
  // The picker opens where it last was; Downloads holds the files.
  let first = named(screen(), files.survey.name);
  if (!first) {
    tap(await onScreen("Show roots", "the picker's menu"));
    tap(
      await until(
        () => screen().filter((n) => n.text === "Downloads").sort((a, b) => a.y - b.y)[0],
        "Downloads among the roots",
      ),
    );
    first = await onScreen(files.survey.name, "the PDF in Downloads");
  }
  await shot("2-picker");
  // Several at once: a long press selects the first, a tap adds the second, Select returns both.
  press(first);
  tap(await onScreen(files.notes.name, "the text file"));
  await shot("3-picker-selected");
  tap(await until(() => screen().find((n) => n.text === "Select" || n.desc === "Select" || /menu_select|action_menu_select/.test(n.id)), "Select"));
  const chips = await until(
    () =>
      page(`const chips = [...document.querySelectorAll('.szf-panel .szf-chip.attachment')].map((c) => c.innerText.replace('×', '').trim());
        return chips.length === 2 ? chips : null;`),
    "two chips in the composer",
  );
  if (!chips.includes(files.survey.name) || !chips.includes(files.notes.name))
    throw Error(`the chips read ${JSON.stringify(chips)}`);
  check(`both files picked in the system's picker become chips: ${chips.join(", ")}`);
  await shot("4-chips");
  tap(await screenPoint(`document.querySelector('.szf-panel .szf-composer .szf-button.primary')`, "Send"));
  await receivedByBo(items, [files.survey.name, files.notes.name]);
  check("Send gives Bo both picked files, byte for byte (a 6 MB PDF and a text file)");
  await shot("5-sent");

  // Shared from the Files app: long press, Share, "Send to a friend", then Bo.
  adb("shell", "am", "start", "-W", "-n", "com.google.android.documentsui/com.android.documentsui.files.FilesActivity");
  await until(() => screen().some((n) => n.pkg.includes("documentsui")), "the Files app");
  let shared = named(screen(), files.curve.name);
  if (!shared) {
    tap(await onScreen("Show roots", "the Files app's menu"));
    tap(await until(() => screen().filter((n) => n.text === "Downloads").sort((a, b) => a.y - b.y)[0], "Downloads"));
    shared = await onScreen(files.curve.name, "the CSV in Downloads");
  }
  press(shared);
  tap(await until(() => screen().find((n) => n.desc === "Share" || n.text === "Share"), "Share"));
  await shot("6-share-sheet");
  let target = null;
  for (let i = 0; i < 6 && !target; i++) {
    target = await until(() => named(screen(), "Send to a friend"), "Send to a friend", 8_000).catch(() => null);
    if (!target) adb("shell", "input", "swipe", "540", "2000", "540", "900", "400");
  }
  if (!target) throw Error("the share sheet offers no Send to a friend");
  check("the Files app's share sheet offers Send to a friend");
  tap(target);
  await phone.reattach();
  await until(() => page(helpers), "the page again");
  const outgoing = await until(
    () => page(`const o = document.querySelector('.szf-panel .szf-outgoing'); return o && o.innerText;`),
    "Friends open to choose who receives it",
  );
  if (!outgoing.includes(files.curve.name)) throw Error(`the list says ${JSON.stringify(outgoing)}`);
  check(`Friends opens on the list: "${outgoing.split("\n")[0]}"`);
  await shot("7-send-to");
  tap(await screenPoint(`__szf.row(${JSON.stringify(boInPhone)}).querySelector(".szf-row-main")`, "Bo's row"));
  await receivedByBo(items, [files.curve.name]);
  check("a tap on Bo sends the shared file, and it arrives whole");
  await wait(1500);
  await shot("8-shared-sent");
} catch (error) {
  failed = true;
  console.error(String(error?.stack ?? error));
  await shot("failed").catch(() => {});
}
for (const file of Object.values(files)) adb("shell", "rm", "-f", `"/sdcard/Download/${file.name}"`);
peer.close();
await phone.cleanup?.();
await peer.exited;
await fs.rm(work, { recursive: true, force: true }).catch(() => {});
console.log(failed ? "phones-attach: FAILED" : `phones-attach: passed (${checks.length} checks)`);
process.exit(failed ? 1 : 0);
