// phones-mac.mjs — the pieces a test of Shenzhen 3D on an Android emulator with the person's Mac is made of
// (docs/FRIENDS.md § Phones): the Mac (shenzhen-pdf's friends-ui-e2e `phone` flow: ShenzhenPDF's real Friends dropdown,
// offscreen, on a real Objective-C helper in a test home, driven one step at a time through two FIFOs), a friend (the
// core's `loopback-peer`), the bridge that joins the loopback test network's directory to the Mac helper's Bonjour
// test type (`szfriends-testnet dir`), and the phone's page and the emulator's own touch input.
//
// Used by phones-get-again.mjs and phones-join.mjs. Every child is stopped by stopAll().
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import readline from "node:readline";

export const PACKAGE = "com.shenzhen3d.viewer";
export const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
export async function until(probe, what, ms = 90_000) {
  const begun = Date.now();
  while (Date.now() - begun < ms) {
    const value = await probe().catch(() => null);
    if (value) return value;
    await wait(300);
  }
  throw Error(`timed out waiting for ${what}`);
}

const children = [];
const started = (child) => (children.push(child), child);

/** The bridge between the routes directory and the Mac helper's Bonjour test type. */
export function startBridge(tools, routes, serviceType) {
  return started(spawn(path.join(tools, "szfriends-testnet"), ["dir", routes, serviceType],
    { stdio: ["pipe", "inherit", "inherit"] }));
}

/** A friend: the core's loopback peer in `home`, one intent per line in, every frame out. */
export function startFriend(tools, home, routes, name) {
  const child = started(spawn(path.join(tools, "examples", "loopback-peer"), [home], {
    env: { ...process.env, SZFRIENDS_STATE_DIR: home, SZFRIENDS_TEST_LOOPBACK: routes },
    stdio: ["pipe", "pipe", "inherit"],
  }));
  const frames = [];
  readline.createInterface({ input: child.stdout }).on("line", (line) => {
    try {
      frames.push(JSON.parse(line));
    } catch {}
  });
  let next = 0;
  return {
    frames,
    ready: () => until(async () => frames.some((f) => f.type === "ready"), `${name}'s helper`),
    async intent(type, fields = {}) {
      const id = `p${++next}`;
      child.stdin.write(`${JSON.stringify({ type, ...fields })}\n`);
      const reply = await until(async () => frames.find((f) => f.type === "reply" && f.re === id), `${name}'s ${type}`);
      if (!reply.ok) throw Error(`${name}'s ${type}: ${JSON.stringify(reply)}`);
      return reply.result;
    },
    /** The newest snapshot of a subscription once `matches` holds. */
    snapshot: (subscription, what, matches = () => true, ms) =>
      until(async () => {
        const last = frames.findLast((f) => f.type === "snapshot" && f.subscription === subscription);
        return last && matches(last.data) && last.data;
      }, `${name}: ${what}`, ms),
    end: () => child.stdin.end(),
  };
}

/** The Mac: friends-ui-e2e's phone flow (SPDFMacFriendsUIPhoneFlows.mm lists its commands). */
export async function startMac({ macDir, manifest, shots, work, serviceType }) {
  const [macIn, macOut] = [path.join(work, "mac-in"), path.join(work, "mac-out")];
  execFileSync("mkfifo", [macIn, macOut]);
  started(spawn(path.join(macDir, "SPDFMacFriendsUIE2ETests"),
    [path.join(macDir, "szfriends-e2e-helper"), manifest, shots ? path.join(shots, "mac") : path.join(work, "mac-shots")],
    { env: { ...process.env, FRIENDS_UI_E2E_FLOWS: "phone", FRIENDS_UI_E2E_VARIANTS: "light-normal",
             FRIENDS_UI_E2E_PHONE_IN: macIn, FRIENDS_UI_E2E_PHONE_OUT: macOut, SZFRIENDS_E2E_SERVICE_TYPE: serviceType },
      stdio: ["ignore", "inherit", "inherit"] }));
  const answers = readline.createInterface({ input: (await fs.open(macOut, "r")).createReadStream() })[
    Symbol.asyncIterator]();
  const commands = await fs.open(macIn, "w");
  const ready = (await answers.next()).value;
  if (!JSON.parse(ready).ok) throw Error(`the Mac did not start: ${ready}`);
  async function mac(cmd, fields = {}) {
    await commands.write(`${JSON.stringify({ cmd, ...fields })}\n`);
    const answer = JSON.parse((await answers.next()).value);
    if (!answer.ok && !fields.mayFail) throw Error(`the Mac's ${cmd}: ${JSON.stringify(answer)}`);
    return answer;
  }
  return mac;
}

/** The phone's page through its DevTools socket, and taps where a person would put a finger. */
export function phoneUI(phone) {
  const page = (body) => phone.evaluate(`(async () => { ${body} })()`);
  const send = (type, fields = {}) =>
    page(`return await window.shenzhenFriends.send(${JSON.stringify(type)}, ${JSON.stringify(fields)});`);
  async function data(type, fields) {
    const { reply, snapshot } = await send(type, fields);
    if (reply?.result?.subscription) await send("unsubscribe", { subscription: reply.result.subscription });
    return snapshot?.data;
  }
  // Where the page is on the screen, from the system's view of the window (it shrinks while the keyboard shows).
  // uiautomator refuses now and then while the screen is still moving: then the last answer stands, or it is asked
  // again until one comes.
  let bounds = null;
  async function webviewBounds() {
    let fresh = null;
    for (let attempt = 0; !fresh && attempt < (bounds ? 1 : 10); attempt++) {
      try {
        phone.adb("shell", "uiautomator", "dump", "/data/local/tmp/szf-window.xml");
        const xml = phone.adb("shell", "cat", "/data/local/tmp/szf-window.xml");
        const node = xml.match(/class="android\.webkit\.WebView"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/);
        if (node) {
          const [, left, top, , bottom] = node.map(Number);
          fresh = { left, top, bottom };
        }
      } catch {}
      if (!fresh && !bounds) await wait(700);
    }
    bounds = fresh ?? bounds;
    if (!bounds) throw Error("no WebView on the screen");
    return bounds;
  }
  // The element's centre, scrolled into sight, in screen pixels.
  async function tap(expression, what) {
    const at = await until(() => page(`const e = ${expression}; if (!e) return null; e.scrollIntoView({block: "center"});
      const b = e.getBoundingClientRect(); return { x: b.x + b.width / 2, y: b.y + b.height / 2, height: innerHeight };`),
    what);
    const bounds = await webviewBounds();
    const scale = (bounds.bottom - bounds.top) / at.height;
    phone.adb("shell", "input", "tap", String(Math.round(bounds.left + at.x * scale)),
      String(Math.round(bounds.top + at.y * scale)));
  }
  /** Types as the keyboard does, into the field a tap focused (`input text`, spaces as %s). */
  const type = (text) => phone.adb("shell", "input", "text", text.replace(/ /g, "%s"));
  /** The app started again: its WebView may sit elsewhere. */
  const forget = () => (bounds = null);
  return { page, send, data, tap, type, forget };
}

export function stopAll() {
  for (const child of children) if (child.exitCode === null) child.kill();
}
