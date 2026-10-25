// Required first by the main script of a test run's Electron (hidden-electron.cjs): nothing the app does may reach the
// screen. Every BrowserWindow is created hidden and is never shown, focused or raised, and dialogs are
// answered here (cancelled, or their cancel button) and written to stderr instead of appearing. The renderer still
// lays out and paints offscreen, so Playwright reads and drives the page as usual. Does nothing outside Electron's
// main process. The patches are made on the app's first require("electron"), once, and every later require gets the
// same wrapped module, whose BrowserWindow is the hidden one (the module's own properties cannot be redefined).
if (process.versions.electron && process.type === "browser") {
  const Module = require("node:module");
  const load = Module._load;
  let wrapped;
  Module._load = function (request, ...rest) {
    const exported = load.call(this, request, ...rest);
    if (request !== "electron" || !exported?.app) return exported;
    wrapped ??= hide(exported);
    return wrapped;
  };
}

function hide(electron) {
  const { BrowserWindow, BaseWindow, app, dialog } = electron;
  const quiet = () => {};
  for (const Window of [BaseWindow, BrowserWindow])
    for (const name of [
      "show",
      "showInactive",
      "focus",
      "moveTop",
      "maximize",
      "setFullScreen",
      "setSimpleFullScreen",
      "flashFrame",
      "setAlwaysOnTop",
    ])
      if (Window?.prototype) Window.prototype[name] = quiet;
  app.focus = quiet;
  app.show = quiet;
  app.whenReady().then(() => app.dock?.hide());
  // Created hidden whatever the options say; paintWhenInitiallyHidden keeps the page painting. Named BrowserWindow:
  // Electron's BrowserWindow.getAllWindows() and getFocusedWindow() keep only windows whose constructor has that name.
  const HiddenBrowserWindow = class BrowserWindow extends electron.BrowserWindow {
    constructor(options = {}) {
      super({ ...options, show: false, paintWhenInitiallyHidden: true });
    }
  };
  const note = (what, options) =>
    console.error(
      `[hidden] ${what}: ${JSON.stringify(options?.message ?? options?.title ?? options ?? "")}`,
    );
  const answer = (options) => ({
    response: Number.isInteger(options?.cancelId) ? options.cancelId : 0,
    checkboxChecked: false,
  });
  // The window argument is optional in every dialog call.
  const last = (args) => args[args.length - 1];
  dialog.showErrorBox = (title, content) => note("error box", { title, message: content });
  dialog.showMessageBox = async (...args) => (note("message box", last(args)), answer(last(args)));
  dialog.showMessageBoxSync = (...args) => (note("message box", last(args)), answer(last(args)).response);
  // A run that picks files (friends-smoke.mjs's Attach files) names them in SHENZHEN_HIDDEN_OPEN_FILES, a JSON list of
  // absolute paths: an open dialog for files then answers as if the person had chosen them, and is cancelled
  // otherwise.
  const chosenFiles = () => {
    try {
      const paths = JSON.parse(process.env.SHENZHEN_HIDDEN_OPEN_FILES ?? "[]");
      return Array.isArray(paths) ? paths.filter((p) => typeof p === "string" && p.startsWith("/")) : [];
    } catch {
      return [];
    }
  };
  dialog.showOpenDialog = async (...args) => {
    const options = last(args);
    note("open dialog", options);
    const files = options?.properties?.includes?.("openFile") ? chosenFiles() : [];
    return files.length ? { canceled: false, filePaths: files } : { canceled: true, filePaths: [] };
  };
  dialog.showOpenDialogSync = (...args) => (note("open dialog", last(args)), undefined);
  dialog.showSaveDialog = async (...args) => (note("save dialog", last(args)), { canceled: true, filePath: "" });
  dialog.showSaveDialogSync = (...args) => (note("save dialog", last(args)), undefined);
  dialog.showCertificateTrustDialog = async (...args) => note("certificate dialog", last(args));
  const module = Object.create(Object.getPrototypeOf(electron));
  for (const key of Reflect.ownKeys(electron))
    Object.defineProperty(module, key, {
      enumerable: true,
      configurable: true,
      get: () => (key === "BrowserWindow" ? HiddenBrowserWindow : electron[key]),
    });
  return module;
}
