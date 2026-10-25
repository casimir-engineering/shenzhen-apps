#!/usr/bin/env node
// android-ipc-origin-e2e.mjs — the page's first calls into the app must work even when they go out before
// onPageStarted, on an emulator (src-tauri/gen/android/…/PageIpc.kt says why they can).
//
//   node scripts/android-ipc-origin-e2e.mjs --serial emulator-5554 [--apk <apk>] [--shot <png>]
//
// The app (installed, or --apk) is started under a debugger, and while its page loads, each file the WebView asks the
// app for puts wry's recorded page address back to "about:blank": the state a page is in when its scripts run before
// onPageStarted, which a busy main thread causes on phones (the first launch after an update, the activity created
// again). Then the page must show no red error banner and its calls must work. Before PageIpc, the page showed
// "Command plugin:event|listen not allowed by ACL".
//
// Emulators only, a Google APIs image (adb root): debugging a release build needs the system's JDWP switch
// (persist.debug.dalvik.vm.jdwp.enabled), which the script turns on, restarting Android's framework once, and leaves
// on. Needs a JDK's jdb (JAVA_HOME, or on PATH).
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const PACKAGE = "com.shenzhen3d.viewer";
const CLIENT = `${PACKAGE}.RustWebViewClient`;
const argv = process.argv.slice(2);
const option = (name) => {
  const index = argv.indexOf(`--${name}`);
  return index >= 0 ? argv[index + 1] : undefined;
};
const serial = option("serial");
if (!serial?.startsWith("emulator-")) {
  console.error(
    "usage: android-ipc-origin-e2e.mjs --serial emulator-NNNN [--apk <apk>] [--shot <png>]",
  );
  process.exit(2);
}
const sdk =
  process.env.ANDROID_HOME ?? path.join(os.homedir(), "Library/Android/sdk");
const adbPath = path.join(sdk, "platform-tools/adb");
const adb = (...args) =>
  execFileSync(adbPath, ["-s", serial, ...args], {
    encoding: "utf8",
    maxBuffer: 1 << 26,
  });
const jdbPath = process.env.JAVA_HOME
  ? path.join(process.env.JAVA_HOME, "bin/jdb")
  : "jdb";
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const step = (text) => console.log(`==> ${text}`);
const fail = (text) => {
  console.error(`FAIL: ${text}`);
  try {
    adb("shell", "am", "clear-debug-app");
  } catch {
    // Already cleared or the emulator went away.
  }
  process.exit(1);
};

// 1. A debugger may attach to release builds.
adb("root");
adb("wait-for-device");
if (adb("shell", "id -u").trim() !== "0")
  fail("needs adb root (a Google APIs emulator image)");
if (
  adb("shell", "getprop persist.debug.dalvik.vm.jdwp.enabled").trim() !== "1"
) {
  step(
    "turning on the system's JDWP switch; Android's framework restarts once",
  );
  adb("shell", "setprop persist.debug.dalvik.vm.jdwp.enabled 1");
  adb("shell", "stop; start");
  adb("wait-for-device");
  const booted = Date.now() + 180_000;
  while (adb("shell", "getprop sys.boot_completed").trim() !== "1") {
    if (Date.now() > booted) fail("Android did not come back");
    await wait(2_000);
  }
  await wait(10_000);
}
if (option("apk")) {
  step(`installing ${path.basename(option("apk"))}`);
  adb("install", "-r", option("apk"));
}

// 2. Started waiting for the debugger.
step("starting the app under the debugger");
adb("shell", "am", "force-stop", PACKAGE);
adb("shell", "am", "set-debug-app", "-w", PACKAGE);
adb("shell", "am", "start", "-n", `${PACKAGE}/.MainActivity`);
let pid = "";
for (const until = Date.now() + 20_000; !pid && Date.now() < until;) {
  await wait(500);
  pid = adb("shell", "pidof", PACKAGE).trim();
}
if (!pid) fail("the app did not start");
adb("forward", "tcp:8700", `jdwp:${pid}`);

