#!/usr/bin/env node
// phones-exchange.mjs — Shenzhen 3D's phone build with Friends on (the core in the app's process) exchanges a message
// and a file each way with a Friends service on this Mac, over the test routes on loopback (docs/FRIENDS.md § Phones).
//
//   node scripts/friends/phones-exchange.mjs --platform android --serial emulator-5644 --tools <dir>
//   node scripts/friends/phones-exchange.mjs --platform ios --udid <simulator> --tools <dir>
//
// --tools names shenzhen-pdf's built examples (`cargo build -p szfriends-helper --example befriend --example
// loopback-peer` in portable/friends/core-rs: target/debug/examples). The two Friends homes are test homes made
// friends with `befriend`; the phone's is pushed into the debug app (Android: `run-as`, `files/friends-test.env`) or
// named in the simulator's environment (iOS, a `friends-smoke` build). Android reaches the Mac's routes through
// `adb reverse` and the Mac the phone's through `adb forward`; the simulator shares the Mac's loopback. The phone's
// side is scripts/friends/phones-exchange-page.js; screenshots of the panel go to --shots when given.
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
const platform = option("platform");
const tools = option("tools");
const shots = option("shots");
if (!["android", "ios"].includes(platform) || !tools) {
  console.error("usage: phones-exchange.mjs --platform android|ios [--serial s | --udid u] --tools <dir> [--shots d]");
  process.exit(64);
}
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../..");
const PACKAGE = "com.shenzhen3d.viewer";
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const checks = [];
const check = (line) => {
  checks.push(line);
  console.log(`ok ${line}`);
};
const work = await fs.mkdtemp(path.join(os.tmpdir(), "szf-phones-"));
const homePhone = path.join(work, "phone");
const homePeer = path.join(work, "peer");
const routes = path.join(work, "routes");
await fs.mkdir(routes, { mode: 0o700 });

const seeded = execFileSync(path.join(tools, "befriend"), [homePhone, homePeer, "Ada", "Bo"], { encoding: "utf8" });
const [boInPhone, adaInPeer] = seeded.trim().split(/\s+/);

// The Mac's side: the service for the peer's home, driven over its protocol.
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

async function until(probe, what, ms = 180_000) {
  const begun = Date.now();
  while (Date.now() - begun < ms) {
    const value = await probe();
    if (value) return value;
    await wait(200);
  }
  throw Error(`timed out waiting for ${what}`);
}

// The test network's entries, one per listener (`<name>.entry`, JSON with the port).
const entries = async (directory) =>
  (await fs.readdir(directory)).filter((name) => name.endsWith(".entry") && !name.startsWith("."));

const page = {
  conversation: boInPhone,
  peerName: "Bo",
  message: "Hello from the phone",
  reply: "Hi Ada, from the Mac",
  outgoingName: "phone-part.stl",
  outgoingText: "solid phone\n" + "facet normal 0 0 1\nendfacet\n".repeat(4000) + "endsolid phone\n",
  incomingName: "mac-bracket.step",
  recentName: "phone-recent.stl",
  recentText: "solid recent\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 10 0 0\nvertex 0 20 0\nendloop\nendfacet\nendsolid recent\n",
  report: platform === "ios" ? "smoke" : "return",
  // A smoke build quits when it reports: long enough for the screenshot first.
  holdMs: platform === "ios" ? 8000 : 0,
};
const incoming = path.join(work, page.incomingName);
const incomingText = "ISO-10303-21;\n" + "/* bracket */\n".repeat(20000) + "END-ISO-10303-21;\n";
await fs.writeFile(incoming, incomingText);

const peer = startPeer();
// As a person opening Friends would: the service looks for friends nearby, and so takes its route, only after this.
await peer.send("activate", {});
const macEntries = await until(async () => {
  const names = await entries(routes);
  return names.length ? names : null;
}, "the Mac's route");
let phone;
if (platform === "android") phone = (await import("./phones-exchange-android.mjs")).android(option("serial"));
else phone = (await import("./phones-exchange-ios.mjs")).ios(option("udid"));
await phone.install({ homePhone, routes, page, root, work });
check(`the phone app starts with Friends on (${platform})`);

