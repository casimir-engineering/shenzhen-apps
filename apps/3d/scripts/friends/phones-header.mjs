#!/usr/bin/env node
// phones-header.mjs — the owner's "with a model open, the Settings button in the header runs off the right edge" on a
// phone narrower than about 410 dp, end to end on an Android emulator with Shenzhen 3D's debug build with Friends.
//
//   node scripts/friends/phones-header.mjs --serial emulator-NNNN --tools <dir> [--shots <dir>]
//            [--widths 320,360,393,412] [--font-scales 1,1.3]
//
// --tools names the core's built examples, as for phones-keyboard.mjs. For each width (the display's density set so
// the screen is that many dp wide) and each system font scale, the app is started anew, a model with a long name is
// opened as the system's picker hands one over, and then, upright and turned sideways:
//   1. every button the header shows lies inside the screen, and a tap at its middle lands on it;
//   2. each of the header's commands (Open file, Share commented project, Close document, Send project to a friend,
//      Copy Download Link where Friends offers it, Friends, Settings, Help & shortcuts) is either such a button or an
//      item of the header's More menu, opened with a tap, whose items lie inside the screen too;
//   3. Settings, tapped (through More where it is folded there), opens the Settings dialog.
// The display's density and font scale are put back at the end.
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
const widths = (option("widths") ?? "320,360,393,412").split(",").map(Number);
const fontScales = (option("font-scales") ?? "1,1.3").split(",").map(Number);
// Emulators only: a phone on USB is someone's.
if (!/^emulator-\d+$/.test(serial ?? "") || !tools || widths.some((w) => !(w >= 280)) || fontScales.some((s) => !(s > 0))) {
  console.error("usage: phones-header.mjs --serial emulator-NNNN --tools <dir> [--shots <dir>] " +
    "[--widths 320,360,393,412] [--font-scales 1,1.3]");
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
    const value = await Promise.resolve().then(probe).catch(() => null);
    if (value) return value;
    await wait(250);
  }
  throw Error(`timed out waiting for ${what}`);
}

const PACKAGE = "com.shenzhen3d.viewer";
const MODEL = "bracket-for-the-left-hand-side-camera-module-rev-c.stl";
const COMMANDS = [
  "Open file",
  "Share commented project",
  "Close document",
  "Send project to a friend",
  "Copy Download Link",
  "Friends",
  "Settings",
  "Help & shortcuts",
];

const work = await fs.mkdtemp(path.join(os.tmpdir(), "szf-header-"));
const homePhone = path.join(work, "phone");
const routes = path.join(work, "routes");
await fs.mkdir(routes, { mode: 0o700 });
execFileSync(path.join(tools, "befriend"), [homePhone, path.join(work, "bo"), "Ada", "Bo"], { encoding: "utf8" });

const phone = android(serial);
const shell = (...args) => phone.adb("shell", ...args);
const page = (expression) => phone.evaluate(`(async () => { ${expression} })()`);
const physical = shell("wm", "size").match(/Physical size: (\d+)x(\d+)/);
if (!physical) throw Error("the emulator's screen size is unknown");
const physicalWidth = Math.min(Number(physical[1]), Number(physical[2]));

// Where the page is on the screen: the WebView's bounds from the system's view of the window.
function webview() {
  for (let attempt = 1; ; attempt++) {
    try {
      shell("uiautomator", "dump", "/data/local/tmp/szh-window.xml");
      break;
    } catch (error) {
      if (attempt === 6) throw error;
      execFileSync("sleep", ["0.5"]);
    }
  }
  const xml = shell("cat", "/data/local/tmp/szh-window.xml");
  const node = xml.match(/class="android\.webkit\.WebView"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/);
  if (!node) throw Error("no WebView on the screen");
  const [, left, top, right, bottom] = node.map(Number);
  return { left, top, right, bottom };
}
/** A tap with the emulator's own touch input at the middle of what `expression` finds. */
async function tapElement(expression, what) {
  const view = webview();
  const at = await until(
    () =>
      page(`const e = ${expression}; if (!e) return null; const r = e.getBoundingClientRect();
        return r.width && r.height ? { x: r.left + r.width / 2, y: r.top + r.height / 2, w: innerWidth } : null;`),
    what,
    15_000,
  );
  const scale = (view.right - view.left) / at.w;
  shell("input", "tap", String(Math.round(view.left + at.x * scale)), String(Math.round(view.top + at.y * scale)));
}
const shot = async (name) => shots && (await phone.screenshot(path.join(shots, `header-${name}.png`)));

