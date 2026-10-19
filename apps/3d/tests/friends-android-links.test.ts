// Friends links on Android: the intent filter a Friends build writes into the manifest (scripts/platform-build.mjs).
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import path from "node:path";
import {
  linkFilters,
  withLinkFilters,
} from "../scripts/friends/android-links.mjs";

const root = path.resolve(__dirname, "..");
const manifest = readFileSync(
  path.join(root, "src-tauri/gen/android/app/src/main/AndroidManifest.xml"),
  "utf8",
);
const { mobile } = JSON.parse(
  readFileSync(path.join(root, "src-tauri/friends/phones.conf.json"), "utf8"),
).plugins["deep-link"];

describe("Friends links on Android", () => {
  it("opens shenzhen3d://friends links in the app, and only those", () => {
    const [filter, ...others] = linkFilters(mobile);
    expect(others).toEqual([]);
    expect(filter).toContain('<data android:scheme="shenzhen3d" />');
    expect(filter).toContain('<data android:host="friends" />');
    expect(filter).toContain("android.intent.category.BROWSABLE");
    expect(filter).not.toContain("autoVerify");
  });

  it("writes one block into the activity however often it runs, and the committed manifest has none", () => {
    expect(manifest).not.toContain('android:scheme="shenzhen3d"');
    const once = withLinkFilters(manifest, mobile);
    expect(withLinkFilters(once, mobile)).toBe(once);
    expect(once.match(/android:scheme="shenzhen3d"/g)).toHaveLength(1);
    const block = once.indexOf("DEEP LINK PLUGIN");
    expect(block).toBeGreaterThan(once.indexOf("<activity"));
    expect(block).toBeLessThan(once.indexOf("</activity>"));
    expect(
      once.replace(
        /\n *<!-- DEEP LINK PLUGIN[\s\S]*PLUGIN\. AUTO-GENERATED\. DO NOT REMOVE\. -->/,
        "",
      ),
    ).toBe(manifest);
  });
});
