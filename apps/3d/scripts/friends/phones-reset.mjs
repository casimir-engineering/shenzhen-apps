#!/usr/bin/env node
// phones-reset.mjs — on an Android emulator, Shenzhen 3D's debug build with Friends (the core in the app's process)
// resets Friends from Settings as a person does with a finger: the taps are the emulator's own touch input
// (`adb shell input`), not events made in the page.
//
//   node scripts/friends/phones-reset.mjs --serial emulator-5704 --tools <dir> [--shots <dir>]
//
// --tools names the core's built examples (`cargo build -p szfriends-helper --example befriend` in
// apps/pdf/portable/friends/core-rs: target/debug/examples). The phone's test home is made friends with Bo and Cy with
// `befriend`, and pushed into the debug app as phones-exchange.mjs does. Checked: Settings ▸ Reset Friends… asks
// first; confirming shows a new, different Friends ID in Settings at once and in the Friends panel, with Bo and Cy
// gone and nothing reported as failed; Nearby runs again (the phone writes a new entry on the test network); after the
// app is quit and opened again the new ID is still the one shown.
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
  console.error("usage: phones-reset.mjs --serial emulator-NNNN --tools <dir> [--shots <dir>]");
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
    const value = await Promise.resolve().then(probe).catch(() => null);
    if (value) return value;
    await wait(250);
  }
  throw Error(`timed out waiting for ${what}`);
}

const work = await fs.mkdtemp(path.join(os.tmpdir(), "szf-reset-"));
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
    settings: () => document.querySelector('[data-szfriends="settings"]'),
    settingsId: () => document.querySelector('[data-szfriends="settings"] .szf-id')?.innerText.trim() ?? null,
    button: (root, text) => root && [...root.querySelectorAll("button")].find((b) => b.innerText.trim() === text),
    dialog: () => document.querySelector('[role=alertdialog]'),
    rect: (element) => {
      if (!element) return null;
      element.scrollIntoView({ block: "center" });
      const box = element.getBoundingClientRect();
      if (!box.width || !box.height) return null;
      return { x: box.x + box.width / 2, y: box.y + box.height / 2, height: innerHeight };
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
  // Scrolled into view: let it settle before the system is asked where the page is.
  await wait(300);
  const again = (await page(`return __szf.rect(${expression});`)) ?? at;
  const bounds = webviewBounds();
  const scale = (bounds.bottom - bounds.top) / again.height;
  return { x: Math.round(bounds.left + again.x * scale), y: Math.round(bounds.top + again.y * scale) };
}
const tap = ({ x, y }) => phone.adb("shell", "input", "tap", String(x), String(y));
const shot = async (name) => shots && (await phone.screenshot(path.join(shots, `reset-${name}.png`)));
const listed = (id) => page(`return Boolean(__szf.row(${JSON.stringify(id)}));`);
// The ports of the phone's own entries on the test network: one per listener while Nearby runs.
function nearbyPorts() {
  const text = phone.adb("shell", `run-as ${PACKAGE} sh -c 'cat files/froutes/*.entry 2>/dev/null; true'`);
  return new Set([...text.matchAll(/"port":(\d+)/g)].map((match) => Number(match[1])));
}

async function ready() {
  await until(() => page(helpers), "the page");
  await until(async () => (await page("return (await window.shenzhenFriends.join()).state;")) === "ready", "Friends ready");
}
async function openPanel() {
  if (!(await page("return Boolean(__szf.panel());")))
    tap(await screenPoint(`document.querySelector('[data-szfriends="button"]')`, "the Friends button"));
  await until(() => page("return Boolean(__szf.panel());"), "the Friends panel");
}
async function closePanel() {
  if (await page("return Boolean(__szf.panel());"))
    tap(await screenPoint(`document.querySelector('[data-szfriends="button"]')`, "the Friends button"));
  await until(async () => !(await page("return Boolean(__szf.panel());")), "the Friends panel closed", 10_000);
}
async function openSettings() {
  tap(await screenPoint(`document.querySelector('button[title="Settings"]')`, "the Settings button"));
  return until(() => page("return __szf.settingsId();"), "the Friends ID in Settings");
}