// In the page: what the header shows, and whether each of it is on the screen and takes a tap at its middle.
const measure = `
  const width = document.documentElement.clientWidth;
  const height = document.documentElement.clientHeight;
  const shown = (e) => {
    const r = e.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && getComputedStyle(e).visibility !== "hidden" ? r : null;
  };
  // The Friends button's name carries its badge ("Friends, 2 new"): by what it is.
  const name = (e) => e.dataset.szfriends === "button" ? "Friends"
    : (e.getAttribute("aria-label") || e.title || e.innerText).trim().split("\\n")[0].trim();
  const place = (e) => {
    const r = shown(e);
    if (!r) return null;
    const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
    return { name: name(e), left: r.left, right: r.right, top: r.top, bottom: r.bottom,
      takesTap: Boolean(hit && (hit === e || e.contains(hit))) };
  };
  const header = document.querySelector(".app-header");
  const buttons = [...header.querySelectorAll("button")].map(place).filter(Boolean);
  const menu = [...document.querySelectorAll('.app-header [role="menu"] [role="menuitem"]')].map(place).filter(Boolean);
  const title = document.querySelector(".app-header .document-title > span");
  const titleBox = title && shown(title);
  return { width, height, buttons, menu, more: buttons.some((b) => b.name === "More"),
    title: titleBox ? { shown: Math.round(titleBox.width), whole: title.scrollWidth <= title.clientWidth } : null,
    friends: Boolean(document.querySelector('[data-szfriends="button"]')),
    links: Boolean(document.querySelector('[data-szfriends="copy-download-link"]')) };`;

function outside(item, width) {
  return item.left < -0.5 || item.right > width + 0.5 || item.top < -0.5 || !item.takesTap;
}
const describe = (item) =>
  `${item.name} (${item.left.toFixed(0)}–${item.right.toFixed(0)} px${item.takesTap ? "" : ", covered"})`;

/** The header with a model open, checked as the owner would find it: every command on the screen. */
async function headerFits(label) {
  let last = "";
  const state = await until(async () => {
    const value = await page(measure);
    const key = JSON.stringify(value);
    const same = key === last;
    last = key;
    return same && value;
  }, `${label}: the header to settle`, 20_000);
  await shot(label);
  const bad = state.buttons.filter((b) => outside(b, state.width));
  if (bad.length)
    throw Error(`${label}: header buttons outside the ${state.width} px wide page: ${bad.map(describe).join(", ")}`);
  const wanted = COMMANDS.filter((c) => c !== "Copy Download Link" || state.links);
  const inHeader = new Set(state.buttons.map((b) => b.name));
  let missing = wanted.filter((c) => !inHeader.has(c));
  let menu = [];
  if (missing.length) {
    if (!state.more)
      throw Error(`${label}: ${missing.join(", ")} not in the header, and no More button to find them under`);
    await tapElement(`document.querySelector('.app-header button[aria-label="More"]')`, "More");
    const open = await until(async () => {
      const value = await page(measure);
      return value.menu.length ? value : null;
    }, `${label}: the More menu`, 10_000);
    await wait(800); // drawn before the screenshot
    await shot(`${label}-more`);
    menu = open.menu;
    const badItems = menu.filter((m) => outside(m, open.width) || m.bottom > open.height + 0.5);
    if (badItems.length) throw Error(`${label}: More menu items off the screen: ${badItems.map(describe).join(", ")}`);
    const inMenu = new Set(menu.map((m) => m.name));
    missing = missing.filter((c) => !inMenu.has(c));
    if (missing.length) throw Error(`${label}: ${missing.join(", ")} neither in the header nor under More`);
  }
  // Settings, for real: its button, or More ▸ Settings.
  const settingsDialog = `[...document.querySelectorAll("dialog")].find((d) => d.querySelector("h2")?.innerText === "Settings")`;
  if (inHeader.has("Settings")) {
    await tapElement(`document.querySelector('.app-header button[aria-label="Settings"]')`, "Settings");
  } else {
    if (!menu.length) throw Error(`${label}: Settings is not in the header`);
    await tapElement(
      `[...document.querySelectorAll('.app-header [role="menuitem"]')].find((m) => m.innerText.trim() === "Settings")`,
      "More ▸ Settings",
    );
  }
  await until(() => page(`return Boolean(${settingsDialog}?.open);`), `${label}: the Settings dialog`, 10_000);
  await page(`${settingsDialog}.close(); return true;`);
  await until(() => page(`return !document.querySelector('.app-header [role="menu"]') && !${settingsDialog}.open;`),
    `${label}: Settings and the menu closed`, 10_000);
  const folded = menu.map((m) => m.name);
  const title = state.title ? (state.title.whole ? "whole" : `cut to ${state.title.shown} px`) : "hidden";
  check(`${label}: ${state.buttons.length} header buttons inside ${state.width} px` +
    `${folded.length ? `, ${folded.join(", ")} under More` : ""}; the model's name ${title}; Settings opens`);
}

