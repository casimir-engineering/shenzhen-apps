// Shenzhen Friends in the real Electron shell, against two real helpers built from the pin (friends.lock): the app's
// own, which it spawns, and a peer's, driven from this script through the same client addon. Both run in temporary
// Friends homes (SZFRIENDS_STATE_DIR), so they use a file key store and never the Keychain, and both find each other
// only over loopback Bonjour with a test service type: no Wi-Fi, Bluetooth or Friends server is involved, and the
// person's own Friends identity and helper are never touched.
//
//   scripts/friends/setup-friends.sh && npm run build && node electron/friends-smoke.mjs
//
// It covers: attaching after first paint, the badge, naming, Nearby and a friend request, accepting it, a message
// both ways, a file offer with the sender's preview before acceptance, Accept and Open in the viewer, a file dropped
// on the chat, the open model sent as a .sz3d, Copy Download Link hidden while no links are offered, and `#` in the
// composer listing the recent files, narrowed by typing, the chosen one sent with Send.
import { _electron as electron, expect } from "@playwright/test";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const root = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  "..",
);
const { friendsBuild } = require("./friends/lock.cjs");
const {
  hiddenElectronApp,
  anyWindowVisible,
  HIDDEN_MAIN,
} = require("./hidden-electron.cjs");
const { readHelperInfo } = require("./friends/host.cjs");
const build = friendsBuild(root);
const addonPath = path.join(
  root,
  "artifacts/friends-native",
  process.arch,
  "friends-link.node",
);
for (const required of [
  build.helperApp,
  addonPath,
  path.join(root, "dist/index.html"),
])
  await fs.access(required).catch(() => {
    throw Error(
      `${required} is missing: run scripts/friends/setup-friends.sh and npm run build first`,
    );
  });
const addon = require(addonPath);
const helper = readHelperInfo(build.helperApp);

const directory = await fs.mkdtemp(path.join(os.tmpdir(), "szf3d-smoke-"));
const homeApp = path.join(directory, "app-home"),
  homePeer = path.join(directory, "peer-home");
// Loopback only, and a type of this run's own, so nothing else on this Mac answers.
const serviceType = `_szf3d${process.pid.toString(36).slice(-6)}._tcp`;
process.env.SZFRIENDS_TEST_SERVICE_TYPE = serviceType;
// macOS lets a bundle browse and advertise only the Bonjour types its Info.plist declares (NSBonjourServices), so
// this run's helpers are an ad-hoc signed copy of the pinned helper that also declares the test type. Its code is
// the pinned build's, byte for byte.
const helperApp = path.join(directory, "helper", "Shenzhen Friends.app");
await fs.mkdir(path.dirname(helperApp));
execFileSync("ditto", [build.helperApp, helperApp]);
execFileSync("/usr/libexec/PlistBuddy", [
  "-c",
  `Add :NSBonjourServices: string ${serviceType}`,
  path.join(helperApp, "Contents/Info.plist"),
]);
execFileSync("codesign", ["--force", "--sign", "-", helperApp], {
  stdio: "pipe",
});
const helperExecutable = path.join(
  helperApp,
  "Contents/MacOS/Shenzhen Friends",
);
const checks = [];
const check = (name) => {
  checks.push(name);
  console.log(`ok ${checks.length} ${name}`);
};

/** The peer: one client of its own helper, held in this process. */
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
  const until = async (condition, what, timeout = 45_000) => {
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
    get welcome() {
      return welcome;
    },
    until,
    send,
    ready: () => until(() => state === "ready", "the peer's helper"),
    async view(type, fields) {
      const { subscription } = await send(type, fields);
      return () => views.get(subscription);
    },
    close() {
      clearInterval(keepAlive);
      client.close();
    },
  };
}

