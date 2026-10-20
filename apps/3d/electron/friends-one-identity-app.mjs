// friends-one-identity-check (apps/pdf/portable/friends/tests/e2e/oneid.mk): the app that plays Shenzhen 3D.
//
// Two modes.
//
//   node electron/friends-one-identity-app.mjs --make-app <dir>/Shenzhen 3D.app <helper executable> <build> [animals]
//     Builds a packaged Shenzhen 3D the way electron/package-mac.mjs lays one out, from this tree: a hidden copy of
//     Electron (hidden-electron.cjs) with the app in Contents/Resources/app (electron/, dist/, the client addon in
//     electron/native/), the animal set [animals] in Contents/Resources/Friends, and <helper executable> embedded as
//     Contents/Helpers/Shenzhen Friends.app saying <build>. Packaged, the shell offers Friends with no
//     SZFRIENDS_STATE_DIR: the addon's default Friends home (under $HOME) and the embedded helper, as shipped. The
//     only differences from a release: an ad hoc signature, LSBackgroundOnly, and a main that requires
//     hidden-hook.cjs and leaves out the updater (it would reach GitHub 20 s after launch).
//
//   node electron/friends-one-identity-app.mjs <helper executable> <helper version> <helper build number>
//     Runs that app hidden (no window, Dock icon, focus or dialog ever shows) through Playwright and
//     answers the runner on stdin and stdout with the lines of szfriends_e2e_appkit_app.m: protocol-level commands go
//     through the page's own bridge (window.shenzhenFriends), the ui_* ones through the real Friends panel. A command
//     about a conversation also names its row's `title`, since the panel opens conversations from their rows.
import { _electron as electron } from "@playwright/test";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const { hiddenElectronApp, anyWindowVisible } = require("./hidden-electron.cjs");

