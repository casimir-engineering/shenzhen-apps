#!/usr/bin/env node
// phones-notify-android.mjs — Friends' system notifications on Shenzhen 3D for Android, end to end on an emulator
// (ADR 0017 § Verification). A Friends service on this Mac, in a test home of its own (nothing shows on the Mac),
// sends the phone a message and a file; the phone's core posts them through the plugin's Kotlin half.
//
//   node scripts/friends/phones-notify-android.mjs --serial emulator-5680 --tools <dir>
//
// --tools names the core's built examples (`cargo build -p szfriends-helper --example befriend --example
// loopback-peer` in apps/pdf/portable/friends/core-rs: target/debug/examples). The debug APK must be installed.
// Emulators only: POST_NOTIFICATIONS and Bluetooth are granted with `pm grant`.
//
// Checks:
//   1. app in front, panel on the list: the friend's message is on the Messages channel with the friend's name and
//      the text; tapping it in the notification shade opens that conversation;
//   2. "Stay reachable in the background" on: the foreground service runs with its ongoing notification on its own
//      channel; the app goes Home and stays there past the grace period; a message still notifies and its tap brings
//      the app back on the conversation;
//   3. a file the friend offers is on the Files channel ("Bo wants to send you …");
//   4. Reply on a message notification, typed in the shade, reaches the friend.
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
const serial = option("serial");
const tools = option("tools");
if (!serial?.startsWith("emulator-") || !tools) {
  console.error("usage: phones-notify-android.mjs --serial emulator-NNNN --tools <dir>  (emulators only)");
  process.exit(64);
}
const PACKAGE = "com.shenzhen3d.viewer";
const GRACE_MS = 20_000;
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
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
    await wait(300);
  }
  throw Error(`timed out waiting for ${what}`);
}

const work = await fs.mkdtemp(path.join(os.tmpdir(), "szf-notify-"));
const homePhone = path.join(work, "phone");
const homePeer = path.join(work, "peer");
const routes = path.join(work, "routes");
await fs.mkdir(routes, { mode: 0o700 });
const seeded = execFileSync(path.join(tools, "befriend"), [homePhone, homePeer, "Ada", "Bo"], { encoding: "utf8" });
const [boInPhone, adaInPeer] = seeded.trim().split(/\s+/);

