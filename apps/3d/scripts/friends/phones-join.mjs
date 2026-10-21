#!/usr/bin/env node
// phones-join.mjs — the owner's "I don't know how to import my profile from my Mac so we can share chats as well",
// with real taps: Shenzhen 3D's debug build with Friends on an Android emulator (the core in the app's process) and
// ShenzhenPDF's real Friends dropdown on the Mac (friends-ui-e2e's phone flow, offscreen, phones-mac.mjs) join one
// profile, and then share the friend, the chat and You.
//
//   node scripts/friends/phones-join.mjs --serial emulator-NNNN --tools <dir> --mac <dir> --manifest <file>
//        [--joins phone|mac] [--shots <dir>]
//
// --joins phone (the default, the owner's case): the Mac has a friend, Fay (the core's `loopback-peer`, made friends
// nearby), and a chat with her; the phone has its own ID and its own friend, Bo. On the phone: Settings ▸ Use my
// existing profile…, which asks first and says the phone's own ID and friends go; Delete and Continue; the join page
// opens by itself; the Mac's ID typed, Continue. On the Mac: Approve clicked in the dropdown, the code read from it.
// On the phone: the code typed, Join. --joins mac: the phone has Fay and the chat; in the Mac's dropdown, Use my
// existing profile…, the phone's ID, Continue; Approve tapped on the phone, its code typed in the dropdown, Join.
// Then, either way: Fay and the chat's history are on the new one; a message the new one sends Fay reaches her and
// shows on the other; her reply reaches both; and You carries a note each way. What the phone does and reads is
// taps and its page; what the Mac does is clicks and typing in its dropdown, except sending a message (its client
// protocol, as another app on the Mac would); what it shows is read from the dropdown.
//
// --tools, --mac and --manifest as for phones-get-again.mjs. Phone and Mac meet nearby on the core's loopback test
// network, bridged to the Mac helper's Bonjour test type.
import { execFileSync } from "node:child_process";
import fs from "node:fs/promises";
import { randomBytes } from "node:crypto";
import os from "node:os";
import path from "node:path";
import { android } from "./phones-exchange-android.mjs";
import { phoneUI, startBridge, startFriend, startMac, stopAll, until, wait } from "./phones-mac.mjs";

const argv = process.argv.slice(2);
const option = (name) => {
  const index = argv.indexOf(`--${name}`);
  return index >= 0 ? argv[index + 1] : undefined;
};
const [serial, tools, macDir, manifest, shots] = ["serial", "tools", "mac", "manifest", "shots"].map(option);
const joins = option("joins") ?? "phone";
if (!/^emulator-\d+$/.test(serial ?? "") || !tools || !macDir || !manifest || !["phone", "mac"].includes(joins)) {
  console.error("usage: phones-join.mjs --serial emulator-NNNN --tools <dir> --mac <dir> --manifest <file> " +
    "[--joins phone|mac] [--shots <dir>]");
  process.exit(64);
}
const checks = [];
const check = (line) => {
  checks.push(line);
  console.log(`ok ${line}`);
};

const work = await fs.mkdtemp(path.join(os.tmpdir(), "szf-join-"));
const [homePhone, homeFay, homeBo, routes] = ["phone", "fay", "bo", "routes"].map((n) => path.join(work, n));
await fs.mkdir(routes, { mode: 0o700 });
const serviceType = `_szfj${randomBytes(4).toString("hex")}._tcp`;
const befriend = (a, b, aName, bName) =>
  execFileSync(path.join(tools, "examples", "befriend"), [a, b, aName, bName], { encoding: "utf8" }).trim().split(/\s+/);
// The phone's own friend (joining the Mac replaces it), or Fay herself when the Mac joins the phone.
const [phoneFriendInPhone, phoneInPhoneFriend] = joins === "phone"
  ? befriend(homePhone, homeBo, "Ada", "Bo")
  : befriend(homePhone, homeFay, "Ada", "Fay");
if (joins === "phone") befriend(homeFay, path.join(work, "nobody"), "Fay", "Nobody"); // Fay's home, named

startBridge(tools, routes, serviceType);
const fay = startFriend(tools, homeFay, routes, "Fay");
const mac = await startMac({ macDir, manifest, shots, work, serviceType });
const phone = android(serial);
const { page, send: phoneSend, data: phoneData, tap, type } = phoneUI(phone);
const shot = async (name) => shots && (await wait(800), await phone.screenshot(path.join(shots, "phone", `${name}.png`)));

