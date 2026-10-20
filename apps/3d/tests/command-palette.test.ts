// The command palette's matching (src/components/CommandPalette.tsx): every word typed begins a word of the title or
// of a keyword; title matches first.
import { describe, expect, it } from "vitest";
import { matchCommands, type Command } from "../src/components/CommandPalette";

const command = (
  id: string,
  title: string,
  keywords: string[] = [],
): Command => ({
  id,
  title,
  keywords,
  run() {},
});
const commands = [
  command("open", "Open file…", ["model"]),
  command("friends-open", "Open Friends", [
    "friend",
    "nearby",
    "add by id",
    "chat",
    "message",
    "people",
  ]),
  command("friends-add", "Add by ID…", ["friends", "friend", "add", "invite"]),
  command("friends-visible", "Make myself visible", [
    "friends",
    "nearby",
    "discoverable",
  ]),
  command("friends-settings", "Friends Settings…", ["preferences"]),
  command("settings", "Settings…", ["preferences"]),
];
const ids = (query: string) =>
  matchCommands(commands, query).map((found) => found.id);

describe("matchCommands", () => {
  it("finds Open Friends first for friends, and by the words people use for it", () => {
    expect(ids("friends")).toEqual([
      "friends-open",
      "friends-settings",
      "friends-add",
      "friends-visible",
    ]);
    for (const query of [
      "friend",
      "nearby",
      "add by id",
      "chat",
      "Friends",
      "  CHAT ",
    ])
      expect(ids(query)).toContain("friends-open");
  });
  it("puts a title match before a keyword match", () => {
    expect(ids("add by id")[0]).toBe("friends-add");
    expect(ids("nearby")).toEqual(["friends-open", "friends-visible"]);
    expect(ids("settings")).toEqual(["friends-settings", "settings"]);
  });
  it("needs every word, each at the start of a word", () => {
    expect(ids("open fr")).toEqual(["friends-open"]);
    expect(ids("riends")).toEqual([]);
    expect(ids("friends banana")).toEqual([]);
  });
  it("lists everything for an empty query, in order", () => {
    expect(ids("")).toEqual(commands.map((found) => found.id));
  });
});
