// windows-installer-smoke.mjs — runs inside Windows (windows-installer-smoke.sh copies it into the VM): Shenzhen 3D's
// NSIS Setup installed silently into a folder of the run's own, then the installed app as a person opens it, in
// Friends homes the run chooses (the app and its helper read %LOCALAPPDATA%, which the run points at its own folder,
// so the person's own Friends, settings and web data are never touched; the app's own log folder is the signed-in
// user's; the helper is the shipped one, so it checks in with the Friends host as any install does). With --home, the
// scenarios that reach the host reuse that kept home, whose Friends ID already exists, instead of making new ones (the
// host lets one address make only a few new IDs a day).
//
//   fresh        the app opens, Ctrl+J opens Friends, and the panel is ready: the helper was copied, started and
//                answered (no "Starting Friends…" left on screen).
//   quarantined  the helper's per-user copy was removed and its folder left behind, as Microsoft Defender quarantines
//                a file: the app writes it again and Friends is ready all the same.
//   broken       the copy cannot be read at all: the panel says Friends didn't start and what to do, rather than
//                "Starting Friends…" without end, and the reason is in the app's friends.log.
//   lingering    the app is closed while its helper stays (as it does for a while), and opened again at once: the new
//                app reaches that helper and Friends is ready.
//   wedged       the same, but the lingering helper no longer answers (its threads suspended, as a helper that hung):
//                the app ends it, starts a new one and Friends is ready, instead of loading without end.
//   declined     Windows Firewall has no rule for Friends (the installer's request was declined): Nearby says people
//                on this network can't find this PC, offers Allow on Private Networks, and the friends already added
//                still show (they connect over the internet).
//   public       Friends' rule is there, the network is Public: Nearby says how to make the network Private.
//   allowed      Friends' rule is there, the network is Private: no firewall line, and the helper listens on one of
//                Friends' ports.
//   blocked      a Block rule covers Friends' ports: Nearby says a firewall rule blocks Friends.
//   bounds       the window is opened and closed five times and keeps the same position and size each time, never
//                smaller than its minimum size; a window that earlier versions saved a few pixels tall (they lost the
//                menu bar's height on every launch) opens at a usable size again. The signed-in user's saved window
//                bounds are put back afterwards.
//
// The firewall scenarios need the firewall and the network set first, which takes an administrator:
// windows-installer-smoke.sh sets them between runs of this script (--scenarios, --installed, --keep, --uninstall).
// The page is driven through WebView2's remote debugging port: keys and reads, as a person's keyboard and eyes would.
// Screenshots of each panel are left in the run's folder.
//
//   node windows-installer-smoke.mjs --setup <Setup.exe> --work <empty folder> [--home <kept LOCALAPPDATA>]
//        [--scenarios fresh,quarantined,…] [--installed <folder of an earlier run>] [--keep] [--uninstall]
import { spawn, spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const value = (name) => {
  const at = process.argv.indexOf(`--${name}`);
  return at < 0 ? undefined : process.argv[at + 1];
};
const flag = (name) => process.argv.includes(`--${name}`);
const option = (name) => {
  const given = value(name);
  if (!given) throw Error(`--${name} is required`);
  return path.resolve(given);
};
const work = option("work");
const keptHome = value("home") && path.resolve(value("home"));
const ALL = ["fresh", "quarantined", "broken", "lingering", "wedged", "bounds"];
const scenarios = (value("scenarios") ?? ALL.join(",")).split(",").filter(Boolean);
const PORT = 9333;
const FRIENDS_PORTS = [48250, 48257];
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
const installed = value("installed") ? path.resolve(value("installed")) : path.join(work, "installed");
const app = path.join(installed, "shenzhen-3d.exe"),
  helper = path.join(installed, "szfriends-helper.exe");
const rememberedFile = path.join(installed, "..", "remembered-install-folder.txt");

function uninstall() {
  const remembered = fs.existsSync(rememberedFile) ? fs.readFileSync(rememberedFile, "utf8") : "";
  const result = spawnSync(path.join(installed, "uninstall.exe"), ["/S"]);
  return (async () => {
    for (let i = 0; i < 40 && fs.existsSync(app); i++) await sleep(250);
    if (result.status === 0 && !fs.existsSync(app)) ok("uninstalled again");
    else notOk("the uninstaller left the app behind");
    await sleep(3000);
    if (remembered) spawnSync("reg", ["add", REMEMBERED, "/ve", "/d", remembered, "/f"]);
    else spawnSync("reg", ["delete", REMEMBERED, "/f"]);
  })();
}

if (flag("uninstall")) {
  await uninstall();
  console.log(failures ? `windows-installer-smoke: FAILED (${failures})` : "windows-installer-smoke: passed");
  process.exit(failures ? 1 : 0);
}

if (!value("installed")) {
  const setup = option("setup");
  const remembered = spawnSync("reg", ["query", REMEMBERED, "/ve"], { encoding: "utf8" }).stdout.match(
    /REG_SZ\s+(.+?)\s*$/m,
  )?.[1];
  fs.mkdirSync(work, { recursive: true });
  fs.writeFileSync(rememberedFile, remembered ?? "");
  const install = spawnSync(setup, ["/S", `/D=${installed}`], {
    env: { ...process.env, LOCALAPPDATA: path.join(work, "installer-home") },
  });
  if (install.status === 0 && fs.existsSync(app) && fs.existsSync(helper))
    ok("the Setup installs silently, the app and its helper side by side");
  else {
    console.log(`not ok the Setup did not install (exit ${install.status})`);
    process.exit(1);
  }
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
        // The page laid out at the app's default size, whatever size the window was last left at.
        await send("Emulation.setDeviceMetricsOverride", { width: 1440, height: 960, deviceScaleFactor: 1, mobile: false });
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
          async click(x, y) {
            for (const type of ["mouseMoved", "mousePressed", "mouseReleased"])
              await send("Input.dispatchMouseEvent", { type, x, y, button: "left", clickCount: 1 });
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
    note: panel.querySelector('.szf-nearby .szf-quiet-line')?.innerText ?? '',
    rows: panel.querySelectorAll('[data-conversation-id]').length,
  };
})()`;
/** Where a tab or button with exactly this text is, for a click as a person makes it. */
const at = (text) => `(() => {
  const e = [...document.querySelectorAll('[data-szfriends="dropdown"] button, [data-szfriends="dropdown"] [role=tab]')]
    .find((e) => e.innerText.trim() === ${JSON.stringify(text)} && e.getClientRects().length);
  if (!e) return null;
  const r = e.getBoundingClientRect();
  return [r.x + r.width / 2, r.y + r.height / 2];
})()`;

const ready = (shown) => !shown.connection && /Add by ID/.test(shown.text);

/** The Friends home a scenario runs in: the kept one when it reaches the host and --home was given. */
function homeFor(name, reachesHost) {
  if (reachesHost && keptHome) return keptHome;
  const local = path.join(work, name, "Local");
  fs.mkdirSync(local, { recursive: true });
  return local;
}

/** Opens the installed app in `local`, opens Friends with Ctrl+J, then runs `look` (default: until `settled`). */
async function open(name, local, { prepare, settled = ready, timeout = 60_000, then, close = "close" } = {}) {
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
    const waited = Date.now() - opened;
    const extra = then ? await then(view, shown) : undefined;
    await view.screenshot(path.join(work, `${name}.png`));
    return { shown: extra?.shown ?? shown, local, waited, extra };
  } finally {
    view?.close();
    if (close) {
      // Closed as a person closes the window; the helper stays for other apps and leaves once idle.
      spawnSync("taskkill", ["/pid", String(child.pid)]);
      for (let i = 0; i < 80 && running("shenzhen-3d.exe").includes(child.pid); i++) await sleep(250);
      if (running("shenzhen-3d.exe").includes(child.pid)) spawnSync("taskkill", ["/f", "/pid", String(child.pid)]);
      await sleep(1000);
    }
  }
}

/** The app's top-level window as Windows has it, in physical pixels: through a small C# tool built with csc. */
function windowOf(pid) {
  const tool = path.join(work, "bounds.exe");
  if (!fs.existsSync(tool)) {
    const source = path.join(work, "bounds.cs");
    fs.writeFileSync(
      source,
      `using System; using System.Runtime.InteropServices;
