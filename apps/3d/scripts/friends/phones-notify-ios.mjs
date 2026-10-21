#!/usr/bin/env node
// phones-notify-ios.mjs — Friends' notifications on Shenzhen 3D for iOS, in a simulator, headless (ADR 0017 §
// Verification): nothing is asked at launch; Turn On on the list's card asks the system; once the person allows it
// (a UI test answers the system's prompt, scripts/friends/ios-link-open's testAllowNotifications), a friend's message
// becomes a local notification request. The Mac's side is a Friends service in a test home of its own, so nothing
// shows on the Mac; the simulator runs without its window.
//
//   node scripts/friends/phones-notify-ios.mjs --udid <simulator> --tools <dir>
//
// A `friends-smoke` simulator build must be installed (platform-build.mjs ios --friends --debug --target aarch64-sim
// --features friends-smoke), freshly (an install remembers the system's answer); --tools as for phones-exchange.mjs. The plugin's Swift half logs FRIENDS-NOTIFY lines
// (asking, asked, posted), which this reads from the simulator's log. Needs xcodegen.
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";

const argv = process.argv.slice(2);
const option = (name) => {
  const index = argv.indexOf(`--${name}`);
  return index >= 0 ? argv[index + 1] : undefined;
};
const udid = option("udid");
const tools = option("tools");
if (!udid || !tools) {
  console.error("usage: phones-notify-ios.mjs --udid <simulator> --tools <dir>");
  process.exit(64);
}
const BUNDLE = "com.shenzhen3d.viewer";
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const simctl = (...args) => execFileSync("xcrun", ["simctl", ...args], { encoding: "utf8" });
const checks = [];
const check = (line) => {
  checks.push(line);
  console.log(`ok ${line}`);
};
async function until(probe, what, ms = 120_000) {
  const begun = Date.now();
  while (Date.now() - begun < ms) {
    const value = await probe();
    if (value) return value;
    await wait(500);
  }
  throw Error(`timed out waiting for ${what}`);
}

const work = await fs.mkdtemp(path.join(os.tmpdir(), "szf-notify-ios-"));
const homePhone = path.join(work, "phone");
const homePeer = path.join(work, "peer");
const routes = path.join(work, "routes");
await fs.mkdir(routes, { mode: 0o700 });
const seeded = execFileSync(path.join(tools, "befriend"), [homePhone, homePeer, "Ada", "Bo"], { encoding: "utf8" });
const [, adaInPeer] = seeded.trim().split(/\s+/);

const peer = (() => {
  const child = spawn(path.join(tools, "loopback-peer"), [homePeer], {
    env: { ...process.env, SZFRIENDS_STATE_DIR: homePeer, SZFRIENDS_TEST_LOOPBACK: routes },
    stdio: ["pipe", "pipe", "inherit"],
  });
  const replies = new Map();
  let sent = 0;
  readline.createInterface({ input: child.stdout }).on("line", (line) => {
    const frame = JSON.parse(line);
    if (frame.type === "reply") replies.set(frame.re, frame);
  });
  return {
    async send(type, fields) {
      const id = `p${++sent}`;
      child.stdin.write(`${JSON.stringify({ type, ...fields })}\n`);
      const reply = await until(() => replies.get(id), `the reply to ${type}`, 30_000);
      if (reply.ok !== true) throw Error(`${type}: ${JSON.stringify(reply.error)}`);
      return reply;
    },
    close: () => child.stdin.end(),
    exited: new Promise((resolve) => child.on("exit", resolve)),
  };
})();

// The UI test that answers the system's prompt with Allow (built once, run when the prompt is up).
async function allower() {
  const project = path.join(work, "link-open");
  await fs.cp(new URL("./ios-link-open", import.meta.url), project, { recursive: true });
  const quiet = { cwd: project, stdio: "pipe", encoding: "utf8" };
  execFileSync("xcodegen", ["generate", "--quiet"], quiet);
  const derived = path.join(project, "build");
  execFileSync("xcodebuild", ["build-for-testing", "-project", "SZFLinkOpen.xcodeproj", "-scheme", "LinkOpen",
    "-destination", `id=${udid}`, "-derivedDataPath", derived], quiet);
  const products = path.join(derived, "Build", "Products");
  const plan = (await fs.readdir(products)).find((name) => name.endsWith(".xctestrun"));
  return () => {
    const run = spawn("xcodebuild", ["test-without-building", "-xctestrun", path.join(products, plan),
      "-destination", `id=${udid}`, "-only-testing:LinkOpen/SZFLinkOpenTests/testAllowNotifications"], { stdio: "ignore" });
    return new Promise((resolve) => run.on("exit", resolve));
  };
}

