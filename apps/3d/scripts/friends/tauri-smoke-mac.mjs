// The Tauri Friends smoke on a Mac: Shenzhen 3D's Tauri app, built with the `friends-smoke` feature, against two
// Objective-C helpers built from the pin (friends.lock) in temporary Friends homes: the app's own, which its plugin
// spawns, and a peer's, driven from here through the Electron app's client addon. They find each other only over
// loopback Bonjour with a service type of this run's own, as electron/friends-smoke.mjs does, so the page half
// (tauri-smoke-page.js, mode "request") makes itself visible, accepts the peer's request, then exchanges messages
// and files. Nobody's own Friends identity, helper or Keychain is touched.
//
//   scripts/friends/setup-friends.sh && npm run build && (build the app with the friends-smoke feature) &&
//   node scripts/friends/tauri-smoke-mac.mjs --app <Shenzhen 3D executable>
//   node scripts/friends/tauri-smoke-mac.mjs --bundle <Shenzhen 3D.app>
//
// --bundle runs a packaged app (platform-build.mjs desktop --friends with the friends-smoke feature) with the helper
// it carries in Contents/Helpers, from a copy whose helper also declares the run's Bonjour type.
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { argv } from "node:process";

const require = createRequire(import.meta.url);
const root = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  "../..",
);
const option = (name, fallback) => {
  const index = argv.indexOf(`--${name}`);
  if (index >= 0 && argv[index + 1]) return path.resolve(argv[index + 1]);
  if (fallback) return fallback;
  throw Error(`--${name} is required`);
};
const { friendsBuild } = require("../../electron/friends/lock.cjs");
const { readHelperInfo } = require("../../electron/friends/host.cjs");
const build = friendsBuild(root);
const bundleIndex = argv.indexOf("--bundle");
const bundle = bundleIndex >= 0 ? path.resolve(argv[bundleIndex + 1]) : null;
const app = bundle ? null : option("app");
const pinnedHelper = bundle
  ? path.join(bundle, "Contents/Helpers/Shenzhen Friends.app")
  : option("helper", build.helperApp);
const addon = require(
  option(
    "addon",
    path.join(
      root,
      "artifacts/friends-native",
      process.arch,
      "friends-link.node",
    ),
  ),
);

const directory = await fs.mkdtemp(path.join(os.tmpdir(), "szf3d-tauri-mac-"));
const homeApp = path.join(directory, "app-home"),
  homePeer = path.join(directory, "peer-home");
const serviceType = `_szf3t${process.pid.toString(36).slice(-6)}._tcp`;
process.env.SZFRIENDS_TEST_SERVICE_TYPE = serviceType;
// macOS lets a bundle browse and advertise only the Bonjour types its Info.plist declares, so this run's helpers
// are an ad-hoc signed copy of the pinned helper that also declares the test type: for --bundle, the app's own
// helper inside a copy of the app.
const appCopy = bundle
  ? path.join(directory, "app", path.basename(bundle))
  : null;
const helperApp = bundle
  ? path.join(appCopy, "Contents/Helpers/Shenzhen Friends.app")
  : path.join(directory, "helper", "Shenzhen Friends.app");
if (bundle) {
  await fs.mkdir(path.dirname(appCopy));
  execFileSync("ditto", [bundle, appCopy]);
} else {
  await fs.mkdir(path.dirname(helperApp));
  execFileSync("ditto", [pinnedHelper, helperApp]);
}
execFileSync("/usr/libexec/PlistBuddy", [
  "-c",
  `Add :NSBonjourServices: string ${serviceType}`,
  path.join(helperApp, "Contents/Info.plist"),
]);
execFileSync("codesign", ["--force", "--sign", "-", helperApp], {
  stdio: "pipe",
});
// The app around it is signed again too (not deeply: the helper keeps its own signature), as packaging signs it.
if (bundle)
  execFileSync("codesign", ["--force", "--sign", "-", appCopy], {
    stdio: "pipe",
  });