let failed = false;
let peerItems = () => [];
// The page opens Friends as a person does; only then does the phone look for friends nearby and list its route.
const run = phone.run();
try {
  // The phone's route where the Mac finds it (Android: copied over and forwarded; iOS lists its own).
  await phone.route(macEntries);
  check("each side has the other's route");
  const conversation = await peer.view("open_conversation", { conversation_id: adaInPeer });
  const items = () => conversation()?.items ?? [];
  peerItems = items;
  await until(() => items().some((i) => i.kind === "message" && i.text === page.message), "the phone's message");
  check("the phone's message arrives on the Mac");
  const ok = (reply, what) => {
    if (reply.ok !== true) throw Error(`${what}: ${JSON.stringify(reply.error)}`);
  };
  const token = (n) => `phones-exchange-mac-${String(n).padStart(12, "0")}`;
  const reply = { conversation_id: adaInPeer, text: page.reply, client_token: token(1) };
  ok(await peer.send("send_message", reply), "reply");
  const files = [{ path: incoming }];
  ok(await peer.send("send_files", { conversation_id: adaInPeer, files, client_token: token(2) }), "send_files");
  const offer = await until(
    () => items().find((i) => i.kind === "transfer" && i.direction === "in" && i.file?.name === page.outgoingName),
    "the phone's staged file",
  );
  ok(await peer.send("accept_offer", { transfer_id: offer.transfer_id }), "accept_offer");
  const received = await until(
    () => items().find((i) => i.transfer_id === offer.transfer_id && i.state === "received"),
    "the phone's file received",
  );
  const file = received.actions?.find((a) => typeof a.path === "string")?.path;
  if (!file || (await fs.readFile(file, "utf8")) !== page.outgoingText) throw Error("the phone's file differs");
  check("the phone's staged file arrives whole on the Mac");
  await until(
    () => items().find((i) => i.direction === "out" && i.file?.name === page.incomingName && i.state === "delivered"),
    "the Mac's file delivered to the phone",
  );
  check("the Mac's file is delivered to the phone");
  // The recent file the phone attached with `#` and sent.
  const recent = await until(
    () => items().find((i) => i.kind === "transfer" && i.direction === "in" && i.file?.name === page.recentName),
    "the phone's recent file",
  );
  ok(await peer.send("accept_offer", { transfer_id: recent.transfer_id }), "accept_offer (recent)");
  const recentDone = await until(
    () => items().find((i) => i.transfer_id === recent.transfer_id && i.state === "received"),
    "the phone's recent file received",
  );
  const recentFile = recentDone.actions?.find((a) => typeof a.path === "string")?.path;
  if (!recentFile || (await fs.readFile(recentFile, "utf8")) !== page.recentText)
    throw Error("the phone's recent file differs");
  if (items().some((i) => i.kind === "message" && !i.text?.trim()))
    throw Error("an empty message came with the recent file");
  check("the recent file chosen with # arrives whole on the Mac");
  // The panel as the phone shows it now (an iOS smoke build quits once it has reported).
  await wait(3000);
  if (shots) await phone.screenshot(path.join(shots, `${platform}-conversation.png`));
  const result = await run;
  for (const line of result.lines) console.log(`phone: ${line}`);
  if (!result.ok) throw Error("the phone's checks failed");
  const copy = await phone.received(page.incomingName);
  if (copy !== incomingText) throw Error("the file the phone received differs");
  check("the Mac's file arrives whole in the phone's private Friends directory");
} catch (error) {
  failed = true;
  console.error(String(error?.stack ?? error));
  const summary = (i) => [i.kind, i.direction, i.text ?? i.file?.name, i.state ?? i.status?.state ?? ""].join(" ");
  for (const item of peerItems()) console.error(`mac item: ${summary(item)}`);
  const late = await Promise.race([run, wait(15_000)]);
  for (const line of late?.lines ?? []) console.log(`phone: ${line}`);
}
peer.close();
await phone.cleanup?.();
await peer.exited;
await fs.rm(work, { recursive: true, force: true }).catch(() => {});
console.log(failed ? "phones-exchange: FAILED" : `phones-exchange: passed (${checks.length} checks)`);
process.exit(failed ? 1 : 0);