class Bounds { [StructLayout(LayoutKind.Sequential)] struct R { public int L, T, Ri, B; }
  delegate bool F(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumWindows(F f, IntPtr p);
  [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out R r);
  [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out R r);
  [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  static int Main(string[] a) { SetProcessDpiAwarenessContext(new IntPtr(-4)); int want = int.Parse(a[0]); int found = 1;
    EnumWindows((h, p) => { int pid; GetWindowThreadProcessId(h, out pid); if (pid != want || !IsWindowVisible(h)) return true;
      R w, c; GetWindowRect(h, out w); GetClientRect(h, out c); if (c.Ri < 50 && c.B < 50 && w.Ri - w.L < 200) return true;
      Console.WriteLine("{\\"x\\":" + w.L + ",\\"y\\":" + w.T + ",\\"width\\":" + (w.Ri - w.L) + ",\\"height\\":" + (w.B - w.T) +
        ",\\"content\\":[" + c.Ri + "," + c.B + "],\\"dpi\\":" + GetDpiForWindow(h) + ",\\"minimized\\":" + (IsIconic(h) ? "true" : "false") + "}");
      found = 0; return false; }, IntPtr.Zero); return found; } }`,
    );
    const csc = path.join(process.env.WINDIR, "Microsoft.NET", "Framework64", "v4.0.30319", "csc.exe");
    spawnSync(csc, ["/nologo", `/out:${tool}`, source]);
  }
  const shown = spawnSync(tool, [String(pid)], { encoding: "utf8" });
  return shown.status === 0 ? JSON.parse(shown.stdout) : undefined;
}

/** Opens the installed app in `local`, waits for its window to settle, measures it and closes it as a person does. */
async function measure(local) {
  const child = spawn(app, [], { env: { ...process.env, LOCALAPPDATA: local }, detached: true, stdio: "ignore" });
  child.unref();
  let shown;
  for (let i = 0; i < 120 && !shown; i++) {
    await sleep(250);
    shown = windowOf(child.pid);
  }
  await sleep(3000); // the page loads; nothing may move the window meanwhile
  shown = windowOf(child.pid) ?? shown;
  spawnSync("taskkill", ["/pid", String(child.pid)]);
  for (let i = 0; i < 80 && running("shenzhen-3d.exe").includes(child.pid); i++) await sleep(250);
  if (running("shenzhen-3d.exe").includes(child.pid)) spawnSync("taskkill", ["/f", "/pid", String(child.pid)]);
  await sleep(500);
  return shown;
}

/** The process holding a Friends home's helper lock. */
const lockHolder = (local) => {
  const lock = path.join(local, "Shenzhen Friends", "ipc", "helper.lock");
  return fs.existsSync(lock) ? Number(fs.readFileSync(lock, "utf8").match(/\d+/)?.[0]) : undefined;
};

/** Suspends or resumes every thread of a process, through a small C# tool built with the .NET Framework's csc. */
function freeze(pid, resume = false) {
  const tool = path.join(work, "freeze.exe");
  if (!fs.existsSync(tool)) {
    const source = path.join(work, "freeze.cs");
    fs.writeFileSync(
      source,
      `using System; using System.Diagnostics; using System.Runtime.InteropServices;
class Freeze { [DllImport("ntdll.dll")] static extern int NtSuspendProcess(IntPtr h);
  [DllImport("ntdll.dll")] static extern int NtResumeProcess(IntPtr h);
  static int Main(string[] a) { var p = Process.GetProcessById(int.Parse(a[1]));
    return a[0] == "suspend" ? NtSuspendProcess(p.Handle) : NtResumeProcess(p.Handle); } }`,
    );
    const csc = path.join(process.env.WINDIR, "Microsoft.NET", "Framework64", "v4.0.30319", "csc.exe");
    spawnSync(csc, ["/nologo", `/out:${tool}`, source]);
  }
  return spawnSync(tool, [resume ? "resume" : "suspend", String(pid)]).status === 0;
}

/** Opens the Nearby tab of an open panel, waits for its firewall line to settle, and returns what it shows. */
const nearby = (expected) => async (view) => {
  const spot = await view.evaluate(at("Nearby"));
  if (spot) await view.click(...spot);
  let shown;
  for (let i = 0; i < 30; i++) {
    shown = await view.evaluate(PANEL);
    if (expected(shown)) break;
    await sleep(500);
  }
  return { shown };
};

const listening = (pid) =>
  spawnSync("netstat", ["-ano", "-p", "tcp"], { encoding: "utf8" })
    .stdout.split("\n")
    .filter((line) => /LISTENING/.test(line) && line.trim().endsWith(` ${pid}`))
    .map((line) => Number(line.trim().split(/\s+/)[1].split(":").pop()));

const copyDir = (friends) => {
  const digest = crypto.createHash("sha256").update(fs.readFileSync(helper)).digest("hex").slice(0, 16);
  return path.join(friends, "helper", `${stamp?.[1]}-${stamp?.[2]}-${digest}`);
};

const startedAt = Date.now();
try {
  for (const name of scenarios) {
    if (name === "fresh") {
      const fresh = await open("fresh", homeFor("fresh", true));
      if (fresh.shown && ready(fresh.shown))
        ok(`fresh: Ctrl+J opens Friends and it is ready in ${(fresh.waited / 1000).toFixed(1)} s`);
      else notOk(`fresh: Friends is not ready: ${JSON.stringify(fresh.shown)}`);
      const log = path.join(fresh.local, "Shenzhen Friends", "helper.log");
      const served = fs.existsSync(log) && [...fs.readFileSync(log, "utf8").matchAll(/serving build (\d+)/g)].pop();
      if (served?.[1] === stamp?.[2]) ok(`fresh: the helper copied into the Friends home serves build ${served[1]}`);
      else notOk(`fresh: no helper of this build served from the Friends home (${log})`);
    } else if (name === "quarantined") {
      let removed;
      const local = homeFor("quarantined", true);
      // The kept home's helper may still run from the last scenario: a copy in use cannot be removed.
      for (let i = 0; i < 120 && lockHolder(local) && running("szfriends-helper.exe").includes(lockHolder(local)); i++)
        await sleep(500);
      const quarantined = await open("quarantined", local, {
        prepare: (friends) => {
          removed = copyDir(friends);
          // As a quarantine removes it (the copy is written read-only).
          const copy = path.join(removed, "szfriends-helper.exe");
          if (fs.existsSync(copy)) fs.chmodSync(copy, 0o666);
          fs.rmSync(copy, { force: true });
          fs.mkdirSync(removed, { recursive: true });
        },
      });
      if (quarantined.shown && ready(quarantined.shown) && fs.existsSync(path.join(removed, "szfriends-helper.exe")))
        ok("quarantined: the removed helper copy is written again and Friends is ready");
      else notOk(`quarantined: ${JSON.stringify(quarantined.shown)}`);
    } else if (name === "broken") {
      const broken = await open("broken", homeFor("broken", false), {
        // A folder where the helper should be: the copy can never be read, so the helper never starts.
        prepare: (friends) => fs.mkdirSync(path.join(copyDir(friends), "szfriends-helper.exe"), { recursive: true }),
        settled: (shown) => /didn't start/.test(shown.connection),
      });
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
    } else if (name === "lingering" || name === "wedged") {
      const local = homeFor(name, true);
      const first = await open(`${name}-first`, local);
      const holder = lockHolder(local);
      if (!(first.shown && ready(first.shown) && holder && running("szfriends-helper.exe").includes(holder))) {
        notOk(`${name}: the first launch did not leave a helper running: ${JSON.stringify(first.shown)}`);
        continue;
      }
      if (name === "wedged" && !freeze(holder)) notOk("wedged: the helper could not be suspended");
      const again = await open(name, local, { timeout: 45_000 });
      const ended = !running("szfriends-helper.exe").includes(holder);
      if (name === "wedged") freeze(holder, true); // if it still runs, it may leave on its own
      if (again.shown && ready(again.shown) && (name === "lingering" || ended))
        ok(
          `${name}: opened again with the first launch's helper ${name === "wedged" ? "hung" : "still running"}, ` +
            `Friends is ready in ${(again.waited / 1000).toFixed(1)} s` +
            (name === "wedged" ? " (the hung helper was ended and a new one started)" : ""),
        );
      else notOk(`${name}: ${JSON.stringify(again.shown)} (old helper ${holder} ${ended ? "ended" : "still running"})`);
    } else if (["declined", "public", "allowed", "blocked"].includes(name)) {
      const local = homeFor(name, true);
      const expected = {
        declined: (shown) => /keeps people on this network from finding this PC/.test(shown?.note ?? ""),
        public: (shown) => /treats this network as public/.test(shown?.note ?? ""),
        allowed: (shown) => Boolean(shown) && !shown.note && !/can’t see this PC/.test(shown.text),
        blocked: (shown) => /A Windows Firewall rule blocks Friends/.test(shown?.note ?? ""),
      }[name];
      const { shown } = await open(name, local, { then: nearby(expected) });
      if (expected(shown)) ok(`${name}: Nearby says "${shown.note || "nothing about the firewall"}"`);
      else notOk(`${name}: Nearby shows ${JSON.stringify(shown)}`);
      if (name === "declined" && !/Allow on Private Networks/.test(shown?.text ?? ""))
        notOk("declined: no Allow on Private Networks button");
      const holder = lockHolder(local);
      const ports = holder ? listening(holder) : [];
      const ours = ports.filter((p) => p >= FRIENDS_PORTS[0] && p <= FRIENDS_PORTS[1]);
      if (name === "allowed" ? ours.length > 0 : ports.length === 0)
        ok(`${name}: the helper ${ours.length ? `listens on port ${ours.join(", ")}` : "listens on no port"}`);
      else notOk(`${name}: the helper listens on ${JSON.stringify(ports)}`);
    } else if (name === "bounds") {
      // Tauri keeps window bounds in the Roaming AppData known folder, whatever %APPDATA% says: the signed-in user's.
      const config = path.join(process.env.APPDATA, "com.shenzhen3d.viewer");
      const files = ["window-bounds.json", ".window-state.json"].map((file) => path.join(config, file));
      const kept = files.map((file) => (fs.existsSync(file) ? fs.readFileSync(file) : undefined));
      const local = homeFor("bounds", true);
      const minimum = (shown) => [360, 560].map((size) => Math.round((size * shown.dpi) / 96));
      try {
        // As 0.2.3 left it after many launches: 9 px of content, in the old file only.
        fs.mkdirSync(config, { recursive: true });
        fs.rmSync(files[0], { force: true });
        const shrunk = { width: 1600, height: 9, x: 120, y: 80, prev_x: 0, prev_y: 0, maximized: false, visible: true };
        fs.writeFileSync(files[1], JSON.stringify({ main: { ...shrunk, decorated: true, fullscreen: false } }));
        const healed = await measure(local);
        const [minWidth, minHeight] = healed ? minimum(healed) : [];
        if (healed && healed.content[0] >= minWidth && healed.content[1] >= minHeight && !healed.minimized)
          ok(`bounds: a window saved 9 px tall opens with ${healed.content.join(" × ")} px of content (minimum ${minWidth} × ${minHeight})`);
        else notOk(`bounds: a window saved 9 px tall opens as ${JSON.stringify(healed)}`);
        const launches = [];
        for (let i = 0; i < 5; i++) launches.push(await measure(local));
        const key = (shown) => shown && `${shown.x},${shown.y} ${shown.width}×${shown.height} (content ${shown.content.join("×")})`;
        if (launches.every((shown) => shown && key(shown) === key(launches[0])))
          ok(`bounds: five launches in a row open at the same place and size: ${key(launches[0])}`);
        else notOk(`bounds: the window moves or changes size between launches: ${launches.map(key).join(" | ")}`);
      } finally {
        files.forEach((file, i) => (kept[i] ? fs.writeFileSync(file, kept[i]) : fs.rmSync(file, { force: true })));
      }
    } else notOk(`unknown scenario ${name}`);
  }
  // The friends the kept home already has show in every state: they do not depend on the local network.
  if (keptHome && scenarios.some((s) => ["declined", "public", "blocked"].includes(s))) {
    const list = await open("friends-list", keptHome, { settled: (shown) => ready(shown) && shown.rows > 0 });
    if (list.shown && list.shown.rows > 0)
      ok(`friends-list: ${list.shown.rows} friend(s) shown while people nearby cannot reach this PC`);
    else notOk(`friends-list: ${JSON.stringify(list.shown)}`);
  }
} catch (error) {
  notOk(String(error?.stack ?? error));
} finally {
  if (!flag("keep") && !value("installed")) await uninstall();
}
console.log(failures ? `windows-installer-smoke: FAILED (${failures})` : "windows-installer-smoke: passed");
process.exit(failures ? 1 : 0);
