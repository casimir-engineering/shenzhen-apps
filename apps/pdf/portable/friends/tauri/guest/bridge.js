// tauri-plugin-szfriends' guest script: window.shenzhenFriends, the FriendsBridge the Electron preload gives
// Shenzhen 3D's Mac app (src/friends/bridge.ts), so one React UI serves both shells (ADR 0015 § 4). It runs before
// the page's own scripts in the windows the plugin serves, and does nothing until the page calls join() after its
// first paint. Every call is checked again in Rust, and the plugin's commands are granted to the main window only.
(() => {
  "use strict";
  const WINDOWS = __SZFRIENDS_WINDOWS__;
  // Phones only: the most the panel stages of one dropped file (0 on desktops, which send files from their paths).
  const STAGED_DROP_LIMIT = __SZFRIENDS_STAGED_DROP_LIMIT__;
  // A Mac: a drop's files are read only for a drag the system saw over this window, so the page says when one is.
  const DRAG_OVER = __SZFRIENDS_DRAG_OVER__;
  const internals = window.__TAURI_INTERNALS__;
  const label = internals?.metadata?.currentWebview?.label;
  if (!internals || !WINDOWS.includes(label) || window.shenzhenFriends) return;

  const invoke = (command, args, options) =>
    internals.invoke(`plugin:szfriends|${command}`, args, options);
  const listeners = new Set();

  const dispatch = (event) => {
    if (!event || typeof event !== "object" || typeof event.kind !== "string") return;
    for (const listener of listeners) {
      try {
        listener(event);
      } catch {
        /* One panel's error must not stop another listener. */
      }
    }
  };

  // A Tauri channel, as @tauri-apps/api's Channel makes one: messages carry an index and are delivered in order.
  const makeChannel = () => {
    let next = 0;
    const waiting = new Map();
    const id = internals.transformCallback((raw) => {
      if (!raw || typeof raw !== "object" || "end" in raw) return;
      waiting.set(raw.index, raw.message);
      while (waiting.has(next)) {
        const message = waiting.get(next);
        waiting.delete(next);
        next++;
        dispatch(message);
      }
    });
    return { toJSON: () => `__CHANNEL__:${id}` };
  };

  // Image replies are a small JSON header and the image's bytes, so no byte becomes a JSON number on the way.
  const unpackImage = (buffer) => {
    if (!(buffer instanceof ArrayBuffer) || buffer.byteLength < 4) return null;
    const view = new DataView(buffer);
    const length = view.getUint32(0, false);
    if (length > 1024 || 4 + length > buffer.byteLength) return null;
    let header;
    try {
      header = JSON.parse(new TextDecoder().decode(new Uint8Array(buffer, 4, length)));
    } catch {
      return null;
    }
    if (!header || typeof header.type !== "string") return null;
    return {
      type: header.type,
      width: header.width,
      height: header.height,
      bytes: new Uint8Array(buffer, 4 + length),
    };
  };

  if (DRAG_OVER) {
    let last = 0;
    const over = (event) => {
      const now = Date.now();
      if (now - last < 200 || !Array.from(event.dataTransfer?.types ?? []).includes("Files")) return;
      last = now;
      invoke("drag_over").catch(() => {});
    };
    window.addEventListener("dragenter", over, true);
    window.addEventListener("dragover", over, true);
  }

  const bridge = {
    // A new channel each time: the plugin takes the latest one for this window and numbers its messages from 0, so
    // a channel joined again would hold every later event back until the count came round to where it was.
    join: () => invoke("join", { events: makeChannel() }),
    status: () => invoke("status"),
    subscribe: (listener) => {
      if (typeof listener !== "function") return () => {};
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    send: (type, fields) => invoke("send", { kind: type, fields: fields ?? null }),
    setEnabled: (enabled) => invoke("set_enabled", { enabled: enabled === true }),
    image: async (kind, path, width, height) =>
      unpackImage(await invoke("image", { kind, path, width: width ?? null, height: height ?? null })),
    animal: (set, index) => invoke("animal", { set, index }),
    animals: () => invoke("animals"),
    // Paths only from the system's own report of a drop on this window, and only when every file matches it by name
    // and size; otherwise none. On Windows the files themselves go to WebView2 first, which knows their paths.
    pathsForFiles: async (files) => {
      const list = Array.from(files ?? []);
      const none = list.map(() => null);
      if (!list.length || STAGED_DROP_LIMIT > 0) return none;
      let ticket = null;
      const webview = window.chrome?.webview;
      if (typeof webview?.postMessageWithAdditionalObjects === "function") {
        const random = crypto.getRandomValues(new Uint8Array(12));
        ticket = Array.from(random, (b) => b.toString(16).padStart(2, "0")).join("");
        try {
          webview.postMessageWithAdditionalObjects(`szfriends-drop:${ticket}`, list);
        } catch {
          ticket = null;
        }
      }
      const wanted = list.map((file) => ({ name: String(file?.name ?? ""), size: Number(file?.size ?? -1) }));
      if (wanted.some((file) => !file.name || !(file.size >= 0))) return none;
      const paths = await invoke("drop_paths", { files: wanted, ticket }).catch(() => null);
      return Array.isArray(paths) && paths.length === list.length ? paths : none;
    },
    // Phones: the most the panel stages of one dropped file. Absent on desktops, where a file without a path
    // cannot be sent.
    ...(STAGED_DROP_LIMIT > 0 ? { stagedDropLimit: STAGED_DROP_LIMIT } : {}),
    classify: (paths) => invoke("classify", { paths }),
    stage: (name, bytes) =>
      invoke("stage", bytes instanceof Uint8Array ? bytes : new Uint8Array(0), {
        headers: { "szfriends-name": encodeURIComponent(String(name)) },
      }),
    token: () => invoke("token"),
    openFile: (path) => invoke("open_file", { path }),
    showFile: (path) => invoke("show_file", { path }),
    openSettings: (target) => invoke("open_settings", { target }),
    openURL: (url) => invoke("open_url", { url }),
    shareable: (value) => invoke("shareable", { value: value === true }),
  };
  Object.defineProperty(window, "shenzhenFriends", {
    value: Object.freeze(bridge),
    enumerable: false,
    configurable: false,
    writable: false,
  });
})();
