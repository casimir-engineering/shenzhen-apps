// The route a Friends page draws beside what travels over it, as the conversation header draws its own: the route
// icon, then the helper's words. A file copying here from another of the person's computers shows the route it
// comes by (PROTOCOL.md § Devices, type.item `route`); the join page shows the route its code travels and the one it
// joined over (PROTOCOL.md § join `route`). Without a route, nothing about it shows.
import { createElement } from "react";
import { describe, expect, it } from "vitest";
import type { Item, Snapshot } from "../src/friends/protocol";
import { ItemView } from "../src/friends/ConversationItems";
import { escape, json, pageFor, render } from "./friends-harness";

const none = () => {};
const conversation = json(
  "snapshots/devices-conversation-mei-files.json",
) as Snapshot;
const items = (conversation.data as { items: Item[] }).items;
const copying = items.find(
  (item) => item.kind === "transfer" && item.state === "fetching" && item.progress,
)!;

/** The words a row shows, tags dropped and entities read back. */
const text = (html: string) =>
  html
    .replace(/<[^>]*>/g, "")
    .replace(/&quot;/g, '"')
    .replace(/&#x27;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
const rowLabel = (html: string) =>
  /^<div class="szf-transfer[^"]*"[^>]*aria-label="([^"]*)"/.exec(html)?.[1];

async function renderItem(item: Item) {
  const { html } = await render(
    { conversation },
    [],
    createElement(ItemView, { item, onLink: none, onMention: none }),
  );
  return html;
}

describe("a file copying here from another computer shows its route", () => {
  it("the fixture has a copying item with a route", () => {
    expect(copying.status_label).toBe("Copying from Raph’s Mac mini · 25%");
    expect(copying.route).toEqual({
      kind: "local",
      method: "lan",
      label: "Nearby, on your network",
    });
  });

  it("draws the route icon, then its words, after the status", async () => {
    const html = await renderItem(copying);
    expect(html).toContain(
      `<span class="szf-route " title="Nearby, on your network" role="img" aria-label="Nearby, on your network"><svg`,
    );
    expect(text(html)).toContain(
      "Copying from Raph’s Mac mini · 25% · Nearby, on your network",
    );
    // The icon comes before the words.
    const icon = html.indexOf('class="szf-route ');
    const words = html.lastIndexOf("Nearby, on your network");
    expect(icon).toBeGreaterThan(-1);
    expect(words).toBeGreaterThan(icon);
  });

  it("says the route with the rest of the row", async () => {
    const html = await renderItem(copying);
    expect(rowLabel(html)).toBe(
      escape(`${copying.accessibility_label}, Nearby, on your network`),
    );
  });

  it("shows on the conversation page, in the copying row", async () => {
    const setup = pageFor("devices-conversation-mei-files.json", conversation)!;
    const { html } = await render(setup.byView, setup.holds, setup.page);
    const start = html.indexOf(`data-item="${copying.item_id}"`);
    const end = html.indexOf("data-item=", start + 1);
    const row = html.slice(start, end === -1 ? undefined : end);
    expect(row).toContain('class="szf-route ');
    expect(text(row)).toContain(
      "Copying from Raph’s Mac mini · 25% · Nearby, on your network",
    );
  });

  it("shows nothing about a route when the item has none", async () => {
    const { route: _route, ...without } = copying;
    const html = await renderItem(without as Item);
    expect(html).not.toContain("szf-route");
    expect(html).not.toContain("Nearby, on your network");
    expect(text(html)).toContain("Copying from Raph’s Mac mini · 25%");
    expect(text(html)).not.toContain("25% ·");
    expect(rowLabel(html)).toBe(escape(copying.accessibility_label));
    // Nor on the fixture's other transfers, which carry no route.
    for (const item of items.filter(
      (item) => item.kind === "transfer" && !item.route,
    )) {
      const other = await renderItem(item);
      expect(other, item.item_id).not.toContain("szf-route");
      expect(rowLabel(other), item.item_id).toBe(
        escape(item.accessibility_label),
      );
    }
  });
});

describe("the join page shows its route", () => {
  for (const [file, label] of [
    ["join-checking.json", "Online, through the Friends relay"],
    ["join-joined.json", "Nearby, on your network"],
  ] as const)
    it(file, async () => {
      const frame = json(`snapshots/${file}`) as Snapshot;
      expect((frame.data as { route: { label: string } }).route.label).toBe(
        label,
      );
      const setup = pageFor(file, frame)!;
      const { html } = await render(setup.byView, setup.holds, setup.page);
      const start = html.indexOf('<p class="szf-join-route"');
      expect(start).toBeGreaterThan(-1);
      const line = html.slice(start, html.indexOf("</p>", start) + 4);
      expect(line).toContain(
        `<span class="szf-route " title="${label}" role="img" aria-label="${label}"><svg`,
      );
      expect(text(line).trim()).toBe(label);
    });

  it("shows no route without one", async () => {
    for (const file of ["join-idle.json", "join-wrong-code.json"]) {
      const frame = json(`snapshots/${file}`) as Snapshot;
      expect((frame.data as { route?: unknown }).route ?? null, file).toBeNull();
      const setup = pageFor(file, frame)!;
      const { html } = await render(setup.byView, setup.holds, setup.page);
      expect(html, file).not.toContain("szf-join-route");
      expect(html, file).not.toContain('class="szf-route');
    }
  });
});
