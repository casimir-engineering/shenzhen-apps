#!/usr/bin/env node
// phones-get-again.mjs — the owner's "I should be able to download any previous file that is available on a device",
// with real taps: Shenzhen 3D's debug build with Friends on an Android emulator (the core in the app's process) and
// ShenzhenPDF's real Friends dropdown on the Mac (friends-ui-e2e's phone flow, offscreen) share one profile; a friend
// (the core's `loopback-peer`) sends them a file. The person deletes it and gets it back: on the phone from the Mac
// (Get), on the Mac from the phone (Get), on the phone from the friend once neither has it (Get again), and, after the
// friend changed the file they sent, hears "Fay doesn’t have this file anymore."
//
//   node scripts/friends/phones-get-again.mjs --serial emulator-NNNN --tools <dir> --mac <dir> --manifest <file>
//        [--shots <dir>]
//
// --tools: shenzhen-pdf's core-rs target directory with `befriend`, `loopback-peer` (examples) and `szfriends-testnet`
// (cargo build -p szfriends-helper --examples; cargo build -p szfriends-interop --bin szfriends-testnet). --mac:
// build/friends-ui-e2e (make friends-ui-e2e builds SPDFMacFriendsUIE2ETests and szfriends-e2e-helper). --manifest:
// the animal manifest. Phone and Mac meet on the core's loopback test network: the phone's entries reach the Mac's
// directory through adb (phones-exchange-android.mjs), and `szfriends-testnet dir` joins that directory to the Mac
// helper's Bonjour test type on lo0. Joining and the friend's file are set up through each side's client protocol;
// every Get, Get again and Accept is a tap on the phone (the emulator's own touch input) or a click in the dropdown.
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs/promises";
import { randomBytes } from "node:crypto";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { android } from "./phones-exchange-android.mjs";

const argv = process.argv.slice(2);
const option = (name) => {
  const index = argv.indexOf(`--${name}`);
  return index >= 0 ? argv[index + 1] : undefined;
};
const [serial, tools, macDir, manifest, shots] = ["serial", "tools", "mac", "manifest", "shots"].map(option);
if (!/^emulator-\d+$/.test(serial ?? "") || !tools || !macDir || !manifest) {
  console.error("usage: phones-get-again.mjs --serial emulator-NNNN --tools <dir> --mac <dir> --manifest <file>");
  process.exit(64);
}
const PACKAGE = "com.shenzhen3d.viewer";
const FILE = "Bracket.stl";
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const checks = [];
const check = (line) => {
  checks.push(line);
  console.log(`ok ${line}`);
};
async function until(probe, what, ms = 90_000) {
  const begun = Date.now();
  while (Date.now() - begun < ms) {
    const value = await probe().catch(() => null);
    if (value) return value;
    await wait(300);
  }
  throw Error(`timed out waiting for ${what}`);
}

const work = await fs.mkdtemp(path.join(os.tmpdir(), "szf-again-"));
const [homePhone, homeFay, routes] = ["phone", "fay", "routes"].map((n) => path.join(work, n));
await fs.mkdir(routes, { mode: 0o700 });
const serviceType = `_szfe${randomBytes(4).toString("hex")}._tcp`;
const [fayInPhone, adaInFay] = execFileSync(path.join(tools, "examples", "befriend"), [homePhone, homeFay, "Ada", "Fay"],
  { encoding: "utf8" }).trim().split(/\s+/);
const children = [];
const started = (child) => (children.push(child), child);

// The bridge between the routes directory and the Mac helper's Bonjour test type.
const bridge = started(spawn(path.join(tools, "szfriends-testnet"), ["dir", routes, serviceType],
  { stdio: ["pipe", "inherit", "inherit"] }));

// Fay: the core's loopback peer, one intent per line in, every frame out.
const fay = started(spawn(path.join(tools, "examples", "loopback-peer"), [homeFay], {
  env: { ...process.env, SZFRIENDS_STATE_DIR: homeFay, SZFRIENDS_TEST_LOOPBACK: routes },
  stdio: ["pipe", "pipe", "inherit"],
}));
const fayFrames = [];
readline.createInterface({ input: fay.stdout }).on("line", (line) => {
  try {
    fayFrames.push(JSON.parse(line));
  } catch {}
});
let fayNext = 0;
async function fayIntent(type, fields = {}) {
  const id = `p${++fayNext}`;
  fay.stdin.write(`${JSON.stringify({ type, ...fields })}\n`);
  const reply = await until(async () => fayFrames.find((f) => f.type === "reply" && f.re === id), `Fay's ${type}`);
  if (!reply.ok) throw Error(`Fay's ${type}: ${JSON.stringify(reply)}`);
  return reply.result;
}