// 3. While the page loads: wry's recorded address back to about:blank at each file it asks for.
const jdb = spawn(jdbPath, ["-attach", "localhost:8700"]);
let out = "";
jdb.stdout.on("data", (data) => (out += data));
jdb.stderr.on("data", (data) => (out += data));
const send = (command) => jdb.stdin.write(`${command}\n`);
const until = async (pattern, ms, from = 0) => {
  const end = Date.now() + ms;
  while (!pattern.test(out.slice(from))) {
    if (Date.now() > end) fail(`the debugger did not answer (${pattern})`);
    await wait(50);
  }
};
await until(/>\s*$/m, 20_000);
send(`stop in ${CLIENT}.shouldInterceptRequest`);
await wait(300);
send("resume");
await until(/Breakpoint hit/, 30_000);
// The client's fields are renamed in release builds: the address is its String field that holds one.
let mark = out.length;
send(`fields ${CLIENT}`);
await until(/\*\* fields list \*\*/, 10_000, mark);
await wait(1_000);
const strings = [
  ...out.slice(mark).matchAll(/^\s*java\.lang\.String (\w+)\s*$/gm),
].map((match) => match[1]);
let field;
for (const name of strings) {
  mark = out.length;
  send(`print this.${name}`);
  await until(new RegExp(`this\\.${name} = `), 10_000, mark);
  const value = out
    .slice(mark)
    .match(new RegExp(`this\\.${name} = (\\S+)`))?.[1];
  if (/^"(about:blank|https?:)/.test(value ?? "")) field = name;
}
if (!field) fail(`no address field among ${strings.join(", ")} of ${CLIENT}`);
step(
  `holding the page's address at about:blank while it loads (field ${field})`,
);
let held = 0;
for (const end = Date.now() + 20_000; held < 12 && Date.now() < end;) {
  const hits = (out.match(/Breakpoint hit/g) ?? []).length;
  if (hits > held) {
    held = hits;
    send(`set this.${field} = "about:blank"`);
    await wait(100);
    send("cont");
  }
  await wait(50);
}
send(`clear ${CLIENT}.shouldInterceptRequest`);
await wait(200);
send("cont");
await wait(300);
send("exit");
adb("shell", "am", "clear-debug-app");
if (/ParseException|not a valid/.test(out))
  fail(
    `the debugger refused a command:\n${out
      .split("\n")
      .filter((l) => /Exception|not a valid/.test(l))
      .join("\n")}`,
  );
step(`${held} files served as from about:blank; the page loads`);
await wait(5_000);

// 4. The page: no red banner, and its calls work.
adb("forward", "tcp:9339", `localabstract:webview_devtools_remote_${pid}`);
const targets = await (await fetch("http://localhost:9339/json")).json();
const target = targets.find(
  (t) => t.type === "page" && JSON.parse(t.description || "{}").attached,
);
if (!target) fail("no page on screen");
const socket = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  socket.onopen = resolve;
  socket.onerror = reject;
});
const evaluate = (expression) =>
  new Promise((resolve) => {
    socket.onmessage = (message) => {
      const data = JSON.parse(message.data);
      if (data.id === 1) resolve(data.result?.result?.value);
    };
    socket.send(
      JSON.stringify({
        id: 1,
        method: "Runtime.evaluate",
        params: { expression, awaitPromise: true, returnByValue: true },
      }),
    );
  });
const state = await evaluate(`(async () => {
  const internals = window.__TAURI_INTERNALS__;
  let call;
  try {
    await Promise.race([
      internals.invoke("plugin:event|listen", { event: "ipc-origin-check", target: { kind: "Any" }, handler: internals.transformCallback(() => {}) }),
      new Promise((_, reject) => setTimeout(() => reject("no answer in 5 s"), 5000)),
    ]);
    call = "ok";
  } catch (error) {
    call = String(error);
  }
  return { banner: document.querySelector(".error-banner")?.textContent ?? "", call };
})()`);
socket.close();
if (option("shot"))
  fs.writeFileSync(
    option("shot"),
    execFileSync(adbPath, ["-s", serial, "exec-out", "screencap", "-p"], {
      maxBuffer: 1 << 26,
    }),
  );
if (state?.banner) fail(`the page shows a red error: "${state.banner}"`);
if (state?.call !== "ok")
  fail(`the page's call into the app failed: ${state?.call}`);
console.log(
  "PASS: calls made before onPageStarted carry the page's address; no red error",
);
