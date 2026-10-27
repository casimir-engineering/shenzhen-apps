// Shortcut hints in the real Electron shell as Windows and Linux show them, run on a Mac and never on its screen
// (hidden-electron.cjs): the window's page is told it runs on each platform (Chromium's own user agent and
// navigator.platform override), a model is opened, and the header, the assembly's search, the status bar, the
// command palette and Help & shortcuts must say Ctrl and never ⌘. A screenshot of each is kept.
//
//   npm run build && node electron/shortcut-hints.mjs [--shots <dir>]
import { _electron as electron, expect } from "@playwright/test";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const root = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  "..",
);
const {
  hiddenElectronApp,
  anyWindowVisible,
  HIDDEN_MAIN,
} = require("./hidden-electron.cjs");
await fs.access(path.join(root, "dist/index.html")).catch(() => {
  throw Error("dist/index.html is missing: run npm run build first");
});
const shotsOption = process.argv.indexOf("--shots");
const directory = await fs.mkdtemp(
  path.join(os.tmpdir(), "sz3d-shortcut-hints-"),
);
const shots =
  shotsOption > 0 ? path.resolve(process.argv[shotsOption + 1]) : directory;
await fs.mkdir(shots, { recursive: true });

const platforms = {
  win32: {
    platform: "Win32",
    userAgent:
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Electron/44.7.2 Safari/537.36",
  },
  linux: {
    platform: "Linux x86_64",
    userAgent:
      "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Electron/44.7.2 Safari/537.36",
  },
};

const environment = { ...process.env };
delete environment.SHENZHEN_3D_DEV_URL;
hiddenElectronApp(path.join(root, "artifacts/hidden-electron/Electron.app"));
process.env.ELECTRON_OVERRIDE_DIST_PATH = path.join(
  root,
  "artifacts/hidden-electron",
);
const application = await electron.launch({
  args: [HIDDEN_MAIN, `--user-data-dir=${path.join(directory, "profile")}`],
  env: environment,
  cwd: root,
});
const errors = [];
const passed = [];
try {
  const page = await application.firstWindow();
  if (await anyWindowVisible(application))
    throw Error("a window is visible: stopping before anything else shows");
  page.on("pageerror", (error) => errors.push(error.message));
  for (const [name, as] of Object.entries(platforms)) {
    // Chromium's override, set in the main process before the page loads again: navigator.platform and userAgent
    // read as `name` from the first script on.
    const loaded = page.waitForEvent("load");
    await application.evaluate(async ({ BrowserWindow }, as) => {
      const { webContents } = BrowserWindow.getAllWindows()[0];
      if (!webContents.debugger.isAttached())
        webContents.debugger.attach("1.3");
      await webContents.debugger.sendCommand(
        "Emulation.setUserAgentOverride",
        as,
      );
      webContents.reload();
    }, as);
    await loaded;
    await expect
      .poll(() => page.evaluate(() => navigator.platform))
      .toBe(as.platform);
    const open = page
      .locator("header")
      .getByRole("button", { name: /^Open file/ });
    await expect(open).toBeEnabled();
    await page
      .getByRole("button", { name: "Sample model", exact: true })
      .click();
    await expect(page.locator(".model-badge")).toContainText("parts", {
      timeout: 120_000,
    });
    await expect(open.locator("kbd")).toHaveText("Ctrl+O");
    await expect(page.locator(".tree-search kbd")).toHaveText("Ctrl+F");
    await expect(page.locator(".status-navigation")).toContainText(
      "to pan with Ctrl held",
    );
    await page.screenshot({ path: path.join(shots, `${name}-header.png`) });
    await page.locator("body").press("Control+K");
    const palette = page.getByRole("dialog", { name: "Commands" });
    await expect(palette).toBeVisible();
    await expect(
      palette.getByRole("option", { name: /Open file/ }).locator("kbd"),
    ).toHaveText("Ctrl+O");
    await expect(
      palette.getByRole("option", { name: /^Settings/ }).locator("kbd"),
    ).toHaveText("Ctrl+,");
    await page.screenshot({ path: path.join(shots, `${name}-palette.png`) });
    await page.keyboard.press("Escape");
    await page
      .locator("header")
      .getByRole("button", { name: "Help & shortcuts" })
      .click();
    const help = page.locator("dialog[open]");
    await expect(help).toContainText("Ctrl+K");
    await expect(help).toContainText("Ctrl+S shares a project");
    await page.screenshot({ path: path.join(shots, `${name}-help.png`) });
    const glyphs = await page.evaluate(() => {
      const found = [];
      if (document.body.textContent.includes("⌘")) found.push("text");
      for (const element of document.querySelectorAll("*"))
        for (const attribute of ["title", "aria-label", "placeholder"])
          if (element.getAttribute(attribute)?.includes("⌘"))
            found.push(`${element.tagName}[${attribute}]`);
      return found;
    });
    expect(glyphs, `${name}: no ⌘ anywhere on the page`).toEqual([]);
    await page.keyboard.press("Escape");
    passed.push(name);
    console.log(
      `ok ${name}: Ctrl in the header, search, status bar, palette and Help; no ⌘`,
    );
  }
  if (await anyWindowVisible(application))
    throw Error("a window became visible");
  expect(errors).toEqual([]);
  console.log(
    `shortcut hints: ${passed.join(", ")} passed; screenshots in ${shots}`,
  );
} finally {
  await application.close();
}
