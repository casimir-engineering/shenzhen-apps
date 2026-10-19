// The Tauri Friends smoke: Shenzhen 3D's Tauri app, built with the `friends-smoke` feature, against two real helpers
// in temporary Friends homes on one computer: the app's own, which its plugin spawns, and a peer's, driven from here
// over the client protocol. The page half (tauri-smoke-page.js) uses the panel as a person would; this half is the
// friend at the other end. Nothing leaves the computer and nobody's own Friends identity or helper is touched.
//
//   Windows, Linux (the Rust helper): the two homes are made friends first (the befriend tool), and the helpers
//   reach each other over their test routes on 127.0.0.1 ($SZFRIENDS_TEST_LOOPBACK).
//   macOS (the Objective-C helper): see tauri-smoke-mac.mjs, which drives the peer through the Electron addon.
//
//   node scripts/friends/tauri-smoke.mjs --app <shenzhen-3d> --helper <szfriends-helper> --befriend <befriend>
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { argv, platform } from "node:process";

const root = path.resolve(
  path.dirname(
    new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1"),
  ),
  "../..",
);
const option = (name) => {
  const index = argv.indexOf(`--${name}`);
  if (index < 0 || !argv[index + 1]) throw Error(`--${name} is required`);
  return path.resolve(argv[index + 1]);
};
const app = option("app"),
  helper = option("helper"),
  befriend = option("befriend");
const directory = await fs.mkdtemp(
  path.join(os.tmpdir(), "szf3d-tauri-smoke-"),
);
const homeApp = path.join(directory, "app-home"),
  homePeer = path.join(directory, "peer-home");
const routes = path.join(directory, "routes");
const checks = [];
const check = (name) => {
  checks.push(name);
  console.log(`ok peer ${checks.length} ${name}`);
};
const testEnvironment = {
  SZFRIENDS_TEST_LOOPBACK: routes,
  // A helper whose last client left exits after a tenth of the usual wait, so the run ends promptly.
  SZFRIENDS_HELPER_TIME_SCALE: "0.1",
};

/** Where a helper for `home` listens (PROTOCOL.md § Transport; the Windows row: the advertised pipe). */
async function helperAddress(home) {
  if (platform === "win32") {
    const name = (
      await fs.readFile(path.join(home, "ipc", "helper.pipe"), "utf8")
    ).trim();
    return name;
  }
  const canonical = await fs.realpath(home);
  const primary = `${canonical}/ipc/helper.sock`;
  if (Buffer.byteLength(primary) < 104) return primary;
  let hash = 0xcbf29ce484222325n;
  for (const byte of Buffer.from(canonical))
    hash = BigInt.asUintN(64, (hash ^ BigInt(byte)) * 0x100000001b3n);
  const temp = process.env.XDG_RUNTIME_DIR?.startsWith("/")
    ? process.env.XDG_RUNTIME_DIR
    : "/tmp";
  return `${temp}/szfriends-${hash.toString(16).padStart(16, "0")}/helper.sock`;
}

