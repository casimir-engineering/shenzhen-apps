#!/usr/bin/env node
// phones-link.mjs — Friends links opened by the phone's system reach Shenzhen 3D's panel (docs/FRIENDS.md § Tauri,
// Friends links), in a Friends home of the run's own:
//
//   node scripts/friends/phones-link.mjs --platform android --serial emulator-5584   a debug APK installed
//   node scripts/friends/phones-link.mjs --platform ios --udid <simulator>           a friends-smoke build installed
//
// Android: the first link starts the app (the activity's VIEW intent), the second reaches it while it runs; the page
// is checked through the WebView's DevTools. iOS: the same, the page script given to the app through the simulator's
// launchd, and each link opened by a UI test (scripts/friends/ios-link-open), since `simctl openurl` waits for a
// person to confirm. The links are download links' form, made by no helper: each still opens its page. Needs xcodegen.
import { execFileSync, spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const argv = process.argv.slice(2);
const option = (name) => argv[argv.indexOf(`--${name}`) + 1];
const platform = option("platform");
if (!["android", "ios"].includes(platform)) {
  console.error(
    "usage: phones-link.mjs --platform android --serial <s> | --platform ios --udid <u>",
  );
  process.exit(64);
}
const PACKAGE = "com.shenzhen3d.viewer";
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const link = () =>
  `shenzhen3d://friends/link#d.${Buffer.concat([Buffer.from([1]), randomBytes(48)]).toString("base64url")}`;
const pageScript = await fs.readFile(
  new URL("./phones-link-page.js", import.meta.url),
  "utf8",
);
const work = await fs.mkdtemp(path.join(os.tmpdir(), "szf-phone-link-"));
let result;
try {
  result =
    platform === "android"
      ? await runAndroid(option("serial"))
      : await runIos(option("udid"));
} finally {
  await fs.rm(work, { recursive: true, force: true });
}
for (const line of result.lines) console.log(line);
console.log(result.ok ? "phones-link: passed" : "phones-link: FAILED");
process.exit(result.ok ? 0 : 1);

async function runAndroid(serial) {
  const adb = (...args) =>
    execFileSync("adb", ["-s", serial, ...args], { encoding: "utf8" });
  const runAs = (command) =>
    adb("shell", `run-as ${PACKAGE} sh -c '${command}'`);
  const files = `/data/user/0/${PACKAGE}/files`;
  adb("shell", "am", "force-stop", PACKAGE);
  runAs(
    "rm -rf files/flink && mkdir -p files/flink/home files/flink/routes && chmod -R 700 files/flink",
  );
  const environment = `SZFRIENDS_STATE_DIR=${files}/flink/home\\nSZFRIENDS_TEST_LOOPBACK=${files}/flink/routes\\n`;
  runAs(`printf "${environment}" > files/friends-test.env`);
  const open = (url) =>
    adb(
      "shell",
      "am",
      "start",
      "-a",
      "android.intent.action.VIEW",
      "-d",
      `'${url}'`,
      PACKAGE,
    );
  let devtools = 0;
  try {
    open(link());
    let pid = "";
    for (let i = 0; i < 120 && !pid; i++) {
      await wait(500);
      let candidate = "";
      try {
        candidate = adb("shell", "pidof", PACKAGE).trim();
      } catch {
        continue; // not started yet
      }
      if (
        candidate &&
        adb("shell", "cat", "/proc/net/unix").includes(
          `webview_devtools_remote_${candidate}`,
        )
      )
        pid = candidate;
    }
    if (!pid) throw Error("the app's WebView did not start");
    devtools = 9000 + (Number(serial.replace(/\D/g, "")) % 1000);
    adb(
      "forward",
      `tcp:${devtools}`,
      `localabstract:webview_devtools_remote_${pid}`,
    );
    const evaluate = (expression) => devtoolsEvaluate(devtools, expression);
    for (let i = 0; i < 120; i++) {
      if (
        await evaluate("document.readyState === 'complete'").catch(() => false)
      )
        break;
      await wait(500);
    }
    // Started, not awaited: the page waits for the second link, which this loop opens.
    await evaluate(
      `window.__SZF_LINK__ = ${JSON.stringify({ links: 2, cold: true })};\n${pageScript}\ntrue`,
    );
    for (let i = 0; i < 480; i++) {
      const state = await evaluate(
        "({ waiting: window.__SZF_LINK_WAITING__, result: window.__SZF_LINK_RESULT__ })",
      );
      if (state.result) return state.result;
      if (state.waiting === 2) {
        open(link());
        await evaluate("window.__SZF_LINK_WAITING__ = 'opened'");
      }
      await wait(250);
    }
    return { ok: false, lines: ["not ok the page reported nothing"] };
  } finally {
    adb("shell", "am", "force-stop", PACKAGE);
    if (devtools) adb("forward", "--remove", `tcp:${devtools}`);
    runAs("rm -rf files/flink files/friends-test.env");
  }
}

async function devtoolsEvaluate(port, expression) {
  const targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
  const target = targets.find((t) => t.type === "page") ?? targets[0];
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    socket.onopen = resolve;
    socket.onerror = reject;
  });
  const answer = new Promise((resolve) => {
    socket.onmessage = (event) => {
      const message = JSON.parse(event.data);
      if (message.id === 1) resolve(message.result);
    };
  });
  const params = { expression, awaitPromise: true, returnByValue: true };
  socket.send(JSON.stringify({ id: 1, method: "Runtime.evaluate", params }));
  const result = await answer;
  socket.close();
  if (result.exceptionDetails)
    throw Error(JSON.stringify(result.exceptionDetails));
  return result.result.value;
}