const environment = {
  ...process.env,
  SHENZHEN_3D_FRIENDS_HELPER: helperApp,
  SHENZHEN_3D_FRIENDS_ADDON: addonPath,
  SZFRIENDS_STATE_DIR: homeApp,
};
delete environment.SHENZHEN_3D_DEV_URL;
const peer = createPeer();
peer.client.start();
let application;
const errors = [];
try {
  // Hidden, as every run of this test is: a background-only copy of Electron running the shell behind
  // hidden-hook.cjs, so no window, Dock icon or dialog ever reaches the screen (hidden-electron.cjs).
  hiddenElectronApp(path.join(root, "artifacts/hidden-electron/Electron.app"));
  process.env.ELECTRON_OVERRIDE_DIST_PATH = path.join(
    root,
    "artifacts/hidden-electron",
  );
  application = await electron.launch({
    args: [HIDDEN_MAIN, `--user-data-dir=${path.join(directory, "profile")}`],
    env: environment,
  });
  const page = await application.firstWindow();
  if (await anyWindowVisible(application))
    throw Error("a window is visible: stopping before anything else shows");
  page.on("pageerror", (error) => errors.push(error.message));
  page.on(
    "console",
    (message) => message.type() === "error" && errors.push(message.text()),
  );
  await expect(
    page.locator("header").getByRole("button", { name: /^Open file/ }),
  ).toBeEnabled();
  const button = page.locator('[data-szfriends="button"]');
  await expect(button).toBeVisible({ timeout: 30_000 });
  await peer.ready();
  const strings = peer.welcome.strings;
  await expect(button).toHaveAttribute("aria-label", strings.button_label);
  check(
    "Friends attaches after first paint and the button reads the helper's catalog",
  );

  await peer.send("set_name", { name: "Bo" });
  await peer.send("activate");
  await button.click();
  const panel = page.locator('[data-szfriends="dropdown"]');
  await expect(panel).toBeVisible();
  const prompt = panel.locator(".szf-name-prompt input");
  await prompt.fill("Ada");
  await prompt.press("Enter");
  await expect(panel.locator(".szf-footer-name")).toHaveText("Ada");
  check("a fresh identity names itself from the list's prompt");

  // Ada makes herself visible from the Nearby tab; Bo finds her and asks to be friends.
  await panel.getByRole("tab", { name: strings.tab_nearby }).click();
  await panel.locator(".szf-visibility .szf-button").click();
  await expect(panel.locator(".szf-countdown")).toBeVisible({
    timeout: 30_000,
  });
  const peerNearby = await peer.view("subscribe", { view: "nearby" });
  const ada = await peer.until(
    () =>
      peerNearby()?.people.find(
        (person) => person.title === "Ada" && person.nearby_id,
      ),
    "Ada in Nearby",
    60_000,
  );
  await peer.send("send_request", { nearby_id: ada.nearby_id });
  check("Make myself visible works, and the peer finds Ada over loopback");

  await panel.getByRole("tab", { name: strings.tab_friends }).click();
  const row = panel.locator(".szf-row", { hasText: "Bo" });
  await expect(row.locator(".szf-row-action.accept")).toBeVisible({
    timeout: 60_000,
  });
  await expect(button.locator(".friends-badge")).toHaveText("1");
  await row.locator(".szf-row-action.accept").click();
  const peerList = await peer.view("subscribe", { view: "list" });
  const request = await peer.until(
    () =>
      peerList()?.rows.find(
        (candidate) =>
          candidate.title === "Ada" &&
          !candidate.waiting &&
          candidate.drop_label,
      ),
    "Ada as a friend",
    60_000,
  );
  await expect(row.locator(".szf-route")).toBeVisible({ timeout: 30_000 });
  check(
    "Accept on the request's row makes them friends, and the row shows how Bo is connected",
  );

  await row.locator(".szf-row-main").click();
  const editor = panel.locator(".szf-editor");
  await expect(editor).toBeVisible();
  await editor.click();
  await page.keyboard.type("Hello from Shenzhen 3D");
  await page.keyboard.press("Enter");
  const peerConversation = await peer.view("open_conversation", {
    conversation_id: request.conversation_id,
  });
  await peer.until(
    () =>
      peerConversation()?.items.some(
        (item) =>
          item.kind === "message" && item.text === "Hello from Shenzhen 3D",
      ),
    "Ada's message",
  );
  await peer.send("send_message", {
    conversation_id: request.conversation_id,
    text: "Hi Ada",
    client_token: "smoke-message-0000000000000001",
  });
  await expect(
    panel.locator(".szf-message.in", { hasText: "Hi Ada" }),
  ).toBeVisible({ timeout: 30_000 });
  check("messages go both ways");

  // A drawing the viewer opens; the peer's Mac makes its preview, which shows before anyone accepts.
  const outgoing = path.join(directory, "outgoing");
  await fs.mkdir(outgoing);
  const drawing = path.join(outgoing, "bracket.svg");
  await fs.copyFile(
    path.join(root, "tests/fixtures/formats/drawing.svg"),
    drawing,
  );
  await peer.send("send_files", {
    conversation_id: request.conversation_id,
    files: [{ path: drawing }],
    client_token: "smoke-files-00000000000000000001",
  });
  const offer = panel.locator(".szf-transfer.in", { hasText: "bracket.svg" });
  await expect(offer).toBeVisible({ timeout: 30_000 });
  await expect(offer.locator("img.szf-thumbnail")).toBeVisible({
    timeout: 30_000,
  });
  check("an offer shows the sender's preview before it is accepted");

  await offer.locator(".szf-button.primary").first().click();
  // The received file's actions come from the helper: Open for the formats Shenzhen 3D opens.
  const actions = offer.locator(".szf-button");
  await expect
    .poll(async () => (await actions.allInnerTexts()).join("|"), {
      timeout: 60_000,
    })
    .toMatch(/Open/)
    .catch(async (error) => {
      console.error("the received offer shows:", await offer.innerText());
      console.error(
        "the panel says:",
        await panel.locator(".szf-notice, .szf-connection").allInnerTexts(),
      );
      throw error;
    });
  await offer.locator(".szf-button", { hasText: /^Open$/ }).click();
  await expect(page.locator(".document-title")).toContainText("bracket", {
    timeout: 60_000,
  });
  check("Accept, then Open shows the received drawing in the viewer");

  // A file dropped on the chat: a real File from the file chooser, so the bridge learns its path as from Finder.
  await button.click();
  if (!(await panel.isVisible())) await button.click();
  await expect(panel.locator(".szf-history")).toBeVisible();
  const mesh = path.join(outgoing, "triangle.stl");
  await fs.copyFile(
    path.join(root, "tests/fixtures/formats/triangle.stl"),
    mesh,
  );
  const chooser = await page.evaluateHandle(() => {
    const input = document.createElement("input");
    input.type = "file";
    input.style.display = "none";
    document.body.append(input);
    return input;
  });
  await chooser.asElement().setInputFiles(mesh);
  await page.evaluate((input) => {
    const transfer = new DataTransfer();
    transfer.items.add(input.files[0]);
    const target = document.querySelector(".szf-history");
    for (const type of ["dragenter", "dragover", "drop"])
      target.dispatchEvent(
        new DragEvent(type, {
          dataTransfer: transfer,
          bubbles: true,
          cancelable: true,
        }),
      );
    input.remove();
  }, chooser);
  await peer.until(
    () =>
      peerConversation()?.items.some(
        (item) =>
          item.kind === "transfer" && item.file?.name === "triangle.stl",
      ),
    "the dropped file's offer",
  );
  check("a file dropped on the chat is offered at once");

  // The open model as a project: Send project to a friend, then the friend's row.
  await page.keyboard.press("Escape");
  await page
    .locator("header")
    .getByRole("button", { name: "Send project to a friend" })
    .click();
  await expect(panel.locator(".szf-outgoing")).toContainText("bracket.sz3d", {
    timeout: 30_000,
  });
  await panel
    .locator(".szf-row", { hasText: "Bo" })
    .locator(".szf-row-main")
    .click();
  await peer.until(
    () =>
      peerConversation()?.items.some(
        (item) =>
          item.kind === "transfer" && item.file?.name === "bracket.sz3d",
      ),
    "the project's offer",
  );
  check("Send project to a friend offers the open model as a .sz3d");

  // Download links need the Friends server, which this run never reaches: the helper announces no `links`, so File ▸
  // Copy Download Link is in the menu but hidden, and the header offers none.
  expect(
    await application.evaluate(({ Menu }) => {
      const item = Menu.getApplicationMenu()?.getMenuItemById(
        "friends-copy-download-link",
      );
      return (
        item && { visible: item.visible, choices: item.submenu.items.length }
      );
    }),
  ).toEqual({ visible: false, choices: 3 });
  await expect(
    page.locator("header").getByRole("button", { name: "Copy Download Link" }),
  ).toHaveCount(0);
  check("Copy Download Link stays hidden while the helper offers no links");

  // `#` in the composer lists the recent files: the received drawing opened above, and a mesh opened now from the
  // app's Open file. Typing narrows the list; choosing one attaches it as a dropped file is, and Send offers it.
  await page.keyboard.press("Escape");
  const recentMesh = path.join(outgoing, "gear-plate.stl");
  await fs.copyFile(
    path.join(root, "tests/fixtures/formats/triangle.stl"),
    recentMesh,
  );
  await page.locator("input[type=file]").setInputFiles(recentMesh);
  await expect(page.locator(".document-title")).toContainText("gear-plate", {
    timeout: 60_000,
  });
  await button.click();
  if (!(await panel.isVisible())) await button.click();
  await expect(
    panel.locator(".szf-editor, .szf-row-main, .szf-history").first(),
  ).toBeVisible();
  if (!(await panel.locator(".szf-editor").isVisible()))
    await panel
      .locator(".szf-row", { hasText: "Bo" })
      .locator(".szf-row-main")
      .click();
  await editor.click();
  await page.keyboard.type("#");
  const picker = panel.locator(".szf-picker");
  await expect(picker).toBeVisible();
  const options = picker.getByRole("option");
  await expect(options.filter({ hasText: "gear-plate.stl" })).toContainText(
    "Opened just now",
  );
  await expect(options.filter({ hasText: "bracket.svg" })).toContainText("SVG");
  await expect(panel.locator(".szf-picker-hint")).toHaveText(
    "Attach the open model or a recent file",
  );
  if (process.env.SZF3D_SMOKE_SHOTS)
    await page.screenshot({
      path: path.join(process.env.SZF3D_SMOKE_SHOTS, "electron-recents.png"),
    });
  check("# lists the recent files with their kind and when they were opened");
  await page.keyboard.type("brack");
  await expect(options).toHaveCount(1);
  await expect(options).toContainText("bracket.svg");
  check("typing after # narrows the list");
  await page.keyboard.press("Enter");
  await expect(panel.locator(".szf-chip.attachment")).toHaveText(
    /bracket\.svg/,
  );
  await page.keyboard.press("Enter");
  const recentOffer = await peer.until(
    () =>
      peerConversation()?.items.find(
        (item) =>
          item.kind === "transfer" &&
          item.direction === "in" &&
          item.file?.name === "bracket.svg",
      ),
    "the recent file's offer",
  );
  await peer.send("accept_offer", { transfer_id: recentOffer.transfer_id });
  const recentReceived = await peer.until(
    () =>
      peerConversation()?.items.find(
        (item) =>
          item.transfer_id === recentOffer.transfer_id &&
          item.state === "received",
      ),
    "the recent file received",
    60_000,
  );
  const recentCopy = recentReceived.actions?.find(
    (action) => typeof action.path === "string",
  )?.path;
  expect(await fs.readFile(recentCopy)).toEqual(await fs.readFile(drawing));
  check("choosing a recent file and pressing Send gives the friend that file");

  // The badge counts what waits for an answer, with the dropdown closed.
  await page.keyboard.press("Escape");
  const waiting = path.join(outgoing, "panel.obj");
  await fs.copyFile(
    path.join(root, "tests/fixtures/formats/panel.obj"),
    waiting,
  );
  await peer.send("send_files", {
    conversation_id: request.conversation_id,
    files: [{ path: waiting }],
    client_token: "smoke-files-00000000000000000002",
  });
  await expect(button.locator(".friends-badge")).toHaveText("1", {
    timeout: 30_000,
  });
  check("the badge counts the waiting offer");

  expect(errors).toEqual([]);
  check("no page errors");
} finally {
  await application?.close().catch(() => {});
  peer.close();
  // Both helpers exit by themselves 10 s after their last client (PROTOCOL.md § Lifecycle); wait for this run's.
  const ours = () => {
    try {
      return execFileSync("pgrep", ["-f", helperExecutable], {
        encoding: "utf8",
      }).trim();
    } catch {
      return "";
    }
  };
  for (let i = 0; i < 30 && ours(); i++)
    await new Promise((resolve) => setTimeout(resolve, 1000));
  const left = ours();
  if (process.env.SZF3D_SMOKE_KEEP) console.error(`kept ${directory}`);
  else await fs.rm(directory, { recursive: true, force: true });
  if (left)
    console.error(`helpers still running from ${helperExecutable}: ${left}`);
}
console.log(JSON.stringify({ friendsSmoke: "passed", checks }, null, 2));
