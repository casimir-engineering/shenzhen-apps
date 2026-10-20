// Cmd+J and the Cmd+K palette's Friends commands, in the real Electron shell with a real helper: keys are pressed in
// the window as a person would press them, and the checks read what the page shows and where its focus is.
//
//   scripts/friends/setup-friends.sh && npm run build && node electron/friends-shortcut.mjs
//
// The helper is an ad hoc signed copy of the built one that also declares this run's own Bonjour type, in a
// temporary Friends home (SZFRIENDS_STATE_DIR), as electron/friends-smoke.mjs runs it: it uses a file key store,
// never the Keychain, finds nothing but loopback, and the person's own Friends identity and helper are never touched.
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

const directory = await fs.mkdtemp(path.join(os.tmpdir(), "szf3d-shortcut-"));
const serviceType = `_szf3k${process.pid.toString(36).slice(-6)}._tcp`;
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
const mod = process.platform === "darwin" ? "Meta" : "Control";
const shortcut = process.platform === "darwin" ? "⌘J" : "Ctrl+J";

const environment = {
  ...process.env,
  SHENZHEN_3D_FRIENDS_HELPER: helperApp,
  SHENZHEN_3D_FRIENDS_ADDON: addonPath,
  SZFRIENDS_STATE_DIR: path.join(directory, "home"),
  SZFRIENDS_DOWNLOADS_DIR: path.join(directory, "downloads"),
  SZFRIENDS_TEST_SERVICE_TYPE: serviceType,
};
delete environment.SHENZHEN_3D_DEV_URL;
let application;
const errors = [];
try {
  application = await electron.launch({
    args: [
      // Nothing on screen: no Dock icon, no window to the front, no error dialogs (test-hidden.cjs).
      path.join(root, "electron/test-hidden.cjs"),
      `--user-data-dir=${path.join(directory, "profile")}`,
    ],
    env: environment,
  });
  console.error(`electron pid ${application.process().pid}`);
  const page = await application.firstWindow();
  page.on("pageerror", (error) => errors.push(error.message));
  page.on(
    "console",
    (message) => message.type() === "error" && errors.push(message.text()),
  );
  const button = page.locator('[data-szfriends="button"]');
  await expect(button).toBeVisible({ timeout: 30_000 });
  await expect(button).toHaveAttribute("title", /\S/);
  const title = await button.getAttribute("title");
  if (!title.endsWith(` · ${shortcut}`))
    throw Error(
      `the Friends button's tooltip is "${title}", without ${shortcut}`,
    );
  check(`the Friends button's tooltip shows ${shortcut}: "${title}"`);

  const panel = page.locator('[data-szfriends="dropdown"]');
  const search = panel.locator('input[type="search"]');
  // Keys go to the page with nothing focused, as after a click on the model.
  await page.evaluate(() => document.activeElement?.blur?.());
  await page.keyboard.press(`${mod}+j`);
  await expect(panel).toBeVisible();
  await expect(search).toBeFocused();
  check(`${shortcut} opens Friends with the search field focused`);
  // Friends is a beta: the tag beside the title shows, whole, inside the dropdown.
  const beta = panel.locator('[data-szfriends="beta"]');
  await expect(beta).toBeVisible();
  await expect(beta).toHaveText("Beta");
  const [tag, box] = [await beta.boundingBox(), await panel.boundingBox()];
  if (
    !tag ||
    !box ||
    tag.width < 1 ||
    tag.x < box.x ||
    tag.y < box.y ||
    tag.x + tag.width > box.x + box.width ||
    tag.y + tag.height > box.y + box.height
  )
    throw Error(
      `the Beta tag is outside the dropdown: ${JSON.stringify({ tag, box })}`,
    );
  check("the dropdown's title shows the Beta tag inside the dropdown");

  await page.keyboard.type("zz");
  await expect(search).toHaveValue("zz");
  await page.keyboard.press(`${mod}+j`);
  await expect(panel).toHaveCount(0);
  check(`${shortcut} again, typed in Friends' search field, closes it`);

  const palette = page.getByRole("dialog", { name: "Commands" });
  const field = palette.getByRole("combobox");
  const options = palette.getByRole("option");
  await page.keyboard.press(`${mod}+k`);
  await expect(palette).toBeVisible();
  await expect(field).toBeFocused();
  for (const query of ["friend", "nearby", "add by id", "chat", "friends"]) {
    await page.keyboard.press(`${mod}+a`);
    await page.keyboard.type(query);
    await expect(options.filter({ hasText: "Open Friends" })).toHaveCount(1);
  }
  await expect(options.first()).toHaveText(`Open Friends${shortcut}`);
  await expect(options.first()).toHaveAttribute("aria-selected", "true");
  for (const title of [
    "Add by ID…",
    "Make myself visible",
    "Friends Settings…",
  ])
    await expect(options.filter({ hasText: title })).toHaveCount(1);
  check(
    'the palette finds Open Friends (with its shortcut) for "friends", "friend", "nearby", "add by id" and "chat", ' +
      'and lists the other Friends commands for "friends"',
  );
  await page.keyboard.press("Enter");
  await expect(palette).toBeHidden();
  await expect(panel).toBeVisible();
  await expect(search).toBeFocused();
  check('Cmd+K, "friends", Return opens Friends with the search field focused');

  await page.keyboard.press("Escape");
  await expect(panel).toHaveCount(0);
  await page.keyboard.press(`${mod}+k`);
  await page.keyboard.type("add by id");
  await expect(options.first()).toHaveText("Add by ID…");
  await page.keyboard.press("Enter");
  await expect(panel).toBeVisible();
  await expect(panel.locator("form.szf-field input").last()).toBeFocused({
    timeout: 15_000,
  });
  check("Add by ID… opens Friends on the profile page, in its ID field");

  await page.keyboard.press("Escape");
  await expect(panel).toHaveCount(0);
  await page.keyboard.press(`${mod}+k`);
  await page.keyboard.type("visible");
  await expect(options.first()).toHaveText("Make myself visible");
  await page.keyboard.press("Enter");
  await expect(panel).toBeVisible();
  await expect(panel.locator(".szf-countdown")).toBeVisible({
    timeout: 30_000,
  });
  check("Make myself visible opens Nearby and makes this person visible");

  await page.keyboard.press("Escape");
  await expect(panel).toHaveCount(0);
  await page.keyboard.press(`${mod}+k`);
  await page.keyboard.type("friends settings");
  await page.keyboard.press("Enter");
  const settings = page.locator("dialog.settings-dialog");
  await expect(settings).toBeVisible();
  await expect(settings.locator('[data-szfriends="settings"]')).toBeInViewport({
    timeout: 15_000,
  });
  await page.keyboard.press("Escape");
  await expect(settings).toBeHidden();
  check("Friends Settings… opens Settings at the Friends section");

  const menuItem = () =>
    application.evaluate(({ Menu }) => {
      const item = Menu.getApplicationMenu().getMenuItemById("friends-toggle");
      return (
        item && {
          label: item.label,
          accelerator: item.accelerator,
          visible: item.visible,
          enabled: item.enabled,
        }
      );
    });
  const item = await menuItem();
  if (
    item?.label !== "Friends (Beta)" ||
    item.accelerator !== "CmdOrCtrl+J" ||
    !item.visible ||
    !item.enabled
  )
    throw Error(`View ▸ Friends is ${JSON.stringify(item)}`);
  await application.evaluate(({ Menu, BrowserWindow }) =>
    Menu.getApplicationMenu()
      .getMenuItemById("friends-toggle")
      .click(undefined, BrowserWindow.getAllWindows()[0]),
  );
  await expect(panel).toBeVisible();
  await expect(search).toBeFocused();
  check(`View ▸ Friends shows ${shortcut} and opens Friends`);
  await page.keyboard.press("Escape");
  await expect(panel).toHaveCount(0);

  // Friends turned off: no button, no Friends commands, and Cmd+J does nothing.
  await page.evaluate(() => window.shenzhenFriends.setEnabled(false));
  await expect(button).toHaveCount(0);
  await page.keyboard.press(`${mod}+k`);
  await page.keyboard.type("friends");
  await expect(
    options.filter({ hasText: /Friends|Add by ID|visible/ }),
  ).toHaveCount(0);
  await page.keyboard.press("Escape");
  await expect(palette).toBeHidden();
  await page.keyboard.press(`${mod}+j`);
  await page.waitForTimeout(500);
  await expect(panel).toHaveCount(0);
  if ((await menuItem())?.visible)
    throw Error("View ▸ Friends shows while Friends is off");
  check(
    "with Friends off, the palette has no Friends commands, the menu item hides and Cmd+J does nothing",
  );

  expect(errors).toEqual([]);
  check("no page errors");
} finally {
  await application?.close().catch(() => {});
  // The helper exits by itself 10 s after its last client (PROTOCOL.md § Lifecycle); wait for this run's.
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
    console.error(`helper still running from ${helperExecutable}: ${left}`);
}
console.log(JSON.stringify({ friendsShortcut: "passed", checks }, null, 2));