/** The peer: one client of its own helper, which it starts as an app would. */
async function startPeer() {
  const child = spawn(helper, [], {
    env: { ...process.env, ...testEnvironment, SZFRIENDS_STATE_DIR: homePeer },
    stdio: "ignore",
    detached: true,
  });
  child.unref();
  const started = Date.now();
  let socket;
  while (!socket) {
    try {
      const address = await helperAddress(homePeer);
      socket = await new Promise((resolve, reject) => {
        const candidate = net.connect(address, () => resolve(candidate));
        candidate.once("error", reject);
      });
    } catch {
      if (Date.now() - started > 20_000)
        throw Error("the peer's helper did not start");
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  const replies = new Map(),
    views = new Map();
  let buffered = "",
    next = 1,
    welcome;
  socket.setEncoding("utf8");
  socket.on("data", (text) => {
    buffered += text;
    let end;
    while ((end = buffered.indexOf("\n")) >= 0) {
      const line = buffered.slice(0, end).trim();
      buffered = buffered.slice(end + 1);
      if (!line) continue;
      const frame = JSON.parse(line);
      if (frame.type === "welcome") welcome = frame;
      else if (frame.type === "reply") replies.get(frame.re)?.(frame);
      else if (frame.type === "snapshot")
        views.set(frame.subscription, frame.data);
    }
  });
  const write = (frame) => socket.write(`${JSON.stringify(frame)}\n`);
  write({
    type: "hello",
    id: "1",
    protocol: { major: 1, minor: 0, min_major: 1 },
    client: {
      app_id: "com.shenzhen3d.friends-smoke",
      app_name: "Friends smoke peer",
      app_version: "1",
      toolkit: "test",
      reveal_in: "Files",
      pid: process.pid,
    },
    capabilities: ["drop.files", "mentions"],
    open_formats: [],
    locale: "en",
  });
  const until = async (condition, what, timeout = 90_000) => {
    const begun = Date.now();
    for (;;) {
      const value = condition();
      if (value) return value;
      if (Date.now() - begun > timeout)
        throw Error(`peer: timed out waiting for ${what}`);
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
  };
  await until(() => welcome, "the peer's welcome");
  const send = async (type, fields = {}) => {
    const id = String(++next);
    const reply = new Promise((resolve) => replies.set(id, resolve));
    write({ ...fields, type, id });
    const answer = await reply;
    if (!answer.ok)
      throw Error(`peer: ${type} failed: ${JSON.stringify(answer.error)}`);
    return answer.result;
  };
  // As a person opening Friends would: the helper starts looking for friends nearby only after this.
  await send("activate");
  return {
    until,
    send,
    async view(type, fields) {
      const { subscription } = await send(type, fields);
      return () => views.get(subscription);
    },
    close: () => socket.end(),
  };
}

let failed = false;
let peer;
try {
  await fs.mkdir(routes);
  const seeded = spawnSync(befriend, [homeApp, homePeer, "Ada", "Bo"], {
    encoding: "utf8",
  });
  if (seeded.status !== 0) throw Error(`befriend failed: ${seeded.stderr}`);
  const [, adaInPeer] = seeded.stdout.trim().split(/\s+/);

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
    mode: "seeded",
    peerName: "Bo",
    message: "Hello from Shenzhen 3D",
    reply: "Hi Ada",
    incomingName: "bracket.svg",
    outgoingName: "triangle.stl",
    outgoingText: mesh,
    outgoingPath: dropped,
    // A download link's form (PROTOCOL.md § Links) that no helper made: opening it shows its page all the same.
    link: `shenzhen3d://friends/link#d.${Buffer.from([1, ...Array(48).fill(7)]).toString("base64url")}`,
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

  peer = await startPeer();
  // On Linux the app keeps its window state and web data under directories of its own, never the person's.
  const appUser = path.join(directory, "app-user");
  const ownDirectories =
    platform === "linux"
      ? {
          XDG_DATA_HOME: path.join(appUser, "data"),
          XDG_CONFIG_HOME: path.join(appUser, "config"),
          XDG_CACHE_HOME: path.join(appUser, "cache"),
        }
      : {};
  const appEnvironment = {
    ...process.env,
    ...testEnvironment,
    ...ownDirectories,
    SZFRIENDS_STATE_DIR: homeApp,
    SHENZHEN_3D_FRIENDS_HELPER: helper,
    SHENZHEN_3D_FRIENDS_DATA: path.join(directory, "app-data"),
  };
  // The link, opened as a browser opens it: the app started again with the link as its argument, which hands it to
  // the running app and ends.
  let secondLaunch;
  const openLink = () =>
    new Promise((resolve) => {
      const child = spawn(app, [page.link], {
        env: appEnvironment,
        stdio: "ignore",
      });
      const timer = setTimeout(() => child.kill(), 30_000);
      child.on("exit", (code) => {
        clearTimeout(timer);
        resolve(code);
      });
    });
  const appRun = new Promise((resolve) => {
    const child = spawn(app, [], {
      env: { ...appEnvironment, SHENZHEN_3D_SMOKE: script },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let output = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (text) => {
      output += text;
      process.stdout.write(text.replace(/^/gm, "app: "));
      if (!secondLaunch && output.includes("SMOKE-LINK-READY"))
        secondLaunch = openLink();
    });
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (text) =>
      process.stderr.write(text.replace(/^/gm, "app stderr: ")),
    );
    const timer = setTimeout(() => child.kill(), 300_000);
    child.on("exit", (code) => {
      clearTimeout(timer);
      resolve({ code, passed: output.includes("SMOKE-PASSED") });
    });
  });

  try {
    const conversation = await peer.view("open_conversation", {
      conversation_id: adaInPeer,
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
      conversation_id: adaInPeer,
      text: page.reply,
      client_token: "smoke-message-0000000000000001",
    });
    await peer.send("send_files", {
      conversation_id: adaInPeer,
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
  if (secondLaunch && (await secondLaunch) === 0)
    check("a second launch with a link hands it over and ends");
  else {
    failed = true;
    console.error("the second launch with a link did not hand it over and end");
  }
} catch (error) {
  failed = true;
  console.error(String(error?.stack ?? error));
} finally {
  // However the run ended, its temporary homes go. Both helpers exit on their own once their last client left;
  // the homes go only after they did.
  peer?.close();
  try {
    for (const home of [homeApp, homePeer]) {
      const name =
        platform === "win32"
          ? path.join(home, "ipc", "helper.pipe")
          : await helperAddress(home);
      const begun = Date.now();
      while (Date.now() - begun < 30_000) {
        try {
          await fs.access(name);
          await new Promise((resolve) => setTimeout(resolve, 200));
        } catch {
          break;
        }
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 1000));
  } catch {
    // A home whose helper never started has nothing to wait for.
  }
  await fs.rm(directory, { recursive: true, force: true }).catch(() => {});
}
console.log(
  failed
    ? "tauri-smoke: FAILED"
    : `tauri-smoke: passed (${checks.length} peer checks)`,
);
process.exit(failed ? 1 : 0);