// The Mac: friends-ui-e2e's phone flow, one command per line through two FIFOs.
const [macIn, macOut] = [path.join(work, "mac-in"), path.join(work, "mac-out")];
execFileSync("mkfifo", [macIn, macOut]);
started(spawn(path.join(macDir, "SPDFMacFriendsUIE2ETests"),
  [path.join(macDir, "szfriends-e2e-helper"), manifest, shots ? path.join(shots, "mac") : path.join(work, "mac-shots")],
  { env: { ...process.env, FRIENDS_UI_E2E_FLOWS: "phone", FRIENDS_UI_E2E_VARIANTS: "light-normal",
           FRIENDS_UI_E2E_PHONE_IN: macIn, FRIENDS_UI_E2E_PHONE_OUT: macOut, SZFRIENDS_E2E_SERVICE_TYPE: serviceType },
    stdio: ["ignore", "inherit", "inherit"] }));
const macAnswers = readline.createInterface({ input: (await fs.open(macOut, "r")).createReadStream() })[
  Symbol.asyncIterator]();
const macCommands = await fs.open(macIn, "w");
const macReady = (await macAnswers.next()).value;
if (!JSON.parse(macReady).ok) throw Error(`the Mac did not start: ${macReady}`);
async function mac(cmd, fields = {}) {
  await macCommands.write(`${JSON.stringify({ cmd, ...fields })}\n`);
  const answer = JSON.parse((await macAnswers.next()).value);
  if (!answer.ok && !fields.mayFail) throw Error(`the Mac's ${cmd}: ${JSON.stringify(answer)}`);
  return answer;
}

// The phone.
const phone = android(serial);
const page = (body) => phone.evaluate(`(async () => { ${body} })()`);
const phoneSend = (type, fields = {}) =>
  page(`return await window.shenzhenFriends.send(${JSON.stringify(type)}, ${JSON.stringify(fields)});`);
async function phoneData(type, fields) {
  const { reply, snapshot } = await phoneSend(type, fields);
  if (reply?.result?.subscription) await phoneSend("unsubscribe", { subscription: reply.result.subscription });
  return snapshot?.data;
}
function webviewBounds() {
  phone.adb("shell", "uiautomator", "dump", "/data/local/tmp/szf-window.xml");
  const xml = phone.adb("shell", "cat", "/data/local/tmp/szf-window.xml");
  const node = xml.match(/class="android\.webkit\.WebView"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/);
  if (!node) throw Error("no WebView on the screen");
  const [, left, top, , bottom] = node.map(Number);
  return { left, top, bottom };
}
// A tap where a person would put a finger: the element's centre, scrolled into sight, in screen pixels.
async function tap(expression, what) {
  const at = await until(() => page(`const e = ${expression}; if (!e) return null; e.scrollIntoView({block: "center"});
    const b = e.getBoundingClientRect(); return { x: b.x + b.width / 2, y: b.y + b.height / 2, height: innerHeight };`),
  what);
  const bounds = webviewBounds();
  const scale = (bounds.bottom - bounds.top) / at.height;
  phone.adb("shell", "input", "tap", String(Math.round(bounds.left + at.x * scale)),
    String(Math.round(bounds.top + at.y * scale)));
}
const transfer = (id) => `document.querySelector('.szf-panel .szf-transfer[data-item="${id}"]')`;
const buttonIn = (id, label) =>
  `[...(${transfer(id)}?.querySelectorAll("button") ?? [])].find((b) => b.innerText.trim() === ${JSON.stringify(label)})`;
const phoneItem = (id) => page(`const t = ${transfer(id)}; return t && { text: t.innerText,
  buttons: [...t.querySelectorAll("button")].map((b) => b.innerText.trim()) };`);