let failed = false;
try {
  await phone.install({ homePhone, routes, page: {}, work });
  await ready();
  await openPanel();
  await until(() => listed(cy), "Cy's row");
  if (!(await listed(bo))) throw Error("Bo is not listed");
  check("the panel lists both friends, Bo and Cy");
  const before = await until(() => (nearbyPorts().size ? nearbyPorts() : null), "the phone on the test network");
  check(`Nearby runs: the phone's entries on the test network (ports ${[...before].join(", ")})`);
  await closePanel();
  await shot("1-list");

  const oldId = await openSettings();
  check(`Settings shows the Friends ID ${oldId}`);
  tap(await screenPoint(`__szf.button(__szf.settings(), "Reset Friends…")`, "Reset Friends… in Settings"));
  const dialog = await until(
    () => page(`const box = __szf.dialog();
      return box && { title: box.querySelector('strong')?.innerText, text: box.innerText };`),
    "the confirmation",
  );
  if (dialog.title !== "Reset Friends?") throw Error(`the confirmation reads ${JSON.stringify(dialog)}`);
  if (!/Files you received stay/.test(dialog.text)) throw Error(`the confirmation reads ${JSON.stringify(dialog)}`);
  check(`Reset Friends… asks first: "${dialog.title}"`);
  await shot("2-confirm");

  tap(await screenPoint(`__szf.button(__szf.dialog(), "Reset Friends")`, "the confirmation's Reset Friends"));
  const confirmed = Date.now();
  const newId = await until(async () => {
    const shown = await page("return __szf.settingsId();");
    return shown && shown !== oldId ? shown : null;
  }, "a new ID in Settings", 40_000);
  check(`confirming shows a new Friends ID in Settings: ${oldId} became ${newId}, ${Date.now() - confirmed} ms later`);
  await wait(1500);
  if (await page("return Boolean(document.querySelector('.szf-notice, .szf-refusal'));")) throw Error("a failure was shown");
  if ((await page("return __szf.settingsId();")) !== newId) throw Error("the ID changed again");
  await shot("3-reset");

  const after = await until(
    () => [...nearbyPorts()].some((port) => !before.has(port)) && nearbyPorts(),
    "the phone back on the test network",
  );
  check(`Nearby runs again: the phone wrote a new entry on the test network (ports ${[...after].join(", ")})`);

  await page("document.querySelector('dialog.settings-dialog[open]')?.close(); return true;");
  await openPanel();
  await wait(1500);
  if ((await listed(bo)) || (await listed(cy))) throw Error("a friend from before the reset is still listed");
  const shownInPanel = await page(`return __szf.panel().innerText;`);
  if (!shownInPanel.replaceAll("‑", "-").includes(newId.replaceAll("‑", "-")))
    throw Error(`the panel does not show the new ID: ${JSON.stringify(shownInPanel.slice(0, 400))}`);
  check("the Friends panel lists neither Bo nor Cy, and shows the new ID");
  await shot("4-panel");

  phone.adb("shell", "am", "force-stop", PACKAGE);
  phone.adb("shell", "am", "start", "-n", `${PACKAGE}/.MainActivity`);
  await wait(3000);
  // The app started again: its WebView's DevTools socket is a new one.
  await phone.reattach();
  await ready();
  const kept = await openSettings();
  if (kept !== newId) throw Error(`after the app started again Settings shows ${kept}, not ${newId}`);
  check("after the app is quit and opened again, Settings still shows the new ID");
  await shot("5-restarted");
} catch (error) {
  failed = true;
  console.error(String(error?.stack ?? error));
  await shot("failed").catch(() => {});
}
await phone.cleanup?.();
await fs.rm(work, { recursive: true, force: true }).catch(() => {});
console.log(failed ? "phones-reset: FAILED" : `phones-reset: passed (${checks.length} checks)`);
process.exit(failed ? 1 : 0);
