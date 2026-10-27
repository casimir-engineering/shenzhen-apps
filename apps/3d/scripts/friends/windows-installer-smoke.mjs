// windows-installer-smoke.mjs — runs inside Windows (windows-installer-smoke.sh copies it into the VM): Shenzhen 3D's
// NSIS Setup installed silently into a folder of the run's own, then the installed app as a person opens it, each run
// in a Friends home of its own (the app and its helper read %LOCALAPPDATA%, which the run points at its own folder,
// so the person's own Friends, settings and web data are never touched; the app's own log folder is the signed-in
// user's; the helper is the shipped one, so it checks in with the Friends host as any new install does):
//
//   fresh        the app opens, Ctrl+J opens Friends, and the panel is ready: the helper was copied, started and
//                answered (no "Starting Friends…" left on screen).
//   quarantined  the helper's per-user copy was removed and its folder left behind, as Microsoft Defender quarantines
//                a file: the app writes it again and Friends is ready all the same.
//   broken       the copy cannot be read at all: the panel says Friends didn't start and what to do, rather than
//                "Starting Friends…" without end, and the reason is in the app's friends.log.
//
// Then the app is uninstalled again. The page is driven through WebView2's remote debugging port: keys and reads, as
// a person's keyboard and eyes would. Screenshots of each panel are left in the run's folder.
//
//   node windows-installer-smoke.mjs --setup <Setup.exe> --work <empty folder>
import { spawn, spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const option = (name) => {
  const at = process.argv.indexOf(`--${name}`);
  if (at < 0 || !process.argv[at + 1]) throw Error(`--${name} is required`);
  return path.resolve(process.argv[at + 1]);
};
const setup = option("setup"),
  work = option("work");
const PORT = 9333;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
let failures = 0;
const ok = (what) => console.log(`ok ${what}`);
const notOk = (what) => {
  failures++;
  console.log(`not ok ${what}`);
};

const running = (image) =>
  spawnSync("tasklist", ["/fi", `imagename eq ${image}`, "/fo", "csv", "/nh"], { encoding: "utf8" })
    .stdout.split("\n")
    .filter((line) => line.startsWith(`"${image}"`))
    .map((line) => Number(line.split('","')[1]));

if (running("shenzhen-3d.exe").length) {
  console.log("not ok Shenzhen 3D is already open in this Windows: quit it first (it would take the run's launches)");
  process.exit(1);
}

// Where the installer puts the app by default is the last install's folder, which it remembers here and its
// uninstaller leaves: put back afterwards, so the person's next install goes where it went before this run.
const REMEMBERED = "HKCU\\Software\\shenzhen3d\\Shenzhen 3D";
const remembered = spawnSync("reg", ["query", REMEMBERED, "/ve"], { encoding: "utf8" })
  .stdout.match(/REG_SZ\s+(.+?)\s*$/m)?.[1];
const installed = path.join(work, "installed");
const install = spawnSync(setup, ["/S", `/D=${installed}`], {
  env: { ...process.env, LOCALAPPDATA: path.join(work, "installer-home") },
});
const app = path.join(installed, "shenzhen-3d.exe"),
  helper = path.join(installed, "szfriends-helper.exe");
if (install.status === 0 && fs.existsSync(app) && fs.existsSync(helper))
  ok("the Setup installs silently, the app and its helper side by side");
else {
  console.log(`not ok the Setup did not install (exit ${install.status})`);
  process.exit(1);
}
const version = spawnSync(helper, ["--version"], { encoding: "utf8" });
const stamp = version.stdout.match(/szfriends-helper (\S+) build (\d+)/);
if (version.status === 0 && stamp) ok(`the installed helper runs on this Windows: ${version.stdout.trim()}`);
else notOk(`the installed helper does not run (exit ${version.status}, ${version.error ?? version.stderr})`);

/** One page of the app over the remote debugging port: evaluate, press keys, take screenshots. */
async function page() {
  const begun = Date.now();
  for (;;) {
    try {
      const targets = await (await fetch(`http://127.0.0.1:${PORT}/json`)).json();
      const target = targets.find((t) => t.type === "page");
      if (target) {
        const socket = new WebSocket(target.webSocketDebuggerUrl);
        await new Promise((resolve, reject) => {
          socket.onopen = resolve;
          socket.onerror = reject;
        });
        let id = 0;
        const pending = new Map();
        socket.onmessage = (message) => {
          const data = JSON.parse(message.data);
          pending.get(data.id)?.(data);
        };
        const send = (method, params = {}) =>
          new Promise((resolve) => {
            pending.set(++id, resolve);
            socket.send(JSON.stringify({ id, method, params }));
          });
        return {
          async evaluate(expression) {
            const reply = await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
            return reply.result?.result?.value;
          },
          async key(key, code, modifiers = 0) {
            const event = { modifiers, windowsVirtualKeyCode: code, key, code: `Key${key.toUpperCase()}` };
            await send("Input.dispatchKeyEvent", { type: "rawKeyDown", ...event });
            await send("Input.dispatchKeyEvent", { type: "keyUp", ...event });
          },
          async screenshot(file) {
            const reply = await send("Page.captureScreenshot", { format: "png" });
            fs.writeFileSync(file, Buffer.from(reply.result.data, "base64"));
          },
          close: () => socket.close(),
        };
      }
    } catch {
      // Not listening yet.
    }
    if (Date.now() - begun > 60_000) throw Error("the app's page never came up");
    await sleep(250);
  }
}

/** What the Friends panel shows: open or not, its connection line, and whether the helper's words arrived. */
const PANEL = `(() => {
  const panel = document.querySelector('[data-szfriends="dropdown"]');
  return panel && {
    connection: panel.querySelector('.szf-connection')?.innerText ?? '',
    text: panel.innerText,
  };
})()`;

/** Opens the installed app in a Friends home of its own, opens Friends with Ctrl+J and waits for `settled`. */
async function scenario(name, prepare, settled, timeout) {
  const home = path.join(work, name);
  const local = path.join(home, "Local");
  fs.mkdirSync(local, { recursive: true });
  prepare?.(path.join(local, "Shenzhen Friends"));
  const child = spawn(app, [], {
    env: {
      ...process.env,
      LOCALAPPDATA: local,
      WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `--remote-debugging-port=${PORT}`,
    },
    detached: true,
    stdio: "ignore",
  });
  child.unref();
  let view;
  try {
    view = await page();
    const begun = Date.now();
    while (!(await view.evaluate("document.readyState === 'complete' && Boolean(window.shenzhenFriends)"))) {
      if (Date.now() - begun > 60_000) throw Error("the page never loaded Friends' bridge");
      await sleep(250);
    }
    await sleep(1500);
    await view.key("j", 0x4a, 2); // Ctrl+J
    let shown;
    const opened = Date.now();
    for (;;) {
      shown = await view.evaluate(PANEL);
      if (shown && settled(shown)) break;
      if (Date.now() - opened > timeout) break;
      await sleep(500);
    }
    await view.screenshot(path.join(work, `${name}.png`));
    return { shown, local, waited: Date.now() - opened };
  } finally {
    view?.close();
    // Closed as a person closes the window; the helper stays for other apps and leaves once idle.
    spawnSync("taskkill", ["/pid", String(child.pid)]);
    for (let i = 0; i < 80 && running("shenzhen-3d.exe").includes(child.pid); i++) await sleep(250);
    if (running("shenzhen-3d.exe").includes(child.pid)) spawnSync("taskkill", ["/f", "/pid", String(child.pid)]);
    await sleep(1000);
  }
}

const ready = (shown) => !shown.connection && /Add by ID/.test(shown.text);
const copyDir = (friends) => {
  const digest = crypto.createHash("sha256").update(fs.readFileSync(helper)).digest("hex").slice(0, 16);
  return path.join(friends, "helper", `${stamp?.[1]}-${stamp?.[2]}-${digest}`);
};

const startedAt = Date.now();
try {
  const fresh = await scenario("fresh", null, ready, 60_000);
  if (fresh.shown && ready(fresh.shown))
    ok(`fresh: Ctrl+J opens Friends and it is ready in ${(fresh.waited / 1000).toFixed(1)} s`);
  else notOk(`fresh: Friends is not ready: ${JSON.stringify(fresh.shown)}`);
  const log = path.join(fresh.local, "Shenzhen Friends", "helper.log");
  const served = fs.existsSync(log) && fs.readFileSync(log, "utf8").match(/serving build (\d+)/);
  if (served?.[1] === stamp?.[2]) ok(`fresh: the helper copied into the Friends home serves build ${served[1]}`);
  else notOk(`fresh: no helper served from the Friends home (${log})`);

  let removed;
  const quarantined = await scenario(
    "quarantined",
    (friends) => {
      removed = copyDir(friends);
      fs.mkdirSync(removed, { recursive: true });
    },
    ready,
    60_000,
  );
  if (quarantined.shown && ready(quarantined.shown) && fs.existsSync(path.join(removed, "szfriends-helper.exe")))
    ok("quarantined: the removed helper copy is written again and Friends is ready");
  else notOk(`quarantined: ${JSON.stringify(quarantined.shown)}`);

  const broken = await scenario(
    "broken",
    // A folder where the helper should be: the copy can never be read, so the helper never starts.
    (friends) => fs.mkdirSync(path.join(copyDir(friends), "szfriends-helper.exe"), { recursive: true }),
    (shown) => /didn't start/.test(shown.connection),
    60_000,
  );
  if (broken.shown && /Friends didn't start\. Quit Shenzhen 3D and open it again\./.test(broken.shown.connection))
    ok(`broken: after ${(broken.waited / 1000).toFixed(0)} s the panel says "${broken.shown.connection}"`);
  else notOk(`broken: the panel never said Friends didn't start: ${JSON.stringify(broken.shown)}`);
  // Tauri's log folder is the Local AppData known folder's, whatever %LOCALAPPDATA% says: the signed-in user's.
  const friendsLog = path.join(process.env.LOCALAPPDATA, "com.shenzhen3d.viewer", "logs", "friends.log");
  const since = Math.floor(startedAt / 1000) - 1;
  const reason = (fs.existsSync(friendsLog) ? fs.readFileSync(friendsLog, "utf8") : "")
    .split("\n")
    .find((line) => Number(line.split(" ")[0]) >= since && line.includes("Friends is unavailable"));
  if (reason) ok(`broken: the app's friends.log says why: ${reason}`);
  else notOk(`broken: no reason in ${friendsLog}`);
} catch (error) {
  notOk(String(error?.stack ?? error));
} finally {
  const uninstall = spawnSync(path.join(installed, "uninstall.exe"), ["/S"]);
  for (let i = 0; i < 40 && fs.existsSync(app); i++) await sleep(250);
  if (uninstall.status === 0 && !fs.existsSync(app)) ok("uninstalled again");
  else notOk("the uninstaller left the app behind");
  await sleep(3000);
  if (remembered) spawnSync("reg", ["add", REMEMBERED, "/ve", "/d", remembered, "/f"]);
  else spawnSync("reg", ["delete", REMEMBERED, "/f"]);
}
console.log(failures ? `windows-installer-smoke: FAILED (${failures})` : "windows-installer-smoke: passed");
process.exit(failures ? 1 : 0);