// After a moment: the emulator's screen follows the page a frame or two behind.
const shot = async (name) => shots && (await wait(800), await phone.screenshot(path.join(shots, "phone", `${name}.png`)));
// Back to the list, then the chat again, as a person coming back to it does.
async function phoneOpenChat() {
  await until(() => page(`return Boolean(window.shenzhenFriends);`), "the page");
  if (!(await page(`return Boolean(document.querySelector(".szf-panel"));`)))
    await tap(`document.querySelector('[data-szfriends="button"]')`, "the Friends button");
  if (await page(`return Boolean(document.querySelector(".szf-panel .szf-back"));`))
    await tap(`document.querySelector(".szf-panel .szf-back")`, "Back");
  await tap(`document.querySelector('.szf-panel .szf-row[data-conversation-id="${fayInPhone}"] .szf-row-main')`,
    "Fay's row");
  await until(() => page(`return Boolean(document.querySelector(".szf-panel .szf-editor"));`), "Fay's chat");
}
async function phonePath(transferId) {
  const data = await phoneData("open_conversation", { conversation_id: fayInPhone });
  return data?.items?.find((i) => i.transfer_id === transferId)?.file?.path ?? null;
}
const phoneHas = (file) => {
  try {
    return phone.adb("shell", `run-as ${PACKAGE} sh -c 'test -f "${file}" && echo yes'`).trim() === "yes";
  } catch {
    return false;
  }
};
async function macPath(conversation, transferId) {
  const { data } = await mac("conversation", { id: conversation });
  return data?.items?.find((i) => i.transfer_id === transferId)?.file?.path ?? null;
}

