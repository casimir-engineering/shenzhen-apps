// Shortcut hints as Windows, Linux and Android see them (src/core/shortcuts.ts): the whole app rendered with the
// browser describing itself as each, a model open, Help & shortcuts and the command palette shown. Not one ⌘ may
// appear in the page's text, its tooltips or its labels; the hints say Ctrl. An Android phone shows none until a
// keyboard is used, then Ctrl too.
import { test, expect, type Page } from "@playwright/test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const welcome = JSON.parse(
  readFileSync(resolve("tests/fixtures/friends/frames/welcome.json"), "utf8"),
);

const platforms = {
  win32: {
    platform: "Win32",
    userAgent:
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
    maxTouchPoints: 0,
  },
  linux: {
    platform: "Linux x86_64",
    userAgent:
      "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
    maxTouchPoints: 0,
  },
  android: {
    platform: "Linux armv8l",
    userAgent:
      "Mozilla/5.0 (Linux; Android 15; 24117RK2CG) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36",
    maxTouchPoints: 5,
  },
};

async function pretend(
  page: Page,
  as: (typeof platforms)[keyof typeof platforms],
) {
  await page.addInitScript((as) => {
    for (const [name, value] of Object.entries(as))
      Object.defineProperty(Navigator.prototype, name, {
        get: () => value,
        configurable: true,
      });
  }, as);
}

/** Friends, on: a stand-in bridge with the pinned welcome's strings, so its button, palette commands and Help line
 * show (as in e2e-friends-menu.spec.ts). */
async function friends(page: Page) {
  await page.addInitScript(({ strings, capabilities, limits }) => {
    const status = {
      available: true,
      enabled: true,
      attached: true,
      state: "ready",
      text: "",
      strings,
      capabilities,
      limits,
      badge: null,
    };
    let next = 0;
    const reply = (result: unknown) => ({
      type: "reply",
      re: String(++next),
      ok: true,
      result,
    });
    (window as unknown as { shenzhenFriends: unknown }).shenzhenFriends = {
      join: async () => status,
      status: async () => status,
      subscribe: () => () => {},
      send: async (type: string) => ({
        reply: reply(type === "subscribe" ? { subscription: `s_${next}` } : {}),
      }),
      setEnabled: async () => status,
      image: async () => null,
      animal: async () => null,
      animals: async () => null,
      pathsForFiles: () => [],
      classify: async () => [],
      stage: async () => "",
      token: async () => "",
      openFile: async () => false,
      showFile: async () => false,
      openSettings: async () => false,
      openURL: async () => false,
      shareable: async () => {},
    };
  }, welcome);
}

/** Every ⌘ the page shows or names: its text (open or closed dialogs alike), tooltips and accessible labels. */
const commandGlyphs = (page: Page) =>
  page.evaluate(() => {
    const found: string[] = [];
    if (document.body.textContent?.includes("⌘")) found.push("text");
    for (const element of document.querySelectorAll("*"))
      for (const name of [
        "title",
        "aria-label",
        "aria-description",
        "placeholder",
        "aria-keyshortcuts",
      ]) {
        const value = element.getAttribute(name);
        if (value?.includes("⌘"))
          found.push(`${element.tagName}[${name}="${value}"]`);
      }
    return found;
  });

const hints = (page: Page) =>
  page.evaluate(() =>
    [...document.querySelectorAll("kbd")].map((kbd) => kbd.textContent ?? ""),
  );

async function openModel(page: Page) {
  await page.goto("/");
  await page.getByRole("button", { name: "Sample model", exact: true }).click();
  await expect(page.locator(".model-badge")).toContainText("parts", {
    timeout: 120_000,
  });
  await expect(
    page.getByRole("textbox", { name: "Search assembly" }),
  ).toBeVisible();
}

test.describe("shortcut hints", () => {
  test.skip(
    ({ isMobile }) => isMobile,
    "the desktop project renders each platform itself",
  );

  for (const name of ["win32", "linux"] as const)
    test(`${name}: Ctrl everywhere, ⌘ nowhere`, async ({ page }) => {
      await pretend(page, platforms[name]);
      await friends(page);
      await openModel(page);
      await expect(page.locator('[data-szfriends="button"]')).toHaveAttribute(
        "title",
        "Friends (Beta) · Ctrl+J",
      );
      await expect(page.locator('[data-szfriends="button"]')).toHaveAttribute(
        "aria-keyshortcuts",
        "Control+J",
      );
      const header = page
        .locator("header")
        .getByRole("button", { name: /^Open file/ });
      await expect(header.locator("kbd")).toHaveText("Ctrl+O");
      await expect(page.locator(".tree-search kbd")).toHaveText("Ctrl+F");
      await expect(page.locator(".status-navigation")).toContainText(
        "to pan with Ctrl held",
      );
      await page.keyboard.press("Control+K");
      const palette = page.getByRole("dialog", { name: "Commands" });
      await expect(palette).toBeVisible();
      await expect(
        palette.getByRole("option", { name: /Open file/ }).locator("kbd"),
      ).toHaveText("Ctrl+O");
      await expect(
        palette.getByRole("option", { name: /Search assembly/ }).locator("kbd"),
      ).toHaveText("Ctrl+F");
      await expect(
        palette.getByRole("option", { name: /^Settings/ }).locator("kbd"),
      ).toHaveText("Ctrl+,");
      await expect(
        palette.getByRole("option", { name: /Open Friends/ }).locator("kbd"),
      ).toHaveText("Ctrl+J");
      expect(await commandGlyphs(page)).toEqual([]);
      await page.keyboard.press("Escape");
      await page
        .locator("header")
        .getByRole("button", { name: "Help & shortcuts" })
        .click();
      const help = page.locator("dialog[open]");
      await expect(help).toBeVisible();
      await expect(help).toContainText("Ctrl+O");
      await expect(help).toContainText("Ctrl+K");
      await expect(help).toContainText("Open or close FriendsCtrl+J");
      await expect(help).toContainText("Ctrl+S shares a project");
      expect(await commandGlyphs(page)).toEqual([]);
      expect(
        (await hints(page))
          .filter((hint) => /Ctrl|⌘/.test(hint))
          .every((hint) => !hint.includes("⌘")),
      ).toBe(true);
    });

  test("android: no hints until a keyboard is used, then Ctrl", async ({
    page,
  }) => {
    await pretend(page, platforms.android);
    await openModel(page);
    expect(await hints(page)).toEqual([]);
    expect(
      await page.locator(".status-navigation").textContent(),
    ).not.toContain("held");
    // A key pressed outside any text field: an on-screen keyboard cannot send one.
    await page.locator("body").press("Shift");
    await expect(page.locator(".tree-search kbd")).toHaveText("Ctrl+F");
    expect(await commandGlyphs(page)).toEqual([]);
  });
});
