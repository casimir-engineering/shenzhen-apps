// The app as the Electron tests run it, with nothing on the screen of the person running them: no Dock icon, windows
// that never come to the front (fully transparent, not focused, clicks pass through), and errors printed rather than
// shown in a dialog. Pages still load, paint and take the keys the tests press.
//
//   electron.launch({ args: ["electron/test-hidden.cjs", ...] })   instead of electron/main.cjs
const { app, BrowserWindow, dialog } = require("electron");

if (process.platform === "darwin") app.setActivationPolicy?.("accessory");
dialog.showErrorBox = (title, content) =>
  console.error(`[dialog not shown] ${title}: ${content}`);
// An uncaught exception in the main process would open Electron's error dialog: print it and end the run instead.
process.on("uncaughtException", (error) => {
  console.error("[main process] uncaught exception:", error);
  app.exit(1);
});
BrowserWindow.prototype.show = function show() {
  this.setOpacity(0);
  this.setIgnoreMouseEvents(true);
  this.showInactive();
};
BrowserWindow.prototype.focus = function focus() {};
app.focus = () => {};

require("./main.cjs");