let failed = false;
try {
  await until(async () => fayFrames.some((f) => f.type === "ready"), "Fay's helper");
  await fayIntent("activate");
  await phone.install({ homePhone, routes, page: {}, work });
  await until(async () => (await page(`return (await window.shenzhenFriends.join()).state;`)) === "ready", "Friends");
  // The person opens Friends: Nearby starts, so the Mac can find the phone.
  await tap(`document.querySelector('[data-szfriends="button"]')`, "the Friends button");
  await phoneSend("activate");

  // One profile: the Mac asks to join the phone's by its Friends ID; the phone approves; the Mac enters the code.
  const id = await until(async () => (await phoneData("subscribe", { view: "profile" }))?.id?.friends_id, "the ID");
  await mac("intent", { type: "join_profile", fields: { friends_id: id } });
  const asked = await until(async () => (await phoneData("subscribe", { view: "list" }))?.join_requests?.find(
    (r) => r.state === "waiting"), "the Mac's join request on the phone");
  await phoneSend("approve_join", { join_id: asked.join_id });
  const code = await until(async () => (await phoneData("subscribe", { view: "list" }))?.join_requests?.find(
    (r) => r.code)?.code, "the code on the phone");
  await mac("intent", { type: "enter_join_code", fields: { code: code.replace(/\s/g, "") } });
  await until(async () => (await mac("data", { view: "join" })).data?.state === "joined", "the Mac joined");
  const fayInMac = await until(async () => (await mac("data", { view: "list" })).data?.rows?.find(
    (r) => r.title === "Fay")?.conversation_id, "Fay on the Mac");
  check("the Mac joined the phone's profile, and lists Fay");

  // Fay sends a file; the phone accepts it with a tap; it copies to the Mac by itself.
  const source = path.join(work, "fay-files", FILE);
  await fs.mkdir(path.dirname(source), { recursive: true });
  await fs.writeFile(source, Buffer.from(Array.from({ length: 150_000 }, (_, i) => (i * 7) % 251)));
  const sent = await fayIntent("send_files", { conversation_id: adaInFay, files: [{ path: source }],
    client_token: "phones-get-again-0123456789abcdef" });
  const id0 = sent.transfer_ids[0];
  await phoneOpenChat();
  await tap(buttonIn(id0, "Accept"), "Accept on Fay's file");
  await until(async () => (await phoneItem(id0))?.buttons.includes("Share…"), "the file received on the phone");
  const onPhone = await phonePath(id0);
  const onMac = await until(() => macPath(fayInMac, id0), "the copy on the Mac");
  if (!phoneHas(onPhone)) throw Error(`the phone's file is not at ${onPhone}`);
  check("Fay's file is accepted with a tap, and copies to the Mac by itself");
  await shot("1-received");

  // On the phone: deleted, then Get from the Mac.
  phone.adb("shell", `run-as ${PACKAGE} rm "${onPhone}"`);
  await phoneOpenChat();
  const onDevice = await until(async () => {
    const item = await phoneItem(id0);
    return item?.buttons.includes("Get") && item.text.includes("On Test computer mac") && item;
  }, "On Test computer mac · Get on the phone");
  await shot("2-on-mac");
  await tap(buttonIn(id0, "Get"), "Get");
  await until(async () => (await phoneItem(id0))?.buttons.includes("Share…"), "the file back on the phone");
  const back = await phonePath(id0);
  if (!phoneHas(back)) throw Error("the phone's copy is not there");
  check(`phone: deleted, then "${onDevice.text.split("\n").find((l) => l.startsWith("On "))}" · Get, tapped: back`);
  await shot("3-back-from-mac");

  // On the Mac: deleted, then Get from the phone, clicked in the dropdown.
  await fs.rm(onMac, { force: true });
  // The phone as the Mac names it: its own name from the system (Settings ▸ About), never "Computer".
  const phoneName = phone.adb("shell", "settings", "get", "global", "device_name").trim();
  await mac("open", { title: "Fay" });
  await mac("text", { near: FILE, text: `On ${phoneName}` });
  await mac("shot", { name: "on-phone" });
  await mac("press", { near: FILE, label: "Get" });
  const macBack = await until(async () => {
    const at = await macPath(fayInMac, id0);
    return at && (await fs.stat(at).catch(() => null)) && at;
  }, "the file back on the Mac");
  if (Buffer.compare(await fs.readFile(macBack), await fs.readFile(source)) !== 0) throw Error("not the same bytes");
  await mac("shot", { name: "back-from-phone" });
  check(`Mac: deleted, then "On ${phoneName}" · Get, clicked in the dropdown: back, the same bytes`);

  // Deleted on both: Get again asks Fay.
  async function deleteEverywhere() {
    const atPhone = await phonePath(id0);
    if (atPhone) phone.adb("shell", `run-as ${PACKAGE} rm -f "${atPhone}"`);
    const atMac = await macPath(fayInMac, id0);
    if (atMac) await fs.rm(atMac, { force: true });
    await phoneOpenChat(); // each computer looks at the chat again, and says it no longer holds the file
    await mac("open", { title: "Fay" });
    await phoneOpenChat();
    return until(async () => {
      const item = await phoneItem(id0);
      return item?.buttons.includes("Get again") && item.text.includes("Moved or deleted") && item;
    }, "Moved or deleted · Get again on the phone");
  }
  await deleteEverywhere();
  await shot("4-get-again");
  await tap(buttonIn(id0, "Get again"), "Get again");
  await until(async () => (await phoneItem(id0))?.buttons.includes("Share…"), "the file got again from Fay");
  if (!phoneHas(await phonePath(id0))) throw Error("the file got again is not there");
  check("deleted on both: Moved or deleted · Get again, tapped: Fay's computer gives it back");
  await shot("5-back-from-fay");

  // Fay edits the file she sent: she no longer has what she sent.
  await fs.writeFile(source, Buffer.from(Array.from({ length: 150_000 }, (_, i) => (i * 11) % 253)));
  await deleteEverywhere();
  await tap(buttonIn(id0, "Get again"), "Get again");
  const gone = await until(async () => {
    const item = await phoneItem(id0);
    return item?.text.includes("Fay doesn’t have this file anymore.") && item;
  }, "Fay doesn’t have this file anymore.");
  if (gone.buttons.length) throw Error(`the item still offers ${gone.buttons}`);
  await wait(3000);
  if (!(await phoneItem(id0))?.text.includes("Fay doesn’t have this file anymore.")) throw Error("it did not stay so");
  check('Fay changed the file: Get again ends with "Fay doesn’t have this file anymore." and nothing to press');
  await shot("6-gone");
} catch (error) {
  failed = true;
  console.error(String(error?.stack ?? error));
  await shot("failed").catch(() => {});
  console.error(`routes: ${(await fs.readdir(routes).catch(() => [])).join(" ")}`);
  const log = await mac("log", { mayFail: true }).catch(() => null);
  console.error(`the Mac helper's log:\n${String(log?.log ?? "").split("\n").slice(-40).join("\n")}`);
}
await mac("end", { mayFail: true }).catch(() => {});
await phone.cleanup?.();
fay.stdin.end();
bridge.stdin.end();
await wait(1500);
for (const child of children) if (child.exitCode === null) child.kill();
await fs.rm(work, { recursive: true, force: true }).catch(() => {});
console.log(failed ? "phones-get-again: FAILED" : `phones-get-again: passed (${checks.length} checks)`);
process.exit(failed ? 1 : 0);
