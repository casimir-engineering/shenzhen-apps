#!/usr/bin/env node
// phones-remove.mjs — on an Android emulator, Shenzhen 3D's debug build with Friends (the core in the app's process)
// takes a friend off the list with a long press, Remove and its confirmation, as a person does with a finger: the
// presses are the emulator's own touch input (`adb shell input`), not events made in the page.
//
//   node scripts/friends/phones-remove.mjs --serial emulator-5660 --tools <dir> [--shots <dir>]
//
// --tools names the core's built examples (`cargo build -p szfriends-helper --example befriend` in
// apps/pdf/portable/friends/core-rs: target/debug/examples). The phone's test home is made friends with two others,
// Bo and Cy, with `befriend`, and pushed into the debug app as phones-exchange.mjs does. Checked: the long press
// opens the row's menu and not the conversation; Remove asks first; confirming takes Bo off the list at once and Cy
// stays; after the app is quit and opened again Bo is still not listed (the core kept it), Cy still is.
import { execFileSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
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
  console.error("usage: phones-remove.mjs --serial emulator-NNNN --tools <dir> [--shots <dir>]");
  process.exit(64);
}
const PACKAGE = "com.shenzhen3d.viewer";
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const checks = [];
const check = (line) => {
  checks.push(line);
  console.log(`ok ${line}`);
};
async function until(probe, what, ms = 60_000) {
  const begun = Date.now();
  while (Date.now() - begun < ms) {
    const value = await probe().catch(() => null);
    if (value) return value;
    await wait(250);
  }
  throw Error(`timed out waiting for ${what}`);
}

const work = await fs.mkdtemp(path.join(os.tmpdir(), "szf-remove-"));
const homePhone = path.join(work, "phone");
const routes = path.join(work, "routes");
await fs.mkdir(routes, { mode: 0o700 });
const befriend = (other, name) =>
  execFileSync(path.join(tools, "befriend"), [homePhone, path.join(work, other), "Ada", name], { encoding: "utf8" })
    .trim()
    .split(/\s+/)[0];
const bo = befriend("bo", "Bo");
const cy = befriend("cy", "Cy");

const phone = android(serial);
const page = (expression) => phone.evaluate(`(async () => { ${expression} })()`);
// The page's helpers, defined again after each start of the app.
const helpers = `
  window.__szf = {
    panel: () => document.querySelector(".szf-panel"),
    row: (id) => document.querySelector('.szf-panel .szf-row[data-conversation-id="' + id + '"]'),
    rect: (element) => {
      if (!element) return null;
      const box = element.getBoundingClientRect();
      return { x: box.x + box.width / 2, y: box.y + box.height / 2, dpr: devicePixelRatio, height: innerHeight };
    },
  };
  return true;`;
// Where the page is on the screen: the WebView's bounds from the system's view of the window.
function webviewBounds() {
  phone.adb("shell", "uiautomator", "dump", "/data/local/tmp/szf-window.xml");
  const xml = phone.adb("shell", "cat", "/data/local/tmp/szf-window.xml");
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
const tap = ({ x, y }) => phone.adb("shell", "input", "tap", String(x), String(y));
// A long press: a swipe that does not move, held 900 ms.
const press = ({ x, y }) => phone.adb("shell", "input", "swipe", String(x), String(y), String(x), String(y), "900");
const shot = async (name) => shots && (await phone.screenshot(path.join(shots, `remove-${name}.png`)));

async function openFriends() {
  await until(() => page(helpers), "the page");
  await until(async () => (await page("return (await window.shenzhenFriends.join()).state;")) === "ready", "Friends ready");
  if (!(await page("return Boolean(__szf.panel());")))
    tap(await screenPoint(`document.querySelector('[data-szfriends="button"]')`, "the Friends button"));
  await until(() => page(`return Boolean(__szf.row(${JSON.stringify(cy)}));`), "Cy's row");
}
const listed = (id) => page(`return Boolean(__szf.row(${JSON.stringify(id)}));`);

let failed = false;
try {
  await phone.install({ homePhone, routes, page: {}, work });
  await openFriends();
  if (!(await listed(bo))) throw Error("Bo is not listed");
  check("the panel lists both friends, Bo and Cy");
  await shot("1-list");

  press(await screenPoint(`__szf.row(${JSON.stringify(bo)}).querySelector(".szf-row-main")`, "Bo's row"));
  const items = await until(
    () => page(`const menu = document.querySelector('.szf-row-menu[role=menu]');
      return menu && [...menu.querySelectorAll('[role=menuitem]')].map((item) => item.innerText.trim());`),
    "the row's menu",
  );
  if (JSON.stringify(items) !== JSON.stringify(["Remove"])) throw Error(`the menu offers ${JSON.stringify(items)}`);
  if (await page("return Boolean(document.querySelector('.szf-editor'));"))
    throw Error("the long press opened the conversation");
  if (await page("return getSelection().toString();")) throw Error("the long press selected text");
  check("a long press on Bo's row opens its menu, Remove, and not the conversation");
  await shot("2-menu");

  tap(await screenPoint(`document.querySelector('.szf-row-menu [role=menuitem]')`, "Remove in the menu"));
  const dialog = await until(
    () => page(`const box = document.querySelector('.szf-panel [role=alertdialog]');
      return box && { title: box.querySelector('strong').innerText, text: box.innerText,
        option: Boolean(box.querySelector('input[type=checkbox]')) };`),
    "the confirmation",
  );
  if (dialog.title !== "Remove Bo?") throw Error(`the confirmation reads ${JSON.stringify(dialog)}`);
  check(`Remove asks first: "${dialog.title}"`);
  await shot("3-confirm");

  tap(
    await screenPoint(
      `[...document.querySelectorAll('.szf-panel [role=alertdialog] button')].find((b) => b.innerText.trim() === 'Remove')`,
      "the confirmation's Remove",
    ),
  );
  await until(async () => !(await listed(bo)), "Bo's row gone", 5_000);
  if (!(await listed(cy))) throw Error("Cy left the list too");
  check("confirming takes Bo off the list, and Cy stays");
  await wait(1500);
  if (await listed(bo)) throw Error("Bo came back");
  if (await page("return Boolean(document.querySelector('.szf-notice'));")) throw Error("a failure was shown");
  await shot("4-removed");

  phone.adb("shell", "am", "force-stop", PACKAGE);
  phone.adb("shell", "am", "start", "-n", `${PACKAGE}/.MainActivity`);
  await wait(3000);
  // The app started again: its WebView's DevTools socket is a new one.
  await phone.reattach();
  await openFriends();
  await wait(1500);
  if (await listed(bo)) throw Error("Bo is listed again after the app started again");
  check("after the app is quit and opened again, Bo is still off the list and Cy is on it");
  await shot("5-restarted");
} catch (error) {
  failed = true;
  console.error(String(error?.stack ?? error));
  await shot("failed").catch(() => {});
}
await phone.cleanup?.();
await fs.rm(work, { recursive: true, force: true }).catch(() => {});
console.log(failed ? "phones-remove: FAILED" : `phones-remove: passed (${checks.length} checks)`);
process.exit(failed ? 1 : 0);