function helperInfoPlist(build) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.shenzhenfriends-e2e</string>
<key>CFBundleName</key><string>Shenzhen Friends</string>
<key>CFBundleExecutable</key><string>Shenzhen Friends</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>26.10.13</string>
<key>CFBundleVersion</key><string>${build}</string>
<key>SZFriendsBuildNumber</key><integer>${build}</integer>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
`;
}

// The shell's own main, hidden (hidden-hook.cjs) and without the updater: Playwright drives the app for minutes, and
// the packaged updater would ask GitHub for releases after 20 s.
const MAIN = `// Written by friends-one-identity-app.mjs: electron/main.cjs, hidden, with the updater left out.
require("./hidden-hook.cjs");
const Module = require("node:module");
const updater = require.resolve("./update-manager.cjs");
require.cache[updater] = Object.assign(new Module(updater), {
  filename: updater,
  loaded: true,
  exports: {
    createUpdateManager: () => new Proxy({}, { get: () => () => undefined }),
  },
});
require("./main.cjs");
`;

function makeApp(target, helperExecutable, build, animals) {
  const addon = path.join(root, "artifacts/friends-native", process.arch, "friends-link.node");
  for (const required of [addon, path.join(root, "dist/index.html"), helperExecutable])
    if (!fs.existsSync(required))
      throw Error(`${required} is missing: run scripts/friends/setup-friends.sh and npm run build first`);
  fs.rmSync(target, { recursive: true, force: true });
  return hiddenElectronApp(target, {
    executableName: "Shenzhen 3D",
    prepare(app) {
      const resources = path.join(app, "Contents/Resources");
      const appDir = path.join(resources, "app");
      fs.mkdirSync(appDir, { recursive: true });
      const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
      fs.writeFileSync(
        path.join(appDir, "package.json"),
        JSON.stringify({
          name: pkg.name,
          productName: "Shenzhen 3D",
          version: pkg.version,
          main: "electron/one-identity-main.cjs",
        }),
      );
      fs.cpSync(path.join(root, "electron"), path.join(appDir, "electron"), { recursive: true });
      fs.writeFileSync(path.join(appDir, "electron/one-identity-main.cjs"), MAIN);
      fs.mkdirSync(path.join(appDir, "electron/native"), { recursive: true });
      fs.copyFileSync(addon, path.join(appDir, "electron/native/friends-link.node"));
      execFileSync("cp", ["-cR", path.join(root, "dist"), path.join(appDir, "dist")]);
      if (animals && fs.existsSync(animals)) {
        fs.mkdirSync(path.join(resources, "Friends"), { recursive: true });
        fs.cpSync(animals, path.join(resources, "Friends/animals"), { recursive: true });
      }
      const helper = path.join(app, "Contents/Helpers/Shenzhen Friends.app/Contents");
      fs.mkdirSync(path.join(helper, "MacOS"), { recursive: true });
      fs.copyFileSync(helperExecutable, path.join(helper, "MacOS/Shenzhen Friends"));
      fs.chmodSync(path.join(helper, "MacOS/Shenzhen Friends"), 0o755);
      fs.writeFileSync(path.join(helper, "Info.plist"), helperInfoPlist(build));
    },
  });
}

if (process.argv[2] === "--make-app") {
  const [target, helperExecutable, build, animals] = process.argv.slice(3);
  console.log(makeApp(path.resolve(target), path.resolve(helperExecutable), Number(build), animals));
  process.exit(0);
}

// ---- The app ----------------------------------------------------------------------------------------------------

const [helperExecutable] = process.argv.slice(2);
const appPath = path.resolve(helperExecutable, "../../../../../..");
const emit = (event) => process.stdout.write(JSON.stringify(event) + "\n");
const log = (...parts) => console.error("[3d]", ...parts);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** The helper at the other end of one of `pid`'s Unix sockets, as lsof pairs them; 0 when none. */
function helperPeer(pid) {
  const sockets = (args) => {
    try {
      return execFileSync("/usr/sbin/lsof", ["-nP", "-U", "-F", "pcdn", ...args], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      });
    } catch (error) {
      return error.stdout ?? "";
    }
  };
  // f records: d = this socket's address, n = "->0x<peer>" when connected.
  const parse = (text) => {
    const entries = [];
    let process = 0,
      command = "",
      current;
    for (const line of text.split("\n")) {
      const tag = line[0],
        value = line.slice(1);
      if (tag === "p") process = Number(value);
      else if (tag === "c") command = value;
      else if (tag === "f") entries.push((current = { pid: process, command }));
      else if (tag === "d" && current) current.address = value;
      else if (tag === "n" && current) current.peer = value.startsWith("->") ? value.slice(2) : undefined;
    }
    return entries;
  };
  const mine = parse(sockets(["-a", "-p", String(pid)])).filter((entry) => entry.peer);
  if (!mine.length) return 0;
  // -a: lsof joins its selections with OR unless told otherwise.
  const helpers = parse(sockets(["-a", "-c", "Shenzhen Friend"])).filter((entry) => entry.pid !== pid);
  for (const socket of mine) {
    const peer = helpers.find(
      (entry) => entry.address === socket.peer || entry.peer === socket.address,
    );
    if (peer) return peer.pid;
  }
  return 0;
}

let application, page, strings;
let lastState = "";
const subscriptions = new Map(); // view name -> {view, fields}
const errors = [];

async function bridge(code, arg) {
  return page.evaluate(code, arg);
}

async function watchState() {
  for (;;) {
    let status;
    try {
      status = await bridge(() => window.shenzhenFriends.status());
    } catch {
      return; // the app went
    }
    const state = status?.state ?? "idle";
    if (state !== lastState) {
      lastState = state;
      if (state === "ready") {
        strings = status.strings;
        // Subscriptions do not survive a reconnect: subscribe again, as the panel does.
        for (const [name, wanted] of subscriptions) await subscribe(name, wanted.type, wanted.fields);
      }
      emit({
        event: "state",
        state,
        helper_pid: state === "ready" ? helperPeer(application.process().pid) : 0,
      });
    }
    await sleep(100);
  }
}

async function subscribe(name, type, fields) {
  subscriptions.set(name, { type, fields });
  const outcome = await bridge(
    async ({ name, type, fields }) => {
      const found = await window.shenzhenFriends.send(type, fields);
      const reply = found?.reply;
      if (!reply?.ok) return { ok: false, reply };
      window.__oneid.views.set(reply.result.subscription, name);
      if (found.snapshot) window.__oneid.snapshots.push({ view: name, data: found.snapshot.data });
      return { ok: true };
    },
    { name, type, fields },
  );
  if (!outcome.ok) log(`subscribe ${name} failed`, JSON.stringify(outcome.reply));
}

async function pumpSnapshots() {
  for (;;) {
    let snapshots;
    try {
      snapshots = await bridge(() => window.__oneid.snapshots.splice(0));
    } catch {
      return;
    }
    for (const { view, data } of snapshots) emit({ event: "snapshot", view, data });
    await sleep(50);
  }
}

const panel = () => page.locator('[data-szfriends="dropdown"]');

async function openPanel() {
  if (await panel().isVisible()) return;
  await page.locator('[data-szfriends="button"]').click();
  await panel().waitFor({ state: "visible", timeout: 10_000 });
}

async function showList() {
  await openPanel();
  for (let i = 0; i < 4 && !(await panel().locator(".szf-list-page").isVisible()); i++)
    await panel().locator(".szf-back").first().click();
  await panel().locator(".szf-list-page").waitFor({ state: "visible", timeout: 10_000 });
}

async function showConversation(title) {
  await openPanel();
  const header = panel().locator(".szf-conversation .szf-header-button strong");
  if ((await header.count()) && (await header.first().innerText()) === title) return;
  await showList();
  const row = panel()
    .locator(".szf-row")
    .filter({ has: page.locator(".szf-row-title", { hasText: new RegExp(`^${title}$`) }) });
  await row.first().locator(".szf-row-main").click();
  await header.first().waitFor({ state: "visible", timeout: 10_000 });
}

async function messageTexts() {
  await page.waitForTimeout(100);
  return panel().locator(".szf-message .szf-bubble").allInnerTexts();
}

async function run(command) {
  const { cmd, tag = "", title } = command;
  const reply = (ok, result = null, code = "") => emit({ event: "reply", tag, ok, result, code });
  try {
    if (cmd === "quit") {
      await application.close().catch(() => {});
      process.exit(0);
    } else if (cmd === "list" || cmd === "profile") {
      await subscribe(cmd, "subscribe", { view: cmd });
    } else if (cmd === "open") {
      await subscribe("conversation", "open_conversation", { conversation_id: command.conversation_id });
    } else if (cmd === "send" || cmd === "intent") {
      const type = cmd === "send" ? "send_message" : command.type;
      const fields =
        cmd === "send"
          ? { conversation_id: command.conversation_id, text: command.text, client_token: command.client_token }
          : (command.fields ?? {});
      const found = await bridge(({ type, fields }) => window.shenzhenFriends.send(type, fields), { type, fields });
      reply(Boolean(found?.reply?.ok), found?.reply?.result ?? null, found?.reply?.error?.code ?? "");
    } else if (cmd === "paths") {
      // Where the main process's client library (the addon) looks for Friends.
      const addon = path.join(appPath, "Contents/Resources/app/electron/native/friends-link.node");
      const paths = await application.evaluate((_, addon) => {
        const link = process.mainModule.require(addon);
        const stateDir = link.defaultStateDir();
        return { state_dir: stateDir, socket_path: link.socketPath(stateDir) };
      }, addon);
      reply(Boolean(paths?.state_dir), paths);
    } else if (cmd === "ui_type") {
      await showConversation(title);
      const editor = panel().locator(".szf-editor");
      await editor.click();
      await page.keyboard.type(command.text);
      await page.keyboard.press("Enter");
      await page.waitForFunction(
        () => (document.querySelector('[data-szfriends="dropdown"] .szf-editor')?.textContent ?? "x") === "",
        null,
        { timeout: 10_000 },
      );
      reply(true);
    } else if (cmd === "ui_texts") {
      await showConversation(title);
      reply(true, { texts: await messageTexts() });
    } else if (cmd === "ui_list") {
      await showList();
      reply(true, { texts: await panel().locator(".szf-list-page").allInnerTexts() });
    } else if (cmd === "ui_delete") {
      // Delete chat history from the conversation's details, as a person does it, confirmed in the panel's dialog.
      await showConversation(title);
      await panel().locator(".szf-conversation .szf-header-button").click();
      await panel().getByRole("button", { name: /Delete chat history/ }).first().click();
      const confirm = page.locator(".szf-confirm-box");
      await confirm.waitFor({ state: "visible", timeout: 10_000 });
      await confirm.locator(".szf-button.destructive").click();
      await confirm.waitFor({ state: "hidden", timeout: 10_000 });
      reply(true);
    }
  } catch (error) {
    log(`${cmd} failed:`, error.message);
    reply(false, null, "ui_error");
  }
}

try {
  application = await electron.launch({
    executablePath: path.join(appPath, "Contents/MacOS/Shenzhen 3D"),
    args: [`--user-data-dir=${path.join(process.env.HOME, "Library/Application Support/Shenzhen 3D")}`],
    env: process.env,
    timeout: 60_000,
  });
  page = await application.firstWindow();
  if (await anyWindowVisible(application)) throw Error("a window is visible: stopping before anything else shows");
  page.on("pageerror", (error) => errors.push(error.message));
  application.process().stderr?.on("data", (data) => process.stderr.write(data));
  await page.waitForFunction(() => Boolean(window.shenzhenFriends), null, { timeout: 30_000 });
  await bridge(() => {
    window.__oneid = { views: new Map(), snapshots: [] };
    window.shenzhenFriends.subscribe((event) => {
      if (event.kind !== "snapshot") return;
      const view = window.__oneid.views.get(event.frame.subscription);
      if (view) window.__oneid.snapshots.push({ view, data: event.frame.data });
    });
  });
} catch (error) {
  log("the app did not start:", error.message);
  await application?.close().catch(() => {});
  process.exit(1);
}
void watchState();
void pumpSnapshots();
const lines = readline.createInterface({ input: process.stdin });
let queue = Promise.resolve();
lines.on("line", (line) => {
  let command;
  try {
    command = JSON.parse(line);
  } catch {
    return;
  }
  queue = queue.then(() => run(command));
});
lines.on("close", () => {
  queue.then(async () => {
    await application.close().catch(() => {});
    process.exit(0);
  });
});