const inPanel = (body) => `(() => { const panel = document.querySelector(".szf-panel"); if (!panel) return null; ${body} })()`;
const button = (root, label) =>
  `[...((${root})?.querySelectorAll("button") ?? [])].find((b) => b.innerText.trim() === ${JSON.stringify(label)})`;
const panelButton = (label) => button(`document.querySelector(".szf-panel")`, label);
const rowTitled = (title) => inPanel(`return [...panel.querySelectorAll("[data-conversation-id]")].find((r) =>
  r.querySelector(".szf-row-title")?.innerText.trim().split("\\n")[0] === ${JSON.stringify(title)}) ?? null;`);
const panelSays = (text) => page(`return Boolean(document.querySelector(".szf-panel")?.innerText.includes(${
  JSON.stringify(text)}));`);
async function phoneOpenFriends() {
  if (!(await page(`return Boolean(document.querySelector(".szf-panel"));`)))
    await tap(`document.querySelector('[data-szfriends="button"]')`, "the Friends button");
  await until(() => page(`return Boolean(document.querySelector(".szf-panel"));`), "the panel");
}
async function phoneToList() {
  await phoneOpenFriends();
  while (await page(`return Boolean(document.querySelector(".szf-panel .szf-back"));`)) {
    await tap(`document.querySelector(".szf-panel .szf-back")`, "Back");
    await wait(400);
  }
}
async function phoneOpenChat(title) {
  await phoneToList();
  await tap(`${rowTitled(title)}?.querySelector(".szf-row-main")`, `${title}'s row`);
  await until(() => page(`return Boolean(document.querySelector(".szf-panel .szf-editor"));`), `${title}'s chat`);
}
async function phoneSendInChat(title, text) {
  await phoneOpenChat(title);
  await tap(`document.querySelector(".szf-panel .szf-editor")`, "the composer");
  type(text);
  await until(() => page(`return document.querySelector(".szf-panel .szf-editor")?.innerText.includes(${
    JSON.stringify(text)});`), "the typed message");
  await tap(panelButton("Send"), "Send");
}
const phoneSees = async (title, text, what) => {
  await phoneOpenChat(title);
  await until(() => panelSays(text), what, 60_000);
};
async function macSees(title, text, what) {
  await mac("open", { title });
  await mac("see", { text, seconds: 60 }).catch((error) => {
    throw Error(`${what}: ${error.message}`);
  });
}
const macSend = (conversation, text) => mac("intent", { type: "send_message", fields: {
  conversation_id: conversation, text, client_token: randomBytes(16).toString("hex") } });
async function macConversation(title) {
  return until(async () => (await mac("data", { view: "list" })).data?.rows?.find((r) => r.title === title)
    ?.conversation_id, `${title} on the Mac`);
}
async function fayChat(conversation) {
  const { subscription } = await fay.intent("open_conversation", { conversation_id: conversation });
  return subscription;
}
const fayTexts = (data) => (data?.items ?? []).map((i) => i.text).filter(Boolean);

