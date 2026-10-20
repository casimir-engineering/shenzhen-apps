// Electron for tests that must never show anything on the screen of the Mac they run on.
//
// The tests drive the real shell with Playwright, but the window must stay off screen, out of the Dock and away from
// the keyboard: someone may be typing in another app while they run. Two halves, both needed:
//
//   hiddenElectronApp(target)  a copy of node_modules/electron's Electron.app (an APFS clone where the disk allows,
//                              so it costs no space) whose Info.plist says LSBackgroundOnly: macOS gives it no Dock
//                              icon and no menu bar, and never makes it the active app. Signed again ad hoc, since the
//                              plist is part of the signature. Returns its executable.
//   hidden-hook.cjs            required first thing by the main script the copy runs: every window is created hidden
//                              and is never shown or focused, and dialogs are answered by the hook instead of
//                              appearing. A development run starts electron/hidden-main.cjs (the hook, then main.cjs);
//                              a packaged one names its own main. Never NODE_OPTIONS: Playwright removes it from the
//                              environment of the Electron it launches.
//
// LSBackgroundOnly alone does not keep a window off the screen, and the hook alone leaves a Dock icon: use both, and
// check with anyWindowVisible() once the app is up.
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const HIDDEN_HOOK = path.join(__dirname, "hidden-hook.cjs");
const HIDDEN_MAIN = path.join(__dirname, "hidden-main.cjs");

function electronVersion() {
  return require("electron/package.json").version;
}

/** The Electron.app the electron package installed. */
function sourceElectronApp() {
  const executable = require("electron"); // .../Electron.app/Contents/MacOS/Electron
  return path.resolve(executable, "../../..");
}

/**
 * A hidden copy of Electron.app at `target` (any name ending in .app). With `prepare(appPath)` the caller adds what it
 * needs inside the bundle (an app, an embedded helper) before it is signed. Returns the executable's path.
 */
function hiddenElectronApp(target, { prepare, executableName } = {}) {
  if (process.platform !== "darwin")
    throw Error("hidden Electron copies are made on macOS only");
  const stamp = path.join(target, "Contents", ".hidden-electron");
  const wanted = `${electronVersion()} ${prepare ? "prepared" : "plain"} ${executableName ?? "Electron"}`;
  const executable = path.join(target, "Contents/MacOS", executableName ?? "Electron");
  if (fs.existsSync(stamp) && fs.readFileSync(stamp, "utf8") === wanted)
    return executable;
  if (fs.existsSync(target)) fs.rmSync(target, { recursive: true, force: true });
  fs.mkdirSync(path.dirname(target), { recursive: true });
  try {
    execFileSync("cp", ["-cR", sourceElectronApp(), target], { stdio: "pipe" });
  } catch {
    execFileSync("ditto", [sourceElectronApp(), target], { stdio: "pipe" });
  }
  const plist = path.join(target, "Contents/Info.plist");
  execFileSync("plutil", ["-replace", "LSBackgroundOnly", "-bool", "YES", plist]);
  execFileSync("plutil", ["-replace", "LSUIElement", "-bool", "YES", plist]);
  // Electron calls itself packaged when its executable is not named Electron (app.isPackaged), as a release is.
  if (executableName && executableName !== "Electron") {
    fs.renameSync(path.join(target, "Contents/MacOS/Electron"), executable);
    execFileSync("plutil", ["-replace", "CFBundleExecutable", "-string", executableName, plist]);
  }
  prepare?.(target);
  execFileSync("codesign", ["--force", "--sign", "-", target], { stdio: "pipe" });
  fs.writeFileSync(stamp, wanted);
  return executable;
}

/** YES when any window of the Playwright-launched `application` is visible: the run must stop at once. */
async function anyWindowVisible(application) {
  // BaseWindow's list: BrowserWindow's leaves out the hidden subclass's windows.
  return application.evaluate(({ BaseWindow }) =>
    BaseWindow.getAllWindows().some((window) => window.isVisible()),
  );
}

module.exports = { hiddenElectronApp, anyWindowVisible, HIDDEN_HOOK, HIDDEN_MAIN };