// The page: Friends opened from its button, the list's card, Turn On after a pause (so the Mac sees nothing was
// asked before), then waiting for the friend's message in the list.
const page = `(async () => {
  const lines = [];
  const until = async (probe, what, ms = 180000) => {
    const begun = Date.now();
    while (Date.now() - begun < ms) { const v = await probe(); if (v) return v; await new Promise((r) => setTimeout(r, 300)); }
    throw Error("timed out waiting for " + what);
  };
  const panel = () => document.querySelector(".szf-panel");
  let ok = true;
  try {
    const bridge = await until(() => window.shenzhenFriends, "the bridge");
    await until(async () => (await bridge.join()).state === "ready", "Friends ready");
    (await until(() => document.querySelector('[data-szfriends="button"]'), "the Friends button")).click();
    await until(() => panel(), "the panel");
    lines.push("ok Friends opens on the list");
    await new Promise((r) => setTimeout(r, 8000));
    const turnOn = await until(
      () => [...panel().querySelectorAll("button")].find((b) => b.innerText.trim() === "Turn On"), "the card's Turn On", 30000);
    turnOn.click();
    lines.push("ok the list's card offers Turn On, tapped");
    await until(() => panel().innerText.includes("${"Hello from Bo on the Mac"}"), "the friend's message in the list");
    lines.push("ok the friend's message shows in the list");
    await new Promise((r) => setTimeout(r, 4000));
  } catch (error) {
    ok = false;
    lines.push("not ok " + (error && error.message || error));
  }
  await window.__TAURI_INTERNALS__.invoke("smoke_report", { ok, lines });
})();`;
const script = path.join(work, "page.js");
await fs.writeFile(script, page);

const now = new Date(Date.now() - 1000);
const started = new Date(now - now.getTimezoneOffset() * 60_000).toISOString().replace("T", " ").slice(0, 19);
const log = (needle) =>
  simctl("spawn", udid, "log", "show", "--style", "compact", "--start", started, "--predicate",
    `process == "Shenzhen 3D" AND eventMessage CONTAINS "${needle}"`);

let failed = false;
let app;
let output = "";
try {
  const allow = await allower();
  // Not asked before: the system's notifications state for the app starts from nothing.
  try {
    execFileSync("xcrun", ["simctl", "terminate", udid, BUNDLE], { stdio: "ignore" });
  } catch {
    // Not running.
  }
  await peer.send("activate", {});
  await until(async () => (await fs.readdir(routes)).some((n) => n.endsWith(".entry")), "the Mac's route");
  const macEntries = (await fs.readdir(routes)).filter((n) => n.endsWith(".entry"));
  app = spawn("xcrun", ["simctl", "launch", "--console", "--terminate-running-process", udid, BUNDLE], {
    env: {
      ...process.env,
      SIMCTL_CHILD_SZFRIENDS_STATE_DIR: homePhone,
      SIMCTL_CHILD_SZFRIENDS_TEST_LOOPBACK: routes,
      SIMCTL_CHILD_SHENZHEN_3D_SMOKE: script,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  app.stdout.setEncoding("utf8");
  app.stdout.on("data", (text) => (output += text));
  await until(
    async () => (await fs.readdir(routes)).some((n) => n.endsWith(".entry") && !macEntries.includes(n)),
    "the phone's route",
  );
  if (/FRIENDS-NOTIFY asking/.test(log("FRIENDS-NOTIFY"))) throw Error("notifications were asked before Turn On");
  check("Friends opens and nothing is asked at launch");
  await until(() => /FRIENDS-NOTIFY asking/.test(log("FRIENDS-NOTIFY")), "the ask after Turn On", 60_000);
  check("Turn On asks the system");
  await allow();
  await until(() => /FRIENDS-NOTIFY asked granted=true/.test(log("FRIENDS-NOTIFY")), "the system's yes", 30_000);
  check("Allow on the system's prompt grants it");
  await wait(2_000);
  await peer.send("send_message", { conversation_id: adaInPeer, text: "Hello from Bo on the Mac", client_token: `ios-notify-${Date.now()}` });
  const posted = await until(
    () => log("FRIENDS-NOTIFY posted").match(/FRIENDS-NOTIFY posted (message:\S+) kind=message added=(\w+)/),
    "the message's notification request",
    90_000,
  );
  if (posted[2] !== "true") throw Error("the notification centre refused the request");
  check(`the friend's message is requested as a local notification (${posted[1]})`);
  // A smoke build reports in its log and quits.
  const report = await until(() => {
    const text = log("SMOKE");
    return /SMOKE-(PASSED|FAILED)/.test(text) && text;
  }, "the page's report", 120_000);
  for (const match of report.matchAll(/SMOKE (.*)$/gm)) console.log(`phone: ${match[1]}`);
  if (!report.includes("SMOKE-PASSED")) throw Error("the page's checks failed");
} catch (error) {
  failed = true;
  console.error(String(error?.stack ?? error));
  console.error(output.slice(-2000));
}
try {
  execFileSync("xcrun", ["simctl", "terminate", udid, BUNDLE], { stdio: "ignore" });
} catch {
  // Gone already: a smoke build quits once it has reported.
}
peer.close();
await peer.exited;
await fs.rm(work, { recursive: true, force: true }).catch(() => {});
console.log(failed ? "phones-notify-ios: FAILED" : `phones-notify-ios: passed (${checks.length} checks)`);
process.exit(failed ? 1 : 0);
