const path = require("node:path");
function createScrollSource({
  app,
  windows,
  trusted = () => false,
  platform = process.platform,
  loadNative = require,
  now = Date.now,
  interval = setInterval,
  clear = clearInterval,
}) {
  let native, timer;
  let disposed = false;
  const subscribers = new Set();
  const cleanupHandlers = new Map();
  if (platform === "darwin") {
    try {
      const binary = app.isPackaged
        ? path.join(__dirname, "native/scroll-source.node")
        : path.join(
            __dirname,
            "../artifacts/native-scroll",
            process.arch,
            "scroll-source.node",
          );
      native = loadNative(binary);
      if (!native.start()) native = undefined;
    } catch {
      /* Browser/device heuristic remains available if native input is unavailable. */
    }
  }
  const query = (sender, epochMs) => {
    if (
      disposed ||
      !native ||
      typeof epochMs !== "number" ||
      !Number.isFinite(epochMs) ||
      Math.abs(now() - epochMs) > 2000
    )
      return null;
    if (sender.isDestroyed()) return null;
    const window = windows.fromWebContents(sender);
    if (!window || window.isDestroyed()) return null;
    return native.source(epochMs, window.getNativeWindowHandle());
  };
  const stopTimer = () => {
    if (timer) clear(timer);
    timer = undefined;
  };
  const unsubscribe = (sender) => {
    subscribers.delete(sender);
    const handlers = cleanupHandlers.get(sender);
    if (handlers) {
      sender.removeListener("destroyed", handlers.closed);
      sender.removeListener("render-process-gone", handlers.closed);
      sender.removeListener("did-start-navigation", handlers.navigation);
      cleanupHandlers.delete(sender);
    }
    if (!subscribers.size) stopTimer();
  };
  const poll = () => {
    for (const sender of subscribers) {
      if (sender.isDestroyed()) {
        unsubscribe(sender);
        continue;
      }
      const window = windows.fromWebContents(sender);
      if (
        sender.isDestroyed() ||
        !window ||
        window.isDestroyed() ||
        !trusted(sender.getURL())
      ) {
        unsubscribe(sender);
        continue;
      }
      try {
        const records = native.drainRotations(window.getNativeWindowHandle());
        const zoom = sender.getZoomFactor();
        if (!Number.isFinite(zoom) || zoom <= 0) continue;
        const [width, height] = window.getContentSize();
        for (const record of Array.isArray(records)
          ? records.slice(0, 128)
          : []) {
          if (
            !record ||
            ![
              record.degrees,
              record.clientX,
              record.clientY,
              record.epochMs,
            ].every(Number.isFinite) ||
            record.degrees === 0 ||
            Math.abs(record.degrees) > 180 ||
            record.clientX < 0 ||
            record.clientY < 0 ||
            record.clientX >= width ||
            record.clientY >= height ||
            now() - record.epochMs > 2000 ||
            record.epochMs > now() + 20
          )
            continue;
          sender.send("shenzhen-rotate", {
            degrees: record.degrees,
            clientX: record.clientX / zoom,
            clientY: record.clientY / zoom,
            epochMs: record.epochMs,
          });
        }
      } catch {
        /* A closing native window or unavailable bridge must not break input. */
      }
    }
    if (!subscribers.size) stopTimer();
  };
  query.subscribeRotate = (sender, enabled) => {
    if (disposed || !native?.drainRotations || typeof enabled !== "boolean")
      return false;
    if (sender.isDestroyed()) return false;
    const window = windows.fromWebContents(sender);
    if (
      !window ||
      window.isDestroyed() ||
      sender.isDestroyed() ||
      !trusted(sender.getURL())
    )
      return false;
    if (enabled) {
      if (!subscribers.has(sender)) {
        subscribers.add(sender);
        const closed = () => unsubscribe(sender);
        const navigation = (_event, _url, inPlace, mainFrame) => {
          if (mainFrame && !inPlace) unsubscribe(sender);
        };
        cleanupHandlers.set(sender, { closed, navigation });
        sender.once("destroyed", closed);
        sender.once("render-process-gone", closed);
        sender.on("did-start-navigation", navigation);
        // Never deliver a twist recorded before this subscription/view existed.
        native.drainRotations(window.getNativeWindowHandle());
      }
      if (!timer) {
        timer = interval(poll, 16);
        timer.unref?.();
      }
    } else {
      unsubscribe(sender);
    }
    return true;
  };
  query.dispose = () => {
    disposed = true;
    stopTimer();
    for (const sender of subscribers) unsubscribe(sender);
  };
  return query;
}
module.exports = { createScrollSource };
