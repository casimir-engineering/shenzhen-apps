// Shenzhen Friends in Shenzhen 3D's main process: the helper link, the IPC bridge the panel uses, and the files the
// panel shows. main.cjs requires this file only once the first window has painted or the panel asks for it, which it
// does only after its own first paint (docs/FRIENDS.md § Startup), so nothing here runs on the launch path.
//
// One client per app, shared by every window (router.cjs). The client library spawns or hands over to the
// embedded helper by itself (connect-or-spawn, build numbers in hello; PROTOCOL.md § Lifecycle). The renderer
// reaches the helper only through `shenzhen-friends` invocations, each checked here (validate.cjs).
const fs = require("node:fs");
const fsp = require("node:fs/promises");
const path = require("node:path");
const crypto = require("node:crypto");
const { FriendsRouter, HOST, notReady } = require("./router.cjs");
const {
  validateIntent,
  FriendsFieldError,
  externalURL,
  settingsURL,
  linkPayload,
  plainPath,
} = require("./validate.cjs");
const {
  readHelperImage,
  readHelperInfo,
  createAnimalSet,
  classifyPath,
  openablePaths,
} = require("./files.cjs");
const { HELPER_NAME } = require("./lock.cjs");
const { createShareMenu } = require("./share-menu.cjs");
const { createViewMenu } = require("./view-menu.cjs");

const EVENT = "shenzhen-friends-event";
// What Shenzhen 3D's panel shows and does (PROTOCOL.md § Capabilities): `#` offers the open model, files may be
// dropped, and `@` mentions friends. No assistant, no global search.
const CAPABILITIES = ["attach.items", "drop.files", "mentions"];
const STAGED_DAYS = 31;
const MAX_STAGED_BYTES = 2 * 1024 * 1024 * 1024;
const MAX_OFFERED_FILES = 4096;

/**
 * Where this run's Friends pieces are, or null when Friends is not offered. A packaged app carries the helper in
 * Contents/Helpers and the animal set in Resources/Friends. A development run offers Friends only when it is told
 * which helper to use and given a Friends home of its own (SZFRIENDS_STATE_DIR), so trying the panel never reaches
 * the person's real Friends identity or a helper another app is running.
 */
function locateFriends({
  app,
  env = process.env,
  platform = process.platform,
  resourcesPath = process.resourcesPath,
}) {
  if (platform !== "darwin") return null;
  if (app.isPackaged) {
    const helperApp = path.join(
      resourcesPath,
      "..",
      "Helpers",
      `${HELPER_NAME}.app`,
    );
    return {
      helperApp,
      helperExecutable: path.join(helperApp, "Contents/MacOS", HELPER_NAME),
      animals: path.join(resourcesPath, "Friends/animals"),
      addon: path.join(__dirname, "../native/friends-link.node"),
    };
  }
  const helperApp = env.SHENZHEN_3D_FRIENDS_HELPER;
  const home = env.SZFRIENDS_STATE_DIR;
  if (!helperApp || !path.isAbsolute(helperApp) || !helperApp.endsWith(".app"))
    return null;
  if (!home || !path.isAbsolute(home)) return null;
  return {
    helperApp,
    helperExecutable: path.join(helperApp, "Contents/MacOS", HELPER_NAME),
    // A standalone helper bundle carries the set where the helper itself reads it.
    animals:
      env.SHENZHEN_3D_FRIENDS_ANIMALS ||
      path.join(helperApp, "Contents/Resources/Friends/animals"),
    addon:
      env.SHENZHEN_3D_FRIENDS_ADDON ||
      path.join(
        __dirname,
        "../../artifacts/friends-native",
        process.arch,
        "friends-link.node",
      ),
  };
}

