#!/usr/bin/env node
// phones-keyboard.mjs — the owner's "on the phone, chat text box does not come up above the keyboard when you type
// so the keyboard hides it and you can't see what you are typing", end to end on an Android emulator with the
// system's own on-screen keyboard. Shenzhen 3D's debug build with Friends draws edge to edge, where Android 15 and
// later no longer shrink the window for the keyboard; MainActivity.kt makes room for it, src/core/keyboard.ts keeps the
// focused field in sight.
//
//   node scripts/friends/phones-keyboard.mjs --serial emulator-NNNN --tools <dir> [--shots <dir>] [--withhold-ime]
//
// --withhold-ime starts the app (a debug build) with the keyboard left out of the insets its window is given, as on
// phones whose system does not report the keyboard to it (the owner's POCO F7, HyperOS on Android 15): the fields must
// stay above the keyboard all the same.
//
// --tools names the core's built examples (`cargo build -p szfriends-helper --example befriend` in
// apps/pdf/portable/friends/core-rs: target/debug/examples). The emulator must have no hardware keyboard
// (hw.keyboard=no), so the on-screen one comes up. Every field is tapped with the emulator's own touch input and
// typed in with `adb shell input text`; where the keyboard's top edge is comes from the system (`dumpsys window`),
// where the field, the caret and the last message are comes from the page, turned into screen pixels with the
// WebView's bounds. Checked, each with the keyboard up:
//   1. a friend's conversation: the composer, the typed text and its caret are above the keyboard's top edge, and
//      the last message is in sight above the composer;
//   2. the same with a long message of several lines, longer than the composer shows at once;
//   3. the same with the phone turned sideways;
//   4. the other fields: the conversation's search, the list's search, the name in the list's footer and on the
//      profile page, Add by ID, the 3D viewer's own (the assembly's Find a part…, the Notes text), and last, as it
//      resets Friends, the join page's Friends ID (its code field shows only once another device approves);
//   5. the window asks to be resized for the keyboard (adjustResize), not panned: panning cannot bring a field of a
//      full-screen WebView into sight, and some phones report the keyboard to a window only when it asks so.
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
const withholdIme = argv.includes("--withhold-ime");
// Emulators only: a phone on USB is someone's.
if (!/^emulator-\d+$/.test(serial ?? "") || !tools) {
  console.error("usage: phones-keyboard.mjs --serial emulator-NNNN --tools <dir> [--shots <dir>] [--withhold-ime]");
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

const work = await fs.mkdtemp(path.join(os.tmpdir(), "szf-keyboard-"));
const homePhone = path.join(work, "phone");
const routes = path.join(work, "routes");
await fs.mkdir(routes, { mode: 0o700 });
const bo = execFileSync(path.join(tools, "befriend"), [homePhone, path.join(work, "bo"), "Ada", "Bo"], {
  encoding: "utf8",
})
  .trim()
  .split(/\s+/)[0];

const phone = android(serial);
const shell = (...args) => phone.adb("shell", ...args);
const page = (expression) => phone.evaluate(`(async () => { ${expression} })()`);
const helpers = `
  window.__szk = {
    panel: () => document.querySelector(".szf-panel"),
    button: (root, text) => root && [...root.querySelectorAll("button")].find((b) => b.innerText.trim() === text),
    box: (element) => {
      if (!element) return null;
      const r = element.getBoundingClientRect();
      return r.width || r.height ? { top: r.top, bottom: r.bottom, left: r.left, right: r.right } : null;
    },
    caret: () => {
      const selection = getSelection();
      if (!selection.rangeCount) return null;
      const range = selection.getRangeAt(0);
      const rects = range.getClientRects();
      const r = rects.length ? rects[rects.length - 1] : range.getBoundingClientRect();
      return r.height ? { top: r.top, bottom: r.bottom } : null;
    },
  };
  return true;`;
// Where the page is on the screen: the WebView's bounds from the system's view of the window.
function webview() {
  // The dump waits for the screen to be idle and sometimes gives up while the viewer draws: again.
  for (let attempt = 1; ; attempt++) {
    try {
      shell("uiautomator", "dump", "/data/local/tmp/szk-window.xml");
      break;
    } catch (error) {
      if (attempt === 6) throw error;
      execFileSync("sleep", ["0.5"]);
    }
  }
  const xml = shell("cat", "/data/local/tmp/szk-window.xml");
  const node = xml.match(/class="android\.webkit\.WebView"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/);
  if (!node) throw Error("no WebView on the screen");
  const [, left, top, right, bottom] = node.map(Number);
  return { left, top, right, bottom };
}
/** The on-screen keyboard's top edge in screen pixels, or null while it is down (the system's own account). */
function keyboardTop() {
  const dump = shell("dumpsys", "window", "InputMethod");
  if (!/isVisible=true|mViewVisibility=0x0/.test(dump) || /mHasSurface=false/.test(dump)) return null;
  const visible = shell("dumpsys", "input_method");
  if (!/mInputShown=true|mIsInputViewShown=true|isInputViewShown=true/.test(visible)) return null;
  // The keyboard's own visible frame: the ime inset source's frame in the display's insets state.
  const insets = shell("dumpsys", "window", "displays");
  const source = insets.match(/type=ime[^\n]*?frame=\[(\d+),(\d+)\]\[(\d+),(\d+)\][^\n]*?visible=true/);
  if (!source) return null;
  return Number(source[2]);
}
/** A page box in screen pixels. */
function onScreen(box, view, height) {
  const scale = (view.bottom - view.top) / height;
  return { top: view.top + box.top * scale, bottom: view.top + box.bottom * scale, scale };
}
const tapElement = async (expression, what) => {
  // The WebView's bounds first (the slow part), then where the element is, then the tap, at once.
  const view = webview();
  // Out of sight in a scrolling box (Settings is longer than the screen): into view first, as a finger would scroll.
  await until(() => page(`const e = ${expression}; if (!e) return null; const r = e.getBoundingClientRect();
    if (r.top < 0 || r.bottom > innerHeight) e.scrollIntoView({ block: "center" }); return true;`), what);
  await wait(400);
  const at = await until(
    () =>
      page(`const e = ${expression}; if (!e) return null; const r = e.getBoundingClientRect();
        return r.width && r.height ? { x: r.left + r.width / 2, y: r.top + Math.min(r.height / 2, 20), h: innerHeight } : null;`),
    what,
  );
  const scale = (view.bottom - view.top) / at.h;
  shell("input", "tap", String(Math.round(view.left + at.x * scale)), String(Math.round(view.top + at.y * scale)));
};
const shot = async (name) => shots && (await phone.screenshot(path.join(shots, `keyboard-${name}.png`)));
const type = (text) => shell("input", "text", `'${text.replaceAll(" ", "%s")}'`);
const keyboardDown = async () => {
  await page("document.activeElement?.blur(); return true;");
  await until(() => keyboardTop() === null, "the keyboard to go down", 15_000);
  await wait(500);
};
/** The keyboard up and the page settled: the same measurement twice in a row. */
async function settled(measure) {
  let last = "";
  return until(async () => {
    const value = await measure();
    const key = JSON.stringify(value);
    const same = key === last;
    last = key;
    return same && value;
  }, "the page to settle with the keyboard up", 20_000);
}

/** A field tapped and typed in: it, and what was typed, end above the keyboard's top edge. */
async function fieldAboveKeyboard(name, expression, text) {
  await tapElement(expression, name);
  const top = await until(keyboardTop, `the keyboard for ${name}`, 15_000);
  await wait(400);
  type(text);
  await until(
    () => page(`const e = document.activeElement; return (e.value ?? e.innerText ?? "").includes(${JSON.stringify(text)});`),
    `${name} to hold the typed text`,
    15_000,
  );
  const measured = await settled(async () => {
    const view = webview();
    const at = await page(`const e = document.activeElement; return { box: __szk.box(e), height: innerHeight,
      matches: e === (${expression}) };`);
    return { view, ...at, top: keyboardTop() };
  });
  if (!measured.matches) throw Error(`${name} lost the focus`);
  const field = onScreen(measured.box, measured.view, measured.height);
  await shot(name.replaceAll(/[^a-z0-9]+/gi, "-").toLowerCase());
  if (field.bottom > measured.top + 1)
    throw Error(`${name}: its bottom edge is at ${field.bottom.toFixed(0)} px, under the keyboard's top at ${measured.top} px`);
  if (field.top < measured.view.top - 1) throw Error(`${name}: scrolled off the top of the screen`);
  check(`${name}: the field ends at ${field.bottom.toFixed(0)} px, above the keyboard's top at ${top} px, and holds "${text}"`);
  await keyboardDown();
}

/** The conversation with the keyboard up: composer, typed text, caret and last message all above the keyboard. */
async function composerAboveKeyboard(label, expected, sideways = false) {
  const measured = await settled(async () => {
    const view = webview();
    const at = await page(`const panel = __szk.panel();
      const editor = panel.querySelector(".szf-editor");
      const composer = panel.querySelector(".szf-composer");
      const history = panel.querySelector(".szf-history");
      const items = [...history.querySelectorAll("[data-item]")];
      return { height: innerHeight, focused: document.activeElement === editor, text: editor.innerText,
        editor: __szk.box(editor), composer: __szk.box(composer), history: __szk.box(history),
        last: __szk.box(items.at(-1)), lastText: items.at(-1)?.innerText ?? "", caret: __szk.caret() };`);
    return { view, ...at, top: keyboardTop() };
  });
  const { top, view, height } = measured;
  if (top === null) throw Error(`${label}: the keyboard is down`);
  if (!measured.focused) throw Error(`${label}: the composer lost the focus`);
  if (!measured.text.replaceAll(/\s+/g, " ").includes(expected))
    throw Error(`${label}: the composer holds ${JSON.stringify(measured.text)}`);
  const composer = onScreen(measured.composer, view, height);
  const editor = onScreen(measured.editor, view, height);
  view.scale = editor.scale;
  if (composer.bottom > top + 1)
    throw Error(`${label}: the composer's bottom edge is at ${composer.bottom.toFixed(0)} px, ` +
      `under the keyboard's top at ${top} px: what is typed cannot be seen`);
  if (!measured.caret) throw Error(`${label}: no caret`);
  const caret = onScreen(measured.caret, view, height);
  if (caret.bottom > Math.min(top, editor.bottom) + 1 || caret.top < editor.top - 1)
    throw Error(`${label}: the caret (${caret.top.toFixed(0)}–${caret.bottom.toFixed(0)} px) is outside the ` +
      `composer's visible text (${editor.top.toFixed(0)}–${editor.bottom.toFixed(0)} px) or under the keyboard`);
  if (!measured.last) throw Error(`${label}: no message in the history`);
  const last = onScreen(measured.last, view, height);
  const history = onScreen(measured.history, view, height);
  // All of it; sideways, where the history may have room for a line or two only, its end at the bottom.
  const whole = !sideways;
  if (history.bottom - history.top < 30 * view.scale)
    throw Error(`${label}: the history has ${(history.bottom - history.top).toFixed(0)} px left`);
  if (last.bottom > history.bottom + 1 || last.bottom > top || last.bottom < history.top ||
    (whole && last.top < history.top - 1))
    throw Error(`${label}: the last message (${last.top.toFixed(0)}–${last.bottom.toFixed(0)} px) is not in ` +
      `sight in the history (${history.top.toFixed(0)}–${history.bottom.toFixed(0)} px)`);
  return { top, composer, caret, last, lastText: measured.lastText };
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
  await phone.install({ homePhone, routes, page: {}, work,
    extras: withholdIme ? ["--ez", "withholdIme", "true"] : [] });
  await until(() => page(helpers), "the page");
  await until(async () => (await page("return (await window.shenzhenFriends.join()).state;")) === "ready", "Friends ready");
  // A conversation with history: messages to Bo, who is away, so they stay in the history as sent.
  for (let i = 1; i <= 14; i++) {
    const sent = await page(`return (await window.shenzhenFriends.send("send_message", { conversation_id: ${JSON.stringify(bo)},
      text: "Earlier message ${i}", client_token: "keyboard-${i}-${Date.now()}" })).reply;`);
    if (sent?.ok !== true) throw Error(`send_message: ${JSON.stringify(sent)}`);
  }
  await tapElement(`document.querySelector('[data-szfriends="button"]')`, "the Friends button");
  await until(() => page("return Boolean(__szk.panel());"), "the Friends panel");
  await tapElement(
    `[...document.querySelectorAll(".szf-panel .szf-row")].find((r) => r.innerText.includes("Bo"))`,
    "Bo's row",
  );
  await until(
    () => page(`const items = [...(__szk.panel()?.querySelectorAll(".szf-history [data-item]") ?? [])];
      return items.at(-1)?.innerText.includes("Earlier message 14");`),
    "Bo's conversation with its history",
  );
  check("Bo's conversation is open, its history ending with the last of 14 messages");
  await shot("1-conversation");

  // 1. The composer tapped, a line typed.
  await tapElement(`__szk.panel().querySelector(".szf-editor")`, "the composer");
  await until(keyboardTop, "the on-screen keyboard", 15_000);
  await wait(500);
  type("Hello from the keyboard test");
  const one = await composerAboveKeyboard("portrait", "Hello from the keyboard test");
  await shot("2-portrait-typed");
  check(`portrait: the composer ends at ${one.composer.bottom.toFixed(0)} px, above the keyboard's top at ${one.top} px; ` +
    `the caret and the last message ("${one.lastText.trim().split("\n")[0]}") are in sight`);

  // 2. A long message, more lines than the composer shows at once. (Return sends: a phone's message runs on.)
  for (let part = 1; part <= 6; part++) type(` and part ${part} of a long message that wraps on a phone screen`);
  const two = await composerAboveKeyboard("long message", "part 6 of a long message");
  const lines = await page(`const e = __szk.panel().querySelector(".szf-editor");
    return { shown: e.clientHeight, all: e.scrollHeight, line: parseFloat(getComputedStyle(e).lineHeight) || 20 };`);
  if (lines.all <= lines.shown + 4) throw Error(`the long message fits the composer: ${JSON.stringify(lines)}`);
  await shot("3-portrait-long");
  check(`long message: about ${Math.round(lines.all / lines.line)} lines typed, more than the composer shows; it ends at ` +
    `${two.composer.bottom.toFixed(0)} px above the keyboard's top at ${two.top} px, the caret on the last line and ` +
    `the last message in sight`);

  // 3. Sideways.
  await setRotation(1);
  if ((await until(() => page("return true;"), "the page after turning")) && keyboardTop() === null) {
    await tapElement(`__szk.panel().querySelector(".szf-editor")`, "the composer, sideways");
    await until(keyboardTop, "the on-screen keyboard, sideways", 15_000);
  }
  await wait(800);
  type(" sideways");
  const three = await composerAboveKeyboard("landscape", "sideways", true);
  await shot("4-landscape");
  check(`landscape: the composer ends at ${three.composer.bottom.toFixed(0)} px, above the keyboard's top at ` +
    `${three.top} px; the caret and the end of the last message are in sight`);
  await keyboardDown();
  await setRotation(0);

  // 4. The other fields.
  await page(`__szk.panel().querySelector(".szf-editor").replaceChildren(); return true;`);
  await tapElement(`__szk.panel().querySelector(".szf-search-button")`, "Search this conversation");
  await until(() => page(`return Boolean(document.querySelector(".szf-panel .szf-conversation-search input"));`),
    "the conversation's search field");
  await fieldAboveKeyboard(
    "the conversation's search",
    `document.querySelector(".szf-panel .szf-conversation-search input")`,
    "Earlier",
  );
  await page(`document.querySelector(".szf-panel .szf-conversation-search input") && document.activeElement?.blur();
    __szk.panel().querySelector(".szf-back, [aria-label='Back'], .szf-page-header button")?.click(); return true;`);
  await until(() => page(`return Boolean(document.querySelector('.szf-panel input[type="search"]'));`), "the list");
  await fieldAboveKeyboard("the list's search", `document.querySelector('.szf-panel input[type="search"]')`, "Bo");
  await page(`const s = document.querySelector('.szf-panel input[type="search"]');
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(s, "");
    s.dispatchEvent(new Event("input", { bubbles: true })); return true;`);
  // The name in the list's footer, edited in place.
  await tapElement(`document.querySelector(".szf-panel .szf-footer-name")`, "the name in the footer");
  await until(() => page(`return Boolean(document.querySelector(".szf-panel .szf-footer input"));`), "the name field");
  await fieldAboveKeyboard("the footer's name", `document.querySelector(".szf-panel .szf-footer input")`, "Ada");
  // The profile page, as Add by ID opens it.
  await page(`__szk.button(__szk.panel(), "Add by ID")?.click(); return true;`);
  const fields = `[...document.querySelectorAll(".szf-panel .szf-profile input")].filter((i) => i.type === "text")`;
  const profile = await until(() => page(`return ${fields}.length;`), "the profile page's fields", 15_000);
  if (profile < 2) throw Error(`the profile page shows ${profile} text field(s)`);
  await fieldAboveKeyboard("the profile page's name", `${fields}[0]`, "Ada");
  await fieldAboveKeyboard("Add by ID", `${fields}.at(-1)`, "ABCD");

  // The viewer's own fields, with a model open (as the system's picker hands one over).
  await tapElement(`document.querySelector('[data-szfriends="button"]')`, "the Friends button");
  await until(() => page("return !__szk.panel();"), "the Friends panel closed", 10_000);
  await page(`const input = document.querySelector("input[type=file]");
    const picked = new DataTransfer();
    picked.items.add(new File(["solid k\\nfacet normal 0 0 1\\nouter loop\\nvertex 0 0 0\\nvertex 10 0 0\\nvertex 0 20 0\\nendloop\\nendfacet\\nendsolid k\\n"], "keyboard-part.stl"));
    input.files = picked.files;
    input.dispatchEvent(new Event("change", { bubbles: true }));
    return true;`);
  await until(() => page(`return document.querySelector(".status-bar")?.innerText.includes("keyboard-part");`), "the model");
  await tapElement(`document.querySelector('[title="Show assembly"]')`, "Show assembly");
  await fieldAboveKeyboard("the assembly's Find a part…", `document.querySelector('[aria-label="Search assembly"]')`, "part");
  await page(`document.querySelector('[title="Hide assembly"]')?.click(); return true;`);
  await tapElement(`document.querySelector('[title="Show measurements"]')`, "Show measurements");
  await tapElement(
    `[...document.querySelectorAll(".inspector-tabs button")].find((b) => b.innerText.startsWith("Notes"))`,
    "the Notes tab",
  );
  await tapElement(`document.querySelector('[title^="Add note"]')`, "Add note");
  await fieldAboveKeyboard("the Notes text", `document.querySelector('[aria-label="Annotation text"]')`, "Check this edge");
  await shot("5-fields");

  // Last, as it resets this test's Friends: the join page's Friends ID field (Settings ▸ Use my existing profile…).
  await page(`document.querySelector('.mobile-close[aria-label="Close measurements"]')?.click(); return true;`);
  // Settings, or More ▸ Settings where a narrow header folds it there (phones-header.mjs).
  const settingsButton = `document.querySelector('.app-header button[title="Settings"]')`;
  if (await page(`return !${settingsButton}.getBoundingClientRect().width;`)) {
    await tapElement(`document.querySelector('.app-header button[aria-label="More"]')`, "More");
    await tapElement(
      `[...document.querySelectorAll('.app-header [role="menuitem"]')].find((m) => m.innerText.trim() === "Settings")`,
      "More ▸ Settings",
    );
  } else {
    await tapElement(settingsButton, "Settings in the header");
  }
  const settings = `document.querySelector('[data-szfriends="settings"]')`;
  await tapElement(`__szk.button(${settings}, "Use my existing profile…")`, "Use my existing profile… in Settings");
  const confirmBox = `document.querySelector('[data-szfriends="settings"] [role=alertdialog]')`;
  await tapElement(`__szk.button(${confirmBox}, "Delete and Continue")`, "Delete and Continue");
  await until(() => page(`return Boolean(document.querySelector(".szf-panel .szf-join input"));`), "the join page", 60_000);
  await fieldAboveKeyboard("the join page's Friends ID", `document.querySelector(".szf-panel .szf-join input")`, "kitten");

  // 5, checked last so the fields above are seen either way: resized for the keyboard, not panned.
  const mode = shell("dumpsys", "window", "windows")
    .split(/\n(?=\s*Window #)/)
    .find((w) => w.includes("com.shenzhen3d.viewer/com.shenzhen3d.viewer.MainActivity"))
    ?.match(/sim=\{adjust=(\w+)/)?.[1];
  if (mode !== "resize") throw Error(`the window is ${mode ? `adjust=${mode}` : "not found"}, not adjust=resize`);
  check("the window is resized for the keyboard (adjust=resize), not panned");
} catch (error) {
  failed = true;
  console.error(String(error?.stack ?? error));
  await shot("failed").catch(() => {});
}
await setRotation(0).catch(() => {});
await phone.cleanup?.();
await fs.rm(work, { recursive: true, force: true }).catch(() => {});
console.log(failed ? "phones-keyboard: FAILED" : `phones-keyboard: passed (${checks.length} checks)`);
process.exit(failed ? 1 : 0);
