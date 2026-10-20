#!/usr/bin/env node
// android-permissions.mjs — Nearby's Bluetooth permissions on an Android emulator, end to end, through the screen as
// a person sees it (uiautomator; no WebView debugging, so a release-profile APK works too). Emulators only: it clears
// the app's data and permissions between runs, which it refuses to do to a real phone.
//
//   node scripts/friends/android-permissions.mjs --serial emulator-5554 [--apk <apk>]
//
// Two runs from a cleared app:
//   grant  opening Friends brings up the system's Bluetooth ("Nearby devices") dialog; Allow grants scan, advertise
//          and connect.
//   deny   Don't allow leaves Nearby's Allow; Allow asks again; refused again, Android stops asking, and Nearby's
//          Allow is replaced by Open Settings, which opens the app's page in Settings.
import { execFileSync } from "node:child_process";
import os from "node:os";
import path from "node:path";

const PACKAGE = "com.shenzhen3d.viewer";
const PERMISSIONS = ["BLUETOOTH_SCAN", "BLUETOOTH_ADVERTISE", "BLUETOOTH_CONNECT"];
const argv = process.argv.slice(2);
const option = (name) => {
  const index = argv.indexOf(`--${name}`);
  return index >= 0 ? argv[index + 1] : undefined;
};
const serial = option("serial");
if (!serial?.startsWith("emulator-")) {
  console.error("error: --serial must name an emulator (emulator-NNNN): this test clears the app's data");
  process.exit(2);
}
const sdk = process.env.ANDROID_HOME ?? path.join(os.homedir(), "Library/Android/sdk");
const adbPath = path.join(sdk, "platform-tools/adb");
const adb = (...args) => execFileSync(adbPath, ["-s", serial, ...args], { encoding: "utf8", maxBuffer: 1 << 26 });
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const step = (text) => console.log(`==> ${text}`);
const fail = (text) => {
  console.error(`FAIL: ${text}`);
  process.exit(1);
};

/** The screen's accessibility nodes: text, content-desc, resource-id, package and centre. */
function screen() {
  adb("shell", "uiautomator dump /data/local/tmp/szap-ui.xml >/dev/null");
  const xml = adb("shell", "cat /data/local/tmp/szap-ui.xml");
  const nodes = [];
  for (const match of xml.matchAll(/<node [^>]*>/g)) {
    const node = match[0];
    const value = (name) => (node.match(new RegExp(`${name}="([^"]*)"`)) ?? [])[1] ?? "";
    const bounds = value("bounds").match(/\d+/g)?.map(Number) ?? [0, 0, 0, 0];
    nodes.push({
      text: value("text"),
      desc: value("content-desc"),
      id: value("resource-id"),
      pkg: value("package"),
      x: Math.round((bounds[0] + bounds[2]) / 2),
      y: Math.round((bounds[1] + bounds[3]) / 2),
    });
  }
  return nodes;
}

const label = (node) => `${node.text} ${node.desc}`.trim();

/** The first node a test accepts, looked for until `ms` runs out. */
async function find(what, test, ms = 20_000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const node = screen().find(test);
    if (node) return node;
    await wait(700);
  }
  return null;
}

async function tap(what, test, ms) {
  const node = await find(what, test, ms);
  if (!node) fail(`no ${what} on screen`);
  adb("shell", "input", "tap", String(node.x), String(node.y));
  return node;
}

const isDialog = (node) => node.pkg.includes("permissioncontroller") || node.pkg.includes("packageinstaller");
const allowButton = (node) => isDialog(node) && /permission_allow_button|allow_foreground_only|allow_button$/.test(node.id);
const denyButton = (node) => isDialog(node) && /permission_deny/.test(node.id);
const exact = (text) => (node) => node.pkg === PACKAGE && (node.text === text || node.desc === text);

function granted() {
  const dump = adb("shell", "dumpsys", "package", PACKAGE);
  return Object.fromEntries(
    PERMISSIONS.map((name) => [name, new RegExp(`android.permission.${name}: granted=true`).test(dump)]),
  );
}

async function fresh() {
  adb("shell", "am", "force-stop", PACKAGE);
  adb("shell", "pm", "clear", PACKAGE);
  adb("shell", "am", "start", "-W", "-n", `${PACKAGE}/.MainActivity`);
  await wait(4_000);
}

async function openFriends() {
  // The Friends button's label is the badge's or "Friends"; the page may still be loading the helper.
  await tap("Friends button", (node) => node.pkg === PACKAGE && /^Friends\b/.test(label(node)), 60_000);
}

async function openNearby() {
  const tab = await find("Nearby tab", exact("Nearby"), 10_000);
  if (tab) adb("shell", "input", "tap", String(tab.x), String(tab.y));
  await wait(1_000);
}

if (option("apk")) {
  step(`installing ${option("apk")}`);
  adb("install", "-r", option("apk"));
}

// 1. Grant.
step("grant: a cleared app, Friends opened");
await fresh();
await openFriends();
step("grant: the system's dialog comes up; Allow");
await tap("system Allow button", allowButton, 20_000);
await wait(2_000);
const afterGrant = granted();
if (!Object.values(afterGrant).every(Boolean)) fail(`not granted after Allow: ${JSON.stringify(afterGrant)}`);
step(`grant: ${JSON.stringify(afterGrant)}`);

// 2. Deny, ask again, deny for good, then Settings.
step("deny: a cleared app, Friends opened");
await fresh();
await openFriends();
step("deny: Don't allow");
await tap("system Don't allow button", denyButton, 20_000);
await wait(1_500);
await openNearby();
step("deny: Nearby keeps its Allow; tapping it asks again");
await tap("Nearby's Allow", exact("Allow"), 20_000);
await tap("system Don't allow button (second time)", denyButton, 20_000);
await wait(1_500);
step("deny: refused twice; Allow once more, and Android answers without a dialog");
const again = await find("Nearby's Allow", exact("Allow"), 10_000);
if (again) {
  adb("shell", "input", "tap", String(again.x), String(again.y));
  await wait(2_500);
  if (screen().some(isDialog)) fail("the system's dialog came up after two refusals");
}
step("deny: Nearby offers Open Settings, which opens the app's page in Settings");
await tap("Open Settings", exact("Open Settings"), 15_000);
await wait(2_500);
const focus = adb("shell", "dumpsys", "window", "displays").match(/mCurrentFocus=.*$/m)?.[0] ?? "";
if (!/settings/i.test(focus)) fail(`Settings did not open: ${focus}`);
if (Object.values(granted()).some(Boolean)) fail("a permission was granted in the deny run");
step(`deny: ${focus.trim()}`);
adb("shell", "input", "keyevent", "KEYCODE_BACK");
console.log("PASS: grant and deny flows");