const setRotation = async (rotation) => {
  shell("settings", "put", "system", "accelerometer_rotation", "0");
  shell("settings", "put", "system", "user_rotation", String(rotation));
  await until(
    () => shell("dumpsys", "window", "displays").includes(`mCurrentRotation=ROTATION_${rotation * 90}`),
    `rotation ${rotation * 90}°`,
    15_000,
  );
  await wait(1500);
};

let failed = false;
try {
  await setRotation(0);
  await phone.install({ homePhone, routes, page: {}, work });
  for (const fontScale of fontScales) {
    for (const width of widths) {
      const label = `${width}dp-font${fontScale}`;
      // The screen `width` dp wide; the app started anew, as the change restarts it on a phone.
      shell("wm", "density", String(Math.round((physicalWidth * 160) / width)));
      shell("settings", "put", "system", "font_scale", String(fontScale));
      shell("am", "force-stop", PACKAGE);
      await wait(800);
      shell("am", "start", "-n", `${PACKAGE}/.MainActivity`);
      await phone.reattach();
      await until(() => page(`return Boolean(document.querySelector('[data-szfriends="button"]'));`),
        `${label}: the Friends button`);
      const seen = await page("return document.documentElement.clientWidth;");
      if (Math.abs(seen - width) > 2) throw Error(`${label}: the page is ${seen} px wide, not ${width}`);
      await page(`const input = document.querySelector("input[type=file]");
        const picked = new DataTransfer();
        picked.items.add(new File(["solid h\\nfacet normal 0 0 1\\nouter loop\\nvertex 0 0 0\\nvertex 10 0 0\\nvertex 0 20 0\\nendloop\\nendfacet\\nendsolid h\\n"], ${JSON.stringify(MODEL)}));
        input.files = picked.files;
        input.dispatchEvent(new Event("change", { bubbles: true }));
        return true;`);
      await until(() => page(`return Boolean(document.querySelector('.app-header button[aria-label="Close document"]'));`),
        `${label}: the model`);
      await headerFits(`${label}-portrait`);
      await setRotation(1);
      await headerFits(`${label}-landscape`);
      await setRotation(0);
    }
  }
} catch (error) {
  failed = true;
  console.error(String(error?.stack ?? error));
  await shot("failed").catch(() => {});
}
await setRotation(0).catch(() => {});
try {
  shell("wm", "density", "reset");
  shell("settings", "put", "system", "font_scale", "1.0");
} catch {
  // The emulator went away first.
}
await phone.cleanup?.();
await fs.rm(work, { recursive: true, force: true }).catch(() => {});
console.log(failed ? "phones-header: FAILED" : `phones-header: passed (${checks.length} checks)`);
process.exit(failed ? 1 : 0);
