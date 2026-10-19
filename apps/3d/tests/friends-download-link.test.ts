// Copy Download Link for the open model (src/friends/download-link.ts), against the pinned PROTOCOL fixtures: the
// intent the header and File ▸ Copy Download Link send, the link on the clipboard, and the words shown after.
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import path from "node:path";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { FriendsStatus, Reply } from "../src/friends/protocol";
import {
  copyDownloadLink,
  COPY_DOWNLOAD_LINK,
  downloadLinkRequests,
  EXPIRY_CHOICES,
  LINK_NOT_COPIED,
  LINK_STAGE_FAILED,
  offersLinks,
} from "../src/friends/download-link";
import { DownloadLinkButton } from "../src/friends/DownloadLinkButton";

const fixtures = path.resolve(__dirname, "fixtures/friends");
const linkReply: Reply = JSON.parse(
  readFileSync(path.join(fixtures, "replies/make_download_link.json"), "utf8"),
);
const welcome = JSON.parse(
  readFileSync(path.join(fixtures, "frames/welcome.json"), "utf8"),
);
const staged = {
  path: "/Users/raph/Library/Application Support/Shenzhen 3D/Friends/Outgoing/a/Gearbox.sz3d",
  display_name: "Gearbox.sz3d",
};

function harness(reply: Reply = linkReply) {
  const sent: { type: string; fields?: Record<string, unknown> }[] = [];
  const copied: string[] = [];
  const bridge = {
    async send(type: string, fields?: Record<string, unknown>) {
      sent.push({ type, fields });
      return { reply };
    },
  };
  const writeText = async (text: string) => void copied.push(text);
  return { sent, copied, bridge, writeText };
}

describe("Copy Download Link", () => {
  it("sends the staged model with the chosen expiry, copies the helper's URL and shows its words", async () => {
    const { sent, copied, bridge, writeText } = harness();
    const outcome = await copyDownloadLink(
      bridge,
      async () => staged,
      writeText,
      30,
    );
    expect(sent).toEqual([
      {
        type: "make_download_link",
        fields: { file: staged, expires_days: 30 },
      },
    ]);
    expect(copied).toEqual([linkReply.result!.url]);
    expect(outcome).toEqual({
      copied: true,
      message: linkReply.result!.message,
    });
  });

  it("shows the helper's refusal and copies nothing", async () => {
    const refusal: Reply = {
      type: "reply",
      re: "9",
      ok: false,
      error: {
        code: "too_many_links",
        message: "You have 50 download links. Revoke one to make another.",
        retryable: false,
        details: {},
      },
    };
    const { copied, bridge, writeText } = harness(refusal);
    expect(
      await copyDownloadLink(bridge, async () => staged, writeText, 7),
    ).toEqual({ copied: false, message: refusal.error!.message });
    expect(copied).toEqual([]);
  });

  it("says so in its own words when the model cannot be saved or the clipboard refuses", async () => {
    const failing = harness();
    expect(
      await copyDownloadLink(
        failing.bridge,
        async () => {
          throw Error("Error invoking remote method 'shenzhen-friends'");
        },
        failing.writeText,
        7,
      ),
    ).toEqual({ copied: false, message: LINK_STAGE_FAILED });
    expect(failing.sent).toEqual([]);
    const clipboard = harness();
    expect(
      await copyDownloadLink(
        clipboard.bridge,
        async () => staged,
        async () => {
          throw new DOMException("Document is not focused.");
        },
        1,
      ),
    ).toEqual({ copied: false, message: LINK_NOT_COPIED });
    for (const message of [LINK_STAGE_FAILED, LINK_NOT_COPIED])
      expect(message).not.toMatch(/invoke|remote|method|stag|clipboard/i);
  });

  it("refuses an expiry the protocol does not offer, before anything is staged", async () => {
    const { sent, bridge, writeText } = harness();
    let stagedCount = 0;
    const stage = async () => (stagedCount++, staged);
    expect(await copyDownloadLink(bridge, stage, writeText, 2)).toEqual({
      copied: false,
      message: null,
    });
    expect([sent.length, stagedCount]).toEqual([0, 0]);
  });

  it("is offered only while Friends is ready and its helper announces links", () => {
    const status: FriendsStatus = {
      available: true,
      enabled: true,
      attached: true,
      state: "ready",
      text: "",
      strings: welcome.strings,
      capabilities: [...welcome.capabilities, "links"],
      limits: welcome.limits,
      badge: null,
    };
    expect(offersLinks(status)).toBe(true);
    expect(
      offersLinks({ ...status, capabilities: welcome.capabilities }),
      "the pinned M1 welcome has no links",
    ).toBe(false);
    expect(offersLinks({ ...status, state: "waiting" })).toBe(false);
    expect(offersLinks({ ...status, enabled: false })).toBe(false);
    expect(offersLinks(null)).toBe(false);
  });

  it("offers 7 days first, then 1 and 30, like the other apps and the File menu", async () => {
    expect(EXPIRY_CHOICES.map((choice) => choice.days)).toEqual([7, 1, 30]);
    // The File menu's choices (electron/friends/share-menu.cjs) are the same words in the same order.
    const { EXPIRY_CHOICES: menu } =
      await import("../electron/friends/share-menu.cjs");
    expect(menu).toEqual(EXPIRY_CHOICES);
    const markup = renderToStaticMarkup(
      createElement(DownloadLinkButton, { busy: false, onChoose: () => {} }),
    );
    expect(markup).toContain(`aria-label="${COPY_DOWNLOAD_LINK}"`);
    expect(markup).toContain('aria-haspopup="menu"');
  });

  it("passes File ▸ Copy Download Link's choice to the header, and only a protocol expiry", () => {
    const heard: number[] = [];
    const stop = downloadLinkRequests.listen((days) => heard.push(days));
    downloadLinkRequests.request(30);
    downloadLinkRequests.request(5);
    stop();
    downloadLinkRequests.request(7);
    expect(heard).toEqual([30]);
  });
});