// The Mac's side: the peer's service in its test home, driven over its protocol.
const peer = (() => {
  const child = spawn(path.join(tools, "loopback-peer"), [homePeer], {
    env: { ...process.env, SZFRIENDS_STATE_DIR: homePeer, SZFRIENDS_TEST_LOOPBACK: routes },
    stdio: ["pipe", "pipe", "inherit"],
  });
  const replies = new Map();
  const views = new Map();
  let sent = 0;
  readline.createInterface({ input: child.stdout }).on("line", (line) => {
    const frame = JSON.parse(line);
    if (frame.type === "reply") replies.set(frame.re, frame);
    if (frame.type === "snapshot") views.set(frame.subscription, frame.data);
  });
  return {
    view: (subscription) => views.get(subscription),
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

const phone = (await import("./phones-exchange-android.mjs")).android(serial);
const { adb, evaluate } = phone;
const shell = (command) => adb("shell", command);

/** Our notifications as `dumpsys notification --noredact` lists them: key (tag), channel, title, text, flags. */
function notifications() {
  const dump = adb("shell", "dumpsys", "notification", "--noredact");
  const records = dump.split(/\n\s*NotificationRecord\(/).slice(1);
  return records
    .filter((record) => record.includes(`pkg=${PACKAGE}`))
    .map((record) => {
      const field = (pattern) => (record.match(pattern) ?? [])[1] ?? "";
      return {
        tag: field(/tag=([^\s:]+:[^\s]+|[^\s]+)/),
        channel: field(/channel=([^\s]+)/) || field(/mChannelId=([^\s,]+)/),
        title: field(/android\.title=String \((.*)\)/),
        text: field(/android\.text=String \((.*)\)/),
        ongoing: /flags=0x[0-9a-f]*[2-7a-f][0-9a-f]\b/i.test(field(/(flags=0x[0-9a-f]+)/)) || /FOREGROUND_SERVICE/.test(record),
        record,
      };
    });
}

const posted = (channel, title, text) =>
  until(
    () => notifications().find((n) => n.channel === channel && n.title === title && n.text === text),
    `"${title}: ${text}" on ${channel}`,
    90_000,
  );

/** The screen's nodes (uiautomator), to tap a notification in the shade as a person does. */
function screen() {
  try {
    shell("uiautomator dump /data/local/tmp/szfn-ui.xml >/dev/null");
    const xml = shell("cat /data/local/tmp/szfn-ui.xml");
    return [...xml.matchAll(/<node [^>]*>/g)].map(([node]) => {
      const value = (name) => (node.match(new RegExp(`${name}="([^"]*)"`)) ?? [])[1] ?? "";
      const b = value("bounds").match(/\d+/g)?.map(Number) ?? [0, 0, 0, 0];
      return { text: value("text") || value("content-desc"), pkg: value("package"), x: (b[0] + b[2]) >> 1, y: (b[1] + b[3]) >> 1 };
    });
  } catch {
    return [];
  }
}

async function tapInShade(text) {
  shell("cmd statusbar expand-notifications");
  const node = await until(
    () => screen().find((n) => n.pkg === "com.android.systemui" && n.text === text),
    `"${text}" in the notification shade`,
    20_000,
  );
  shell(`input tap ${node.x} ${node.y}`);
}

/** What the page shows: the panel's open conversation, by the friend's name in its header. */
const conversationShown = (name) =>
  evaluate(`(() => {
    const panel = document.querySelector(".szf-panel");
    return !!panel && !!panel.querySelector(".szf-editor") && panel.innerText.includes(${JSON.stringify(name)});
  })()`).catch(() => false);

const inFront = () => /mCurrentFocus=.*com\.shenzhen3d\.viewer/.test(shell("dumpsys window displays"));

let failed = false;
try {
  for (const permission of [
    "POST_NOTIFICATIONS",
    "BLUETOOTH_SCAN",
    "BLUETOOTH_ADVERTISE",
    "BLUETOOTH_CONNECT",
  ]) {
    adb("shell", "pm", "grant", PACKAGE, `android.permission.${permission}`);
  }
  shell(`cmd notification cancel_all ${PACKAGE} 2>/dev/null; true`);
  await peer.send("activate", {});
  await until(async () => (await fs.readdir(routes)).some((n) => n.endsWith(".entry")), "the Mac's route");
  await phone.install({ homePhone, routes, page: {}, work });
  // Open Friends as a person does: the phone looks for friends nearby and takes its route; the list shows.
  await evaluate(`(async () => {
    const until = async (probe) => { for (let i = 0; i < 400; i++) { const v = await probe(); if (v) return v;
      await new Promise((r) => setTimeout(r, 250)); } throw Error("timed out"); };
    await until(async () => (await window.shenzhenFriends.join()).state === "ready");
    (await until(() => document.querySelector('[data-szfriends="button"]'))).click();
    await until(() => document.querySelector(".szf-panel"));
    return true;
  })()`);
  await phone.route();
  check("the phone runs Friends with its panel on the list and has a route to the Mac");

  // 1. In front, not looking at the conversation.
  const first = "Are you free to look at the bracket?";
  await peer.send("send_message", { conversation_id: adaInPeer, text: first, client_token: `notify-a-${Date.now()}` });
  const message = await posted("friends.messages", "Bo", first);
  if (!message.tag.startsWith("message:")) throw Error(`unexpected key ${message.tag}`);
  check(`the message is on the Messages channel, titled Bo, with its text (key ${message.tag})`);
  await tapInShade(first);
  await until(() => conversationShown("Bo"), "Bo's conversation after the tap", 30_000);
  check("tapping it opens Bo's conversation");

  // 2. Reachable in the background, the app at Home past the grace period.
  const switched = await evaluate(
    `window.shenzhenFriends.send("set_notifications", { background: true }).then((r) => r.reply)`,
  );
  if (switched?.ok !== true) throw Error(`set_notifications: ${JSON.stringify(switched)}`);
  const ongoing = await until(
    () => notifications().find((n) => n.channel === "friends.background"),
    "the ongoing notification",
    20_000,
  );
  if (ongoing.title !== "Friends is reachable") throw Error(`the ongoing notification reads ${ongoing.title}`);
  if (!/isForeground=true/.test(shell(`dumpsys activity services ${PACKAGE}`)))
    throw Error("the reachable service is not in the foreground");
  check(`the switch starts the foreground service with "${ongoing.title}" on its own channel`);
  // Away from the conversation, then Home.
  await evaluate(`document.querySelector('[data-szfriends="button"]')?.click(), true`);
  shell("input keyevent KEYCODE_HOME");
  await until(() => !inFront(), "the app in the background", 10_000);
  await wait(GRACE_MS + 8_000);
  const second = "Still there? Sent while the app is closed";
  await peer.send("send_message", { conversation_id: adaInPeer, text: second, client_token: `notify-b-${Date.now()}` });
  await posted("friends.messages", "Bo", second);
  check("past the grace period at Home, a message still notifies on the Messages channel");
  await tapInShade(second);
  await until(inFront, "the app back in front", 20_000);
  await phone.reattach();
  await until(() => conversationShown("Bo"), "Bo's conversation after the tap from Home", 30_000);
  check("tapping it brings the app back on Bo's conversation");

  // 3. A file the friend offers.
  await evaluate(`document.querySelector('[data-szfriends="button"]')?.click(), true`);
  const name = "notify-bracket.step";
  const file = path.join(work, name);
  await fs.writeFile(file, "ISO-10303-21;\nEND-ISO-10303-21;\n");
  await peer.send("send_files", {
    conversation_id: adaInPeer,
    files: [{ path: file }],
    client_token: `notify-c-${Date.now()}`,
  });
  const offer = await until(
    () => notifications().find((n) => n.channel === "friends.files" && n.title === "Bo" && n.text.includes(name)),
    "the file's notification",
    90_000,
  );
  check(`the file is on the Files channel: "${offer.text}"`);

  await evaluate(`window.shenzhenFriends.send("set_notifications", { background: false }).then((r) => r.reply)`);
  await until(() => !notifications().some((n) => n.channel === "friends.background"), "the service stopped", 20_000);
  check("switching it off stops the service and its notification");

  // 4. Reply from the shade.
  const view = await peer.send("open_conversation", { conversation_id: adaInPeer });
  const items = () => peer.view(view.result?.subscription)?.items ?? [];
  const third = "Can you reply from the notification?";
  await peer.send("send_message", { conversation_id: adaInPeer, text: third, client_token: `notify-d-${Date.now()}` });
  await posted("friends.messages", "Bo", third);
  shell("cmd statusbar expand-notifications");
  const replyButton = await until(
    () => screen().find((n) => n.pkg === "com.android.systemui" && /^reply$/i.test(n.text)),
    "Reply on the notification",
    20_000,
  );
  shell(`input tap ${replyButton.x} ${replyButton.y}`);
  await wait(1_500);
  const answer = "Replying from the shade";
  shell(`input text '${answer.replaceAll(" ", "%s")}'`);
  await wait(500);
  const send = await until(
    () => screen().find((n) => n.pkg === "com.android.systemui" && /^send$/i.test(n.text)),
    "the reply's Send",
    5_000,
  ).catch(() => null);
  if (send) shell(`input tap ${send.x} ${send.y}`);
  else shell("input keyevent KEYCODE_ENTER");
  await until(
    () => items().some((i) => i.kind === "message" && i.direction === "in" && i.text === answer),
    "the reply on the Mac",
    60_000,
  );
  check("Reply typed in the notification shade reaches the friend");
} catch (error) {
  failed = true;
  console.error(String(error?.stack ?? error));
  for (const n of notifications()) console.error(`notification: ${n.tag} ${n.channel} ${n.title}: ${n.text}`);
}
shell("cmd statusbar collapse");
peer.close();
await phone.cleanup();
await peer.exited;
await fs.rm(work, { recursive: true, force: true }).catch(() => {});
console.log(failed ? "phones-notify-android: FAILED" : `phones-notify-android: passed (${checks.length} checks)`);
process.exit(failed ? 1 : 0);
