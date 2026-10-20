// Friends Settings in Shenzhen 3D: each button sits in the row it belongs to. On a phone (the Rust core's golden
// phone-settings.json) received files go to Downloads with no Change… of their own, so nothing under "Save received
// files to" may look like one; history is "on this device". Rendered with the panel's own CSS in headless Chromium
// at a phone's viewport, nothing on screen.
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { chromium, devices, type Browser } from "playwright";
import type { Snapshot } from "../src/friends/protocol";
import { json, pageFor, render } from "./friends-harness";

const css = readdirSync(path.resolve(__dirname, "../src/friends"))
  .filter((name) => name.endsWith(".css"))
  .map((name) =>
    readFileSync(path.resolve(__dirname, "../src/friends", name), "utf8"),
  )
  .join("\n");

async function markup(frame: Snapshot) {
  const shown = pageFor("settings", frame)!;
  const { html } = await render(shown.byView, shown.holds, shown.page);
  return html;
}

/** Each field of the Settings form: its label, and the buttons inside it, top to bottom. */
type Field = { label: string; text: string; buttons: string[]; top: number };

let browser: Browser;
beforeAll(async () => {
  browser = await chromium.launch({ headless: true });
});
afterAll(async () => {
  await browser?.close();
});

async function fields(frame: Snapshot, device = devices["Pixel 7"]) {
  const context = await browser.newContext({ ...device });
  try {
    const page = await context.newPage();
    await page.setContent(
      `<!doctype html><style>${css}</style><section class="szf-settings">${await markup(frame)}</section>`,
    );
    return await page.$$eval(".szf-form > .szf-field", (nodes) =>
      nodes.map((node) => ({
        label: (node.firstElementChild?.textContent ?? "").trim(),
        text: (node as HTMLElement).innerText,
        buttons: Array.from(node.querySelectorAll("button")).map((button) =>
          (button.textContent ?? "").trim(),
        ),
        top: node.getBoundingClientRect().top,
      })),
    );
  } finally {
    await context.close();
  }
}

const field = (all: Field[], label: string) => {
  const found = all.find((f) => f.label === label);
  expect(found, `a field labelled ${label}`).toBeTruthy();
  return found!;
};

describe("Friends Settings", () => {
  const phone = json("snapshots/phone-settings.json") as Snapshot;
  const computer = json("snapshots/settings.json") as Snapshot;

  it("on an Android phone, Downloads has no Change…, and the friends' button names what it shows", async () => {
    const all = await fields(phone);
    const received = field(all, "Save received files to");
    expect(received.text).toContain("Downloads");
    expect(received.buttons).toEqual([]);
    const automatic = field(all, "Accept files automatically");
    expect(automatic.buttons).toEqual(["Choose friends…"]);
    expect(automatic.top).toBeGreaterThan(received.top);
    expect(all.flatMap((f) => f.buttons)).not.toContain("Change…");
  });

  it("on a phone, history is on this device, and no Settings line says computer or Mac", async () => {
    const all = await fields(phone);
    expect(field(all, "Conversation history").text).toContain(
      "Stored on this device.",
    );
    const words = all.map((f) => f.text).join("\n");
    expect(words).not.toMatch(/computer|\bMac\b/);
  });

  it("with no friends there is nothing to choose, so the row shows only its note", async () => {
    const data = phone.data as Record<string, Record<string, unknown>>;
    const lonely = {
      ...phone,
      data: {
        ...data,
        auto_accept: {
          ...data.auto_accept,
          note: "Turn it on for a friend in their details.",
          friends: [],
        },
      },
    } as Snapshot;
    const all = await fields(lonely);
    const automatic = field(all, "Accept files automatically");
    expect(automatic.buttons).toEqual([]);
    expect(automatic.text).toContain(
      "Turn it on for a friend in their details.",
    );
    // Nothing between the folder and the history may read as a folder button.
    expect(field(all, "Save received files to").buttons).toEqual([]);
  });

  it("on a computer, the folder's Change… sits in the folder's own row", async () => {
    const all = await fields(computer, devices["Desktop Chrome"]);
    expect(field(all, "Save received files to").buttons).toEqual([
      "Change…",
      "Show in Finder",
    ]);
    expect(field(all, "Accept files automatically").buttons).toEqual([
      "Choose friends…",
    ]);
    expect(field(all, "Conversation history").text).toContain(
      "Stored on this computer.",
    );
  });
});
