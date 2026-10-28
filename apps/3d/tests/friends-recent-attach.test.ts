// What `#` offers in a conversation: the open model, then the recent files with when each was opened, narrowed by
// what follows `#`. A chosen recent file is attached as a dropped one is: from its path on a desktop that keeps one,
// otherwise its bytes staged for sending (phones, where the original's grant may have lapsed).
import { describe, expect, it } from "vitest";
import type { RecentEntry } from "../src/core/recent-files";
import type { FriendsBridge, PathKind } from "../src/friends/bridge";
import { AttachRefused, type OutgoingFile } from "../src/friends/drops";
import {
  attachSource,
  matchesQuery,
  openedLabel,
  recentGone,
  recentTooLarge,
  type RecentFiles,
} from "../src/friends/recent-attach";

const NOW = Date.UTC(2026, 9, 20, 12, 0, 0);
const entry = (
  name: string,
  format: string,
  minutesAgo: number,
  extra: Partial<RecentEntry> = {},
): RecentEntry => ({
  id: `${name}-id`,
  name,
  format,
  openedAt: NOW - minutesAgo * 60_000,
  fileCount: 1,
  totalBytes: 10,
  storage: "browser",
  ...extra,
});
const RECENT = [
  entry("Gearbox.step", "step", 3),
  entry("Pièce moulée.stl", "stl", 150),
  entry("Bracket.obj", "obj", 60 * 30, { fileCount: 3 }),
];

function bridge({
  kinds = [] as PathKind[],
  stagedDropLimit,
}: { kinds?: PathKind[]; stagedDropLimit?: number } = {}) {
  const staged: { name: string; size: number }[] = [];
  const fake = {
    stagedDropLimit,
    classify: async () => kinds,
    stage: async (name: string, bytes: Uint8Array) => {
      staged.push({ name, size: bytes.length });
      return `/private/outgoing/${name}`;
    },
  } as unknown as FriendsBridge;
  return { fake, staged };
}
const files = (
  paths: Record<string, string[]> = {},
  contents: Record<string, File[]> = {},
): RecentFiles => ({
  paths: async (e) => {
    if (e.storage !== "native") return null;
    if (!paths[e.id]) throw Error("moved");
    return paths[e.id];
  },
  open: async (e) => {
    if (!contents[e.id]) throw Error("gone");
    return contents[e.id];
  },
});
const project: OutgoingFile = {
  path: "/private/outgoing/Open.sz3d",
  display_name: "Open.sz3d",
};
const source = (
  over: Partial<Parameters<typeof attachSource>[0]> = {},
): ReturnType<typeof attachSource> =>
  attachSource({
    projectName: null,
    stageProject: async () => project,
    recent: RECENT,
    bridge: bridge().fake,
    files: files(),
    now: () => NOW,
    ...over,
  });

describe("# in a Shenzhen 3D conversation", () => {
  it("lists the open model first, then recent files with their format and when they were opened", () => {
    const items = source({ projectName: "Open" })!.items("");
    expect(
      items.map(({ title, detail, kind_label }) => [title, kind_label, detail]),
    ).toEqual([
      ["Open", "SZ3D", "The open model, with its notes and measurements"],
      ["Gearbox.step", "STEP", "Opened 3 minutes ago"],
      ["Pièce moulée.stl", "STL", "Opened 2 hours ago"],
      ["Bracket.obj", "OBJ", "Opened yesterday · 3 files"],
    ]);
  });

  it("narrows the list by name or format as the person types, ignoring case and accents", () => {
    const titles = (query: string) =>
      source()!
        .items(query)
        .map((item) => item.title);
    expect(titles("gear")).toEqual(["Gearbox.step"]);
    expect(titles("PIECE")).toEqual(["Pièce moulée.stl"]);
    expect(titles("obj")).toEqual(["Bracket.obj"]);
    expect(titles("nothing")).toEqual([]);
    expect(matchesQuery("  ", "anything")).toBe(true);
  });

  it("says when nothing matches, and offers nothing when there is nothing to attach", () => {
    expect(source({ projectName: "Open" })!.empty).toBe("No matching files");
    expect(source({ recent: [] })).toBeNull();
  });

  it("sends a desktop's recent file from its path, every file of the model, staging nothing", async () => {
    const native = entry("part.obj", "obj", 1, {
      storage: "native",
      fileCount: 2,
    });
    const { fake, staged } = bridge({ kinds: ["file", "file"] });
    const item = source({
      recent: [native],
      bridge: fake,
      files: files({
        [native.id]: ["/Users/mei/part.obj", "/Users/mei/part.mtl"],
      }),
    })!.items("")[0];
    expect(await item.file()).toEqual([
      { path: "/Users/mei/part.obj", display_name: "part.obj" },
      { path: "/Users/mei/part.mtl", display_name: "part.mtl" },
    ]);
    expect(staged).toEqual([]);
  });

  it("refuses a desktop's recent file that was moved, deleted or replaced", async () => {
    const native = entry("part.step", "step", 1, { storage: "native" });
    const moved = source({ recent: [native], files: files() })!.items("")[0];
    await expect(moved.file()).rejects.toThrow(AttachRefused);
    await expect(moved.file()).rejects.toThrow(recentGone("part.step"));
    const replaced = source({
      recent: [native],
      bridge: bridge({ kinds: ["other"] }).fake,
      files: files({ [native.id]: ["/Users/mei/part.step"] }),
    })!.items("")[0];
    await expect(replaced.file()).rejects.toThrow(recentGone("part.step"));
  });

  it("stages the kept copy of a phone's recent file, which still reads after the original's grant has lapsed", async () => {
    const kept = new File(["solid gearbox"], "Gearbox.step");
    const { fake, staged } = bridge({ stagedDropLimit: 250_000_000 });
    const item = source({
      bridge: fake,
      files: files({}, { [RECENT[0].id]: [kept] }),
    })!.items("gear")[0];
    expect(await item.file()).toEqual([
      { path: "/private/outgoing/Gearbox.step", display_name: "Gearbox.step" },
    ]);
    expect(staged).toEqual([{ name: "Gearbox.step", size: 13 }]);
  });

  it("refuses, before reading it, a phone's recent file larger than it can stage", async () => {
    const big = new File(["x".repeat(20)], "Big.step");
    const { fake, staged } = bridge({ stagedDropLimit: 10 });
    const item = source({
      bridge: fake,
      files: files({}, { [RECENT[0].id]: [big] }),
    })!.items("gear")[0];
    await expect(item.file()).rejects.toThrow(recentTooLarge("Big.step", 10));
    expect(staged).toEqual([]);
  });

  it("refuses a kept copy that is no longer there", async () => {
    const item = source({
      bridge: bridge({ stagedDropLimit: 10 }).fake,
    })!.items("gear")[0];
    await expect(item.file()).rejects.toThrow(recentGone("Gearbox.step"));
  });

  it("says when each file was opened", () => {
    expect(openedLabel(NOW - 20_000, NOW)).toBe("Opened just now");
    expect(openedLabel(NOW - 60_000, NOW)).toBe("Opened 1 minute ago");
    expect(openedLabel(NOW - 5 * 3600_000, NOW)).toBe("Opened 5 hours ago");
    expect(openedLabel(NOW - 3 * 86400_000, NOW)).toBe("Opened 3 days ago");
    expect(openedLabel(Date.UTC(2026, 8, 2, 12), NOW)).toBe("Opened Sep 2");
    expect(openedLabel(Date.UTC(2025, 8, 2, 12), NOW)).toBe(
      "Opened Sep 2, 2025",
    );
  });
});