async function runIos(udid) {
  const simctl = (...args) =>
    execFileSync("xcrun", ["simctl", ...args], { encoding: "utf8" });
  const openLink = await linkOpener(udid);
  const home = path.join(work, "home");
  const routes = path.join(work, "routes");
  await fs.mkdir(home, { mode: 0o700 });
  await fs.mkdir(routes, { mode: 0o700 });
  const script = path.join(work, "page.js");
  await fs.writeFile(
    script,
    `window.__SZF_LINK__ = ${JSON.stringify({ links: 2, cold: true, smoke: true })};\n${pageScript}`,
  );
  // `log show --start` reads the simulator's local time.
  const now = new Date(Date.now() - 1000);
  const started = new Date(now - now.getTimezoneOffset() * 60_000)
    .toISOString()
    .replace("T", " ")
    .slice(0, 19);
  const terminate = () => {
    try {
      simctl("terminate", udid, PACKAGE);
    } catch {
      // Not running.
    }
  };
  terminate();
  // The first link starts the app, in the run's own Friends home and with the page script: the simulator's launchd
  // gives the app that environment (a link's launch takes none of its own), until the run ends.
  const environment = {
    SZFRIENDS_STATE_DIR: home,
    SZFRIENDS_TEST_LOOPBACK: routes,
    SHENZHEN_3D_SMOKE: script,
  };
  simctl(
    "spawn",
    udid,
    "launchctl",
    "setenv",
    ...Object.entries(environment).flat(),
  );
  const opening = openLink(link());
  try {
    let opened = 1;
    for (let i = 0; i < 300; i++) {
      await wait(1000);
      const log = simctl(
        "spawn",
        udid,
        "log",
        "show",
        "--style",
        "compact",
        "--start",
        started,
        "--predicate",
        'process == "Shenzhen 3D" AND eventMessage CONTAINS "SMOKE"',
      );
      if (/SMOKE-(PASSED|FAILED)/.test(log))
        return {
          ok: log.includes("SMOKE-PASSED"),
          lines: [...log.matchAll(/SMOKE (.*)$/gm)].map((m) => m[1]),
        };
      if ((log.match(/SMOKE-LINK-READY/g) ?? []).length + 1 > opened) {
        opened++;
        openLink(link());
      }
    }
    return { ok: false, lines: ["not ok the app reported nothing"] };
  } finally {
    terminate();
    for (const name of Object.keys(environment))
      simctl("spawn", udid, "launchctl", "unsetenv", name);
    await opening;
  }
}

// How the run opens links on iOS: scripts/friends/ios-link-open, a UI test built here for the simulator, hands each
// one to the app through the system (its project.yml says why not `simctl openurl`).
async function linkOpener(udid) {
  const project = path.join(work, "link-open");
  await fs.cp(new URL("./ios-link-open", import.meta.url), project, {
    recursive: true,
  });
  const quiet = { cwd: project, stdio: "pipe", encoding: "utf8" };
  execFileSync("xcodegen", ["generate", "--quiet"], quiet);
  const derived = path.join(project, "build");
  execFileSync(
    "xcodebuild",
    [
      "build-for-testing",
      ...["-project", "SZFLinkOpen.xcodeproj", "-scheme", "LinkOpen"],
      ...["-destination", `id=${udid}`, "-derivedDataPath", derived],
    ],
    quiet,
  );
  const products = path.join(derived, "Build", "Products");
  const plan = (await fs.readdir(products)).find((name) =>
    name.endsWith(".xctestrun"),
  );
  return (url) =>
    new Promise((resolve) => {
      const child = spawn(
        "xcodebuild",
        [
          "test-without-building",
          ...["-xctestrun", path.join(products, plan)],
          ...["-destination", `id=${udid}`],
          "-only-testing:LinkOpen/SZFLinkOpenTests/testOpenLink",
        ],
        { env: { ...process.env, TEST_RUNNER_SZF_LINK: url }, stdio: "ignore" },
      );
      child.on("exit", resolve);
    });
}