const appExecutable = bundle
  ? path.join(
      appCopy,
      "Contents/MacOS",
      execFileSync(
        "plutil",
        [
          "-extract",
          "CFBundleExecutable",
          "raw",
          "-o",
          "-",
          path.join(appCopy, "Contents/Info.plist"),
        ],
        { encoding: "utf8" },
      ).trim(),
    )
  : app;
const helperExecutable = path.join(
  helperApp,
  "Contents/MacOS/Shenzhen Friends",
);
const helper = readHelperInfo(helperApp);
const checks = [];
const check = (name) => {
  checks.push(name);
  console.log(`ok peer ${checks.length} ${name}`);
};

function createPeer() {
  const replies = new Map(),
    views = new Map();
  let state = "idle",
    welcome;
  const client = addon.createClient(
    {
      stateDir: homePeer,
      helperPath: helperExecutable,
      helperVersion: helper.version,
      helperBuildNumber: helper.buildNumber,
      appId: "com.shenzhen3d.friends-smoke",
      appName: "Friends smoke peer",
      appVersion: "1",
      toolkit: "test",
      revealIn: "Finder",
      capabilities: ["drop.files", "mentions"],
      openFormats: [],
    },
    (events) => {
      for (const event of events) {
        if (event.type === "state") state = event.state;
        else {
          const frame = JSON.parse(event.json);
          if (frame.type === "welcome") welcome = frame;
          if (frame.type === "reply") replies.get(frame.re)?.(frame);
          if (frame.type === "snapshot")
            views.set(frame.subscription, frame.data);
        }
      }
    },
  );
  const keepAlive = setInterval(() => {}, 1000);
  const until = async (condition, what, timeout = 90_000) => {
    const started = Date.now();
    for (;;) {
      const value = condition();
      if (value) return value;
      if (Date.now() - started > timeout)
        throw Error(`peer: timed out waiting for ${what}`);
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
  };
  const send = async (type, fields = {}) => {
    const result = client.send(type, JSON.stringify(fields));
    if (result.status !== "ok")
      throw Error(`peer: ${type} not sent (${result.status})`);
    const reply = await new Promise((resolve) =>
      replies.set(result.id, resolve),
    );
    if (!reply.ok)
      throw Error(`peer: ${type} failed: ${JSON.stringify(reply.error)}`);
    return reply.result;
  };
  return {
    client,
    until,
    send,
    ready: () => until(() => state === "ready" && welcome, "the peer's helper"),
    async view(type, fields) {
      const { subscription } = await send(type, fields);
      return () => views.get(subscription);
    },
    close() {
      clearInterval(keepAlive);
      client.stop(false);
      client.close();
    },
  };
}

const fixtures = path.join(root, "tests/fixtures/formats");
const outgoing = path.join(directory, "outgoing");
await fs.mkdir(outgoing);
const drawing = path.join(outgoing, "bracket.svg");
await fs.copyFile(path.join(fixtures, "drawing.svg"), drawing);
const mesh = await fs.readFile(path.join(fixtures, "triangle.stl"), "utf8");
// The file the page drops, on disk where the system's report of the drop names it.
const dropped = path.join(outgoing, "triangle.stl");
await fs.writeFile(dropped, mesh);
const page = {
  mode: "request",
  ownName: "Ada",
  peerName: "Bo",
  message: "Hello from Shenzhen 3D",
  reply: "Hi Ada",
  incomingName: "bracket.svg",
  outgoingName: "triangle.stl",
  outgoingText: mesh,
  outgoingPath: dropped,
};
const script = path.join(directory, "page.js");
await fs.writeFile(
  script,
  `window.__SZF_SMOKE__ = ${JSON.stringify(page)};\n` +
    (await fs.readFile(
      path.join(root, "scripts/friends/tauri-smoke-page.js"),
      "utf8",
    )),
);

let failed = false;
const peer = createPeer();
peer.client.start();
await peer.ready();
await peer.send("set_name", { name: "Bo" });
await peer.send("activate");
// The app keeps its window state and web data under a home of its own, never the person's.
const appHome = path.join(directory, "app-user");
await fs.mkdir(appHome);
const appRun = new Promise((resolve) => {
  const child = spawn(appExecutable, [], {
    env: {
      ...process.env,
      HOME: appHome,
      CFFIXED_USER_HOME: appHome,
      SZFRIENDS_STATE_DIR: homeApp,
      // A packaged app finds the helper it carries in Contents/Helpers.
      ...(bundle ? {} : { SHENZHEN_3D_FRIENDS_HELPER: helperApp }),
      SHENZHEN_3D_FRIENDS_DATA: path.join(directory, "app-data"),
      SHENZHEN_3D_SMOKE: script,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let output = "";
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (text) => {
    output += text;
    process.stdout.write(text.replace(/^/gm, "app: "));
  });
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (text) =>
    process.stderr.write(text.replace(/^/gm, "app stderr: ")),
  );
  const timer = setTimeout(() => child.kill(), 360_000);
  child.on("exit", (code) => {
    clearTimeout(timer);
    resolve({ code, passed: output.includes("SMOKE-PASSED") });
  });
});

try {
  const nearby = await peer.view("subscribe", { view: "nearby" });
  const ada = await peer.until(
    () =>
      nearby()?.people?.find(
        (person) => person.title === page.ownName && person.nearby_id,
      ),
    "Ada in Nearby",
    120_000,
  );
  await peer.send("send_request", { nearby_id: ada.nearby_id });
  check("the peer finds the app nearby and asks to be friends");
  const list = await peer.view("subscribe", { view: "list" });
  const friend = await peer.until(
    () =>
      list()?.rows?.find(
        (row) => row.title === page.ownName && !row.waiting && row.drop_label,
      ),
    "Ada as a friend",
    120_000,
  );
  const conversation = await peer.view("open_conversation", {
    conversation_id: friend.conversation_id,
  });
  const items = () => conversation()?.items ?? [];
  await peer.until(
    () =>
      items().some(
        (item) => item.kind === "message" && item.text === page.message,
      ),
    "Ada's message",
  );
  check("the app's message arrives");
  await peer.send("send_message", {
    conversation_id: friend.conversation_id,
    text: page.reply,
    client_token: "smoke-message-0000000000000001",
  });
  await peer.send("send_files", {
    conversation_id: friend.conversation_id,
    files: [{ path: drawing }],
    client_token: "smoke-files-00000000000000000001",
  });
  const offer = await peer.until(
    () =>
      items().find(
        (item) =>
          item.kind === "transfer" &&
          item.direction === "in" &&
          item.file?.name === page.outgoingName &&
          item.actions?.some((action) => action.action === "accept_offer"),
      ),
    "the app's dropped file",
  );
  await peer.send("accept_offer", { transfer_id: offer.transfer_id });
  const received = await peer.until(
    () =>
      items().find(
        (item) =>
          item.transfer_id === offer.transfer_id && item.state === "received",
      ),
    "the dropped file received",
  );
  const file = received.actions?.find(
    (action) => typeof action.path === "string",
  )?.path;
  if (!file || (await fs.readFile(file, "utf8")) !== mesh)
    throw Error("the received file differs from the dropped one");
  check("the dropped file arrives whole");
} catch (error) {
  failed = true;
  console.error(String(error?.stack ?? error));
}
const result = await appRun;
peer.close();
if (!result.passed || result.code !== 0) failed = true;

// Both helpers exit on their own once their last client left; the homes go only after they did.
const lockHeld = async (home) => {
  try {
    execFileSync("/usr/bin/lsof", ["-t", path.join(home, "helper.lock")], {
      stdio: "pipe",
    });
    return true;
  } catch {
    return false;
  }
};
for (const home of [homeApp, homePeer]) {
  const begun = Date.now();
  while ((await lockHeld(home)) && Date.now() - begun < 30_000)
    await new Promise((resolve) => setTimeout(resolve, 250));
}
await fs.rm(directory, { recursive: true, force: true }).catch(() => {});
console.log(
  failed
    ? "tauri-smoke-mac: FAILED"
    : `tauri-smoke-mac: passed (${checks.length} peer checks)`,
);
process.exit(failed ? 1 : 0);