function createFriendsHost({
  app,
  BrowserWindow,
  Menu,
  MenuItem,
  shell,
  trusted,
  openFormats,
  openFiles,
  env = process.env,
  platform = process.platform,
  loadAddon = require,
  located = locateFriends({ app, env, platform }),
}) {
  const settingsFile = () => path.join(app.getPath("userData"), "friends.json");
  const outgoing = () =>
    path.join(app.getPath("userData"), "Friends", "Outgoing");
  const windows = new Map(); // webContents id -> webContents that joined
  const animals = located ? createAnimalSet(located.animals) : null;
  let enabled = null; // read once, after first paint
  let addon, client, stateDir, attachTimer, pendingLink;
  let state = "idle",
    stateText = "";
  let painted = false;
  // Received files the helper offered to open. Open in the viewer opens only these, so a page cannot ask the main
  // process to load any other file on the disk.
  const offered = new Set();
  const offer = (frame) => {
    for (const file of openablePaths(frame.data)) {
      offered.delete(file);
      offered.add(file);
      if (offered.size > MAX_OFFERED_FILES)
        offered.delete(offered.values().next().value);
    }
  };

  const deliver = (owner, event) => {
    const contents = windows.get(owner);
    if (contents && !contents.isDestroyed()) contents.send(EVENT, event);
  };
  const broadcast = (event) => {
    for (const contents of windows.values())
      if (!contents.isDestroyed()) contents.send(EVENT, event);
  };
  const router = new FriendsRouter({ deliver, broadcast });
  const focusedId = () => BrowserWindow.getFocusedWindow?.()?.webContents?.id;
  // File ▸ Copy Download Link, while the helper announces `links` (share-menu.cjs).
  const shareMenu = createShareMenu({
    Menu: located ? Menu : undefined,
    focusedId,
    choose: (owner, days) =>
      deliver(owner, { kind: "copy_download_link", days }),
  });
  shareMenu.install();
  // View ▸ Friends (⌘J), while Friends runs and is on (view-menu.cjs).
  const viewMenu = createViewMenu({
    Menu: located ? Menu : undefined,
    MenuItem,
    toggle: (window) => {
      const owner = window ?? focusedId();
      if (owner !== undefined) deliver(owner, { kind: "toggle" });
    },
  });
  viewMenu.install();
  app.on?.("browser-window-focus", shareMenu.refresh);
  app.on?.("browser-window-blur", shareMenu.refresh);

  function status() {
    const welcome = router.welcome;
    return {
      available: Boolean(located),
      enabled: enabled !== false,
      attached: Boolean(client),
      state,
      text: stateText,
      strings: welcome?.strings ?? null,
      capabilities: welcome?.capabilities ?? [],
      limits: welcome?.limits ?? null,
      badge: router.badge,
    };
  }
  const announce = () => {
    viewMenu.setShown(Boolean(located) && enabled !== false);
    shareMenu.setOffers(
      Boolean(client) &&
        state === "ready" &&
        Boolean(router.welcome?.capabilities?.includes?.("links")),
    );
    broadcast({ kind: "status", status: status() });
  };

  async function readEnabled() {
    if (enabled !== null) return enabled;
    try {
      const value = JSON.parse(await fsp.readFile(settingsFile(), "utf8"));
      enabled = value?.enabled !== false;
    } catch {
      enabled = true; // Enable Shenzhen Friends is on by default.
    }
    return enabled;
  }

  function onEvents(events) {
    try {
      for (const event of events) {
        if (event.type === "frame") {
          let frame;
          try {
            frame = JSON.parse(event.json);
          } catch {
            continue;
          }
          if (frame?.type === "snapshot") offer(frame);
          router.frame(frame);
        } else if (event.type === "state") {
          state = event.state;
          router.connectionChanged(state);
          if (state === "ready") sendFromHost("subscribe", { view: "badge" });
        }
      }
      if (typeof events.stateText === "string") stateText = events.stateText;
      if (events.some((event) => event.type === "state")) {
        announce();
        if (state === "ready") offerPendingLink();
      }
    } catch (error) {
      console.error("Friends:", error);
    }
  }

  function sendFromHost(type, fields) {
    if (!client) return;
    const result = client.send(type, JSON.stringify(fields));
    if (result.status === "ok") void router.sent(result.id, HOST, type, fields);
  }

  async function attach() {
    attachTimer = undefined;
    if (!located || client || !(await readEnabled()) || client) return;
    try {
      addon ??= loadAddon(located.addon);
      // The app's own signing policy, read off the main thread, before the first connect (ADR 0002).
      await addon.prepare();
      if (client || !enabled) return;
      stateDir = addon.defaultStateDir();
      const helper = readHelperInfo(located.helperApp);
      client = addon.createClient(
        {
          helperPath: fs.existsSync(located.helperExecutable)
            ? located.helperExecutable
            : undefined,
          helperVersion: helper.version,
          helperBuildNumber: helper.buildNumber,
          appId: "com.shenzhen3d.performance",
          appName: "Shenzhen 3D",
          appVersion: app.getVersion(),
          // Any toolkit name is accepted by the helper; nothing is worded by it.
          toolkit: "electron",
          revealIn: "Finder",
          locale: app.getLocale?.() || "en",
          capabilities: CAPABILITIES,
          openFormats: [...openFormats],
        },
        onEvents,
      );
      client.start();
      announce();
      void sweepOutgoing();
    } catch (error) {
      console.error("Friends could not start:", error);
      client = undefined;
      state = "idle";
      announce();
    }
  }

  function detach(disabling) {
    if (!client) return;
    client.stop(disabling);
    router.stopped();
    client.close();
    client = undefined;
    state = "idle";
    stateText = "";
    announce();
  }

  /** The first window painted a while ago (main.cjs waits): attach now. */
  function firstPaint() {
    if (painted || !located) return;
    painted = true;
    attachTimer = setTimeout(() => void attach(), 0);
    attachTimer.unref?.();
  }

  async function setEnabled(value) {
    enabled = Boolean(value);
    await fsp.mkdir(path.dirname(settingsFile()), { recursive: true });
    await fsp.writeFile(settingsFile(), JSON.stringify({ enabled }) + "\n", {
      mode: 0o600,
    });
    // Turning Friends off tells the helper (`disable`), which exits at once if no other app needs it.
    if (enabled) {
      if (painted) await attach();
    } else detach(true);
    announce();
    return status();
  }

  async function send(owner, type, fields) {
    let json;
    try {
      json = validateIntent(type, fields);
    } catch (error) {
      if (!(error instanceof FriendsFieldError)) throw error;
      return {
        reply: {
          type: "reply",
          re: null,
          ok: false,
          error: {
            code: "invalid_field",
            message: null,
            retryable: false,
            details: { field: error.field },
          },
        },
      };
    }
    if (!client || state !== "ready") return { reply: notReady() };
    if (
      (type === "subscribe" || type === "open_conversation") &&
      !router.mayAddSubscription(owner)
    )
      return {
        reply: {
          type: "reply",
          re: null,
          ok: false,
          error: {
            code: "too_many_subscriptions",
            message: null,
            retryable: false,
            details: {},
          },
        },
      };
    const result = client.send(type, json);
    if (result.status !== "ok") return { reply: notReady() };
    return router.sent(result.id, owner, type, JSON.parse(json));
  }

  function forget(owner) {
    shareMenu.forget(owner);
    if (!windows.delete(owner)) return;
    for (const subscription of router.dropOwner(owner))
      sendFromHost("unsubscribe", { subscription });
  }

  function join(contents) {
    const owner = contents.id;
    if (!windows.has(owner)) {
      windows.set(owner, contents);
      // A reload or navigation starts a new page: the old page's subscriptions go with it.
      const leave = () => forget(owner);
      contents.once("destroyed", leave);
      contents.once("did-start-navigation", (event) => {
        if (event?.isMainFrame !== false && !event?.isSameDocument) leave();
      });
    }
    if (pendingLink && state === "ready") setTimeout(offerPendingLink, 0);
    return status();
  }

  // A Friends link opened in this app (PROTOCOL.md § Links): given to the focused window once Friends is ready.
  function openLink(url) {
    const payload = linkPayload(url);
    if (!payload || !located) return false;
    pendingLink = payload;
    offerPendingLink();
    return true;
  }
  function offerPendingLink() {
    if (!pendingLink || state !== "ready" || !windows.size) return;
    const focused = BrowserWindow.getFocusedWindow?.()?.webContents;
    const target =
      focused && windows.has(focused.id) ? focused : [...windows.values()][0];
    if (!target || target.isDestroyed()) return;
    target.send(EVENT, { kind: "link", payload: pendingLink });
    pendingLink = undefined;
  }

  // The open model as a project file, written where only this app looks, for send_files, `#` or a download link.
  async function stage(name, bytes) {
    if (
      typeof name !== "string" ||
      path.basename(name) !== name ||
      name.startsWith(".") ||
      !/\.sz3d$/i.test(name) ||
      Buffer.byteLength(name) > 200 ||
      name.includes("\0")
    )
      throw Error("Invalid project name");
    if (!(bytes instanceof Uint8Array) || bytes.length > MAX_STAGED_BYTES)
      throw Error("Invalid project");
    const directory = path.join(outgoing(), crypto.randomUUID());
    await fsp.mkdir(directory, { recursive: true, mode: 0o700 });
    const file = path.join(directory, name);
    await fsp.writeFile(file, bytes, { mode: 0o600, flag: "wx" });
    return file;
  }
  // Staged copies stay while a download link may still serve them from the original (no clone possible), the
  // longest a link lives plus a day; older ones go when Friends next attaches.
  async function sweepOutgoing() {
    try {
      const cutoff = Date.now() - STAGED_DAYS * 24 * 3600 * 1000;
      for (const entry of await fsp.readdir(outgoing(), {
        withFileTypes: true,
      })) {
        const directory = path.join(outgoing(), entry.name);
        if (entry.isDirectory() && (await fsp.stat(directory)).mtimeMs < cutoff)
          await fsp.rm(directory, { recursive: true, force: true });
      }
    } catch {}
  }

  async function openReceived(file) {
    if (!plainPath(file) || !offered.has(file)) return false;
    const extension = path.extname(file).slice(1).toLowerCase();
    if (!openFormats.has(extension) || (await classifyPath(file)) !== "file")
      return false;
    openFiles([file]);
    return true;
  }
  async function showFile(file) {
    if (!plainPath(file) || (await classifyPath(file)) === "missing")
      return false;
    shell.showItemInFolder(file);
    return true;
  }

  const methods = {
    join: (event) => join(event.sender),
    status: () => status(),
    send: (event, value) => send(event.sender.id, value?.type, value?.fields),
    setEnabled: (_event, value) => setEnabled(value === true),
    image: (_event, value) =>
      readHelperImage(stateDir, value?.kind, value?.path, {
        width: value?.width,
        height: value?.height,
      }),
    animal: (_event, value) =>
      animals?.animal(value?.set, value?.index) ?? null,
    animals: () => animals?.list() ?? null,
    classify: async (_event, value) =>
      Array.isArray(value) && value.length <= 100
        ? Promise.all(
            value.map((file) =>
              plainPath(file) ? classifyPath(file) : "missing",
            ),
          )
        : [],
    stage: (_event, value) => stage(value?.name, value?.bytes),
    token: () => crypto.randomBytes(16).toString("hex"),
    openFile: (_event, value) => openReceived(value),
    showFile: (_event, value) => showFile(value),
    openSettings: async (_event, value) => {
      const url = settingsURL(value);
      if (url) await shell.openExternal(url);
      return Boolean(url);
    },
    // Whether this window has a model open, for File ▸ Copy Download Link.
    shareable: (event, value) =>
      void shareMenu.setShareable(event.sender.id, value === true),
    openURL: async (_event, value) => {
      const url = externalURL(value);
      if (url) await shell.openExternal(url);
      return Boolean(url);
    },
  };

  /** The `shenzhen-friends` invocation handler: the app's own page only, and only these methods. */
  async function handle(event, method, value) {
    if (
      event.senderFrame !== event.sender.mainFrame ||
      !trusted(event.senderFrame?.url) ||
      typeof method !== "string" ||
      !Object.hasOwn(methods, method)
    )
      throw Error("Friends request is not allowed");
    if (!located && method !== "status" && method !== "join")
      throw Error("Friends is not available");
    return methods[method](event, value);
  }

  return {
    available: Boolean(located),
    handle,
    firstPaint,
    openLink,
    status,
    dispose() {
      clearTimeout(attachTimer);
      app.removeListener?.("browser-window-focus", shareMenu.refresh);
      app.removeListener?.("browser-window-blur", shareMenu.refresh);
      // Quitting is not turning Friends off: the helper keeps serving other apps, and exits on its own when none
      // remains (PROTOCOL.md § Lifecycle).
      detach(false);
    },
  };
}

module.exports = {
  createFriendsHost,
  locateFriends,
  readHelperInfo,
  CAPABILITIES,
};