let failed = false;
try {
  await fay.ready();
  await fay.intent("activate");
  await fay.intent("set_name", { name: "Fay" });
  await mac("intent", { type: "set_name", fields: { name: "Raph" } });
  await phone.install({ homePhone, routes, page: {}, work });
  await until(async () => (await page(`return (await window.shenzhenFriends.join()).state;`)) === "ready", "Friends");
  await phoneOpenFriends();
  await phoneSend("activate");

  let fayConversation; // Fay's conversation with the person
  if (joins === "phone") {
    // The Mac and Fay become friends nearby, and talk.
    await fay.intent("start_visibility");
    const found = await until(async () => (await mac("data", { view: "nearby" })).data?.people?.find(
      (p) => p.title === "Fay" && p.action?.action === "send_request"), "Fay nearby on the Mac");
    await mac("intent", { type: "send_request", fields: { nearby_id: found.nearby_id } });
    const { subscription: list } = await fay.intent("subscribe", { view: "list" });
    const asked = await fay.snapshot(list, "the Mac's request", (d) => d.rows?.some((r) => r.waiting?.kind === "request"));
    fayConversation = asked.rows.find((r) => r.waiting?.kind === "request").conversation_id;
    await fay.intent("accept_request", { conversation_id: fayConversation });
    await fay.intent("stop_visibility");
    const fayInMac = await macConversation("Fay");
    await macSend(fayInMac, "Before joining from the Mac");
    const chat = await fayChat(fayConversation);
    await fay.snapshot(chat, "the Mac's message", (d) => fayTexts(d).includes("Before joining from the Mac"));
    await fay.intent("send_message", { conversation_id: fayConversation, text: "Before joining from Fay",
      client_token: randomBytes(16).toString("hex") });
    await macSees("Fay", "Before joining from Fay", "Fay's message on the Mac");
    check("the Mac and Fay are friends, with a message each way");
    await until(() => page(`return Boolean(${rowTitled("Bo")});`), "Bo on the phone");

    // The phone: Settings ▸ Use my existing profile…, which says what goes.
    const macId = (await mac("data", { view: "profile" })).data.id.friends_id;
    await tap(`document.querySelector('button[title="Settings"]')`, "the Settings button");
    const settings = `document.querySelector('[data-szfriends="settings"]')`;
    await tap(button(settings, "Use my existing profile…"), "Use my existing profile… in Settings");
    const confirmBox = `document.querySelector('[data-szfriends="settings"] [role=alertdialog]')`;
    const dialog = await until(() => page(`const box = ${confirmBox};
      return box && { title: box.querySelector("strong").innerText, text: box.innerText };`), "the confirmation");
    if (dialog.title !== "Use your existing profile here?" || !dialog.text.includes("This device’s own ID"))
      throw Error(`the confirmation reads ${JSON.stringify(dialog)}`);
    check(`Settings ▸ Use my existing profile… asks first: "${dialog.title}", naming this device's own ID`);
    await shot("1-confirm");
    await tap(button(confirmBox, "Delete and Continue"), "Delete and Continue");
    await until(() => page(`return Boolean(document.querySelector(".szf-panel .szf-join input"));`),
      "the join page, opened by itself", 60_000);
    check("Delete and Continue resets the phone and opens the join page by itself");
    await shot("2-join-page");
    await tap(`document.querySelector('.szf-panel .szf-join input')`, "the Friends ID field");
    type(macId);
    await tap(panelButton("Continue"), "Continue");
    // The Mac: Approve in the dropdown, and the code it shows.
    await mac("list");
    await mac("see", { text: "wants to join your profile", seconds: 60 });
    await mac("shot", { name: "join-request" });
    await mac("click", { label: "Approve" });
    const code = (await mac("join_code")).code;
    await mac("shot", { name: "join-code" });
    check(`the Mac's dropdown shows the phone's request; Approve clicked; it shows the code ${code}`);
    await tap(`document.querySelector('.szf-panel .szf-join input[inputmode=numeric]')`, "the code field");
    type(code.replace(/\s/g, ""));
    await tap(panelButton("Join"), "Join");
    await until(() => panelSays("This device now uses your profile"), "joined", 60_000);
    check("the code typed on the phone: This device now uses your profile");
    await shot("3-joined");

    // What came with it.
    await phoneSees("Fay", "Before joining from Fay", "the chat's history on the phone");
    if (!(await panelSays("Before joining from the Mac"))) throw Error("the Mac's own message is missing");
    if (await page(`return Boolean(${rowTitled("Bo")});`)) throw Error("Bo is still listed");
    check("on the phone: Fay and the chat's history, both ways; the phone's own friend Bo is gone");
    await shot("4-history");
    await phoneSendInChat("Fay", "Hello from my phone");
    await fay.snapshot(await fayChat(fayConversation), "the phone's message at Fay",
      (d) => fayTexts(d).includes("Hello from my phone"), 60_000);
    await macSees("Fay", "Hello from my phone", "the phone's message on the Mac");
    check("the phone's message reaches Fay and shows in the Mac's dropdown");
    await fay.intent("send_message", { conversation_id: fayConversation, text: "Reply to all of you",
      client_token: randomBytes(16).toString("hex") });
    await phoneSees("Fay", "Reply to all of you", "Fay's reply on the phone");
    await macSees("Fay", "Reply to all of you", "Fay's reply on the Mac");
    check("Fay's reply reaches the phone and the Mac");
    await phoneSendInChat("You", "Note from my phone");
    await macSees("You", "Note from my phone", "the phone's note in You on the Mac");
    await macSend("you", "Note from my Mac");
    await phoneSees("You", "Note from my Mac", "the Mac's note in You on the phone");
    check("You: a note from the phone shows on the Mac, and one from the Mac on the phone");
    await shot("5-you");
  } else {
    // The phone holds the profile with Fay; they talk.
    fayConversation = phoneInPhoneFriend;
    await phoneSendInChat("Fay", "Before joining from the phone");
    await fay.snapshot(await fayChat(fayConversation), "the phone's message",
      (d) => fayTexts(d).includes("Before joining from the phone"), 60_000);
    await fay.intent("send_message", { conversation_id: fayConversation, text: "Before joining from Fay",
      client_token: randomBytes(16).toString("hex") });
    await phoneSees("Fay", "Before joining from Fay", "Fay's message on the phone");
    check("the phone and Fay are friends, with a message each way");
    const phoneId = (await phoneData("subscribe", { view: "profile" })).id.friends_id;

    // The Mac's dropdown: Use my existing profile…, the phone's ID, Continue.
    await mac("list");
    await mac("shot", { name: "offer" });
    await mac("click", { label: "Use my existing profile…" });
    await mac("fill", { placeholder: "Friends ID", text: phoneId });
    await mac("click", { label: "Continue" });
    await mac("see", { text: "Approve this computer" });
    check("in the Mac's dropdown: Use my existing profile…, the phone's ID, Continue");
    // The phone: Approve on the request, and its code.
    await phoneToList();
    const request = `document.querySelector(".szf-panel .szf-join-request")`;
    await until(() => page(`return Boolean(${request});`), "the Mac's request on the phone", 60_000);
    await shot("1-request");
    await tap(button(request, "Approve"), "Approve");
    const code = await until(() => page(`return document.querySelector(".szf-panel .szf-code")?.innerText.trim();`),
      "the code on the phone");
    await shot("2-code");
    check(`the phone shows the Mac's request; Approve tapped; it shows the code ${code}`);
    await mac("fill", { placeholder: "8-digit code", text: code.replace(/\s/g, "") });
    await mac("click", { label: "Join" });
    await mac("see", { text: "This computer now uses your profile", seconds: 60 });
    await mac("shot", { name: "joined" });
    check("the code typed in the Mac's dropdown: This computer now uses your profile");

    await macSees("Fay", "Before joining from Fay", "the chat's history on the Mac");
    await mac("see", { text: "Before joining from the phone" });
    await mac("shot", { name: "history" });
    check("on the Mac: Fay and the chat's history, both ways");
    const fayInMac = await macConversation("Fay");
    await macSend(fayInMac, "Hello from my Mac");
    await fay.snapshot(await fayChat(fayConversation), "the Mac's message at Fay",
      (d) => fayTexts(d).includes("Hello from my Mac"), 60_000);
    await phoneSees("Fay", "Hello from my Mac", "the Mac's message on the phone");
    check("the Mac's message reaches Fay and shows on the phone");
    await fay.intent("send_message", { conversation_id: fayConversation, text: "Reply to all of you",
      client_token: randomBytes(16).toString("hex") });
    await macSees("Fay", "Reply to all of you", "Fay's reply on the Mac");
    await phoneSees("Fay", "Reply to all of you", "Fay's reply on the phone");
    check("Fay's reply reaches the Mac and the phone");
    await macSend("you", "Note from my Mac");
    await phoneSees("You", "Note from my Mac", "the Mac's note in You on the phone");
    await phoneSendInChat("You", "Note from my phone");
    await macSees("You", "Note from my phone", "the phone's note in You on the Mac");
    check("You: a note from the Mac shows on the phone, and one from the phone on the Mac");
    await shot("3-you");
  }
} catch (error) {
  failed = true;
  console.error(String(error?.stack ?? error));
  await shot("failed").catch(() => {});
  const log = await mac("log", { mayFail: true }).catch(() => null);
  console.error(`the Mac helper's log:\n${String(log?.log ?? "").split("\n").slice(-40).join("\n")}`);
}
await mac("end", { mayFail: true }).catch(() => {});
await phone.cleanup?.();
fay.end();
await wait(1500);
stopAll();
await fs.rm(work, { recursive: true, force: true }).catch(() => {});
console.log(failed ? `phones-join (${joins} joins): FAILED` : `phones-join (${joins} joins): passed (${checks.length} checks)`);
process.exit(failed ? 1 : 0);
