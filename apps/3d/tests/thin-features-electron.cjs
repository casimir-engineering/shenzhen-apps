// Electron main for tests/thin-features-browser.mjs: one window, kept hidden by electron/hidden-hook.cjs, showing the
// test page named by THIN_FEATURES_URL (a loopback Vite server) in the same Chromium and GPU path as the app.
require("../electron/hidden-hook.cjs");
const { app, BrowserWindow } = require("electron");

const url = new URL(process.env.THIN_FEATURES_URL);
if (url.protocol !== "http:" || url.hostname !== "127.0.0.1") throw Error("loopback test pages only");
app.whenReady().then(() => {
  const window = new BrowserWindow({
    width: Number(process.env.THIN_FEATURES_WIDTH) || 960,
    height: Number(process.env.THIN_FEATURES_HEIGHT) || 640,
    useContentSize: true,
    webPreferences: { sandbox: true, contextIsolation: true, backgroundThrottling: false },
  });
  window.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  void window.loadURL(url.href);
});
app.on("window-all-closed", () => app.quit());
