// Attach files in a conversation's composer: the system's file picker for any file, several at once, beside `#`
// (recent files). The paperclip is there wherever the shell has a picker and the helper names it ("Attach files");
// what is chosen is checked as a drop is, so folders, links and special files are refused in the helper's words.
import { afterEach, describe, expect, it, vi } from "vitest";
import type { FriendsBridge, PathKind } from "../src/friends/bridge";
import { canChooseFiles, chooseFiles } from "../src/friends/drops";
import type { Strings } from "../src/friends/protocol";
import { json, pageFor, render, status, welcome } from "./friends-harness";

const chosen = vi.hoisted(() => ({ paths: null as string[] | null }));
vi.mock("@tauri-apps/plugin-dialog", () => ({
  open: async (options: { multiple?: boolean; directory?: boolean }) => {
    expect(options).toMatchObject({ multiple: true, directory: false });
    return chosen.paths;
  },
}));

const strings = welcome.strings as Strings;
const tauri = () =>
  vi.stubGlobal("window", { __TAURI_INTERNALS__: { invoke: () => null } });
afterEach(() => {
  vi.unstubAllGlobals();
  chosen.paths = null;
});

function classifying(kinds: Record<string, PathKind>) {
  const asked: string[][] = [];
  const bridge = {
    classify: async (paths: string[]) => {
      asked.push(paths);
      return paths.map((path) => kinds[path] ?? "missing");
    },
  } as unknown as FriendsBridge;
  return { bridge, asked };
}

describe("Attach files", () => {
  it("takes what the shell's own picker chose (Electron, phones), and nothing when cancelled", async () => {
    const files = [
      { path: "/Users/mei/Plant.step", display_name: "Plant.step" },
      { path: "/Users/mei/notes.txt", display_name: "notes.txt" },
    ];
    let answer: typeof files | null = files;
    const bridge = {
      chooseFiles: async () => answer,
    } as unknown as FriendsBridge;
    expect(canChooseFiles(bridge)).toBe(true);
    expect(await chooseFiles(bridge, strings)).toEqual({
      files,
      refusal: null,
    });
    answer = null;
    expect(await chooseFiles(bridge, strings)).toEqual({
      files: [],
      refusal: null,
    });
  });

  it("on a Tauri desktop, opens the dialog for any files and sends them from their paths", async () => {
    tauri();
    const { bridge, asked } = classifying({
      "/home/mei/Plant.step": "file",
      "C:\\Users\\Mei\\Report.pdf": "file",
    });
    expect(canChooseFiles(bridge)).toBe(true);
    chosen.paths = ["/home/mei/Plant.step", "C:\\Users\\Mei\\Report.pdf"];
    expect(await chooseFiles(bridge, strings)).toEqual({
      files: [
        { path: "/home/mei/Plant.step", display_name: "Plant.step" },
        { path: "C:\\Users\\Mei\\Report.pdf", display_name: "Report.pdf" },
      ],
      refusal: null,
    });
    expect(asked).toEqual([chosen.paths]);
    chosen.paths = null;
    expect(await chooseFiles(bridge, strings)).toEqual({
      files: [],
      refusal: null,
    });
  });

  it("refuses a chosen folder or special file in the helper's words, as a drop", async () => {
    tauri();
    const { bridge } = classifying({
      "/a/file.txt": "file",
      "/a/Parts.app": "folder",
      "/a/link": "other",
    });
    chosen.paths = ["/a/file.txt", "/a/Parts.app"];
    expect(await chooseFiles(bridge, strings)).toEqual({
      files: [],
      refusal: strings.drop_folders_refused,
    });
    chosen.paths = ["/a/file.txt", "/a/link"];
    expect(await chooseFiles(bridge, strings)).toEqual({
      files: [],
      refusal: strings.drop_not_a_file,
    });
  });

  it("has no picker on the web, nor through Tauri's dialog on a phone (the plugin's own picker is used)", () => {
    expect(canChooseFiles({} as FriendsBridge)).toBe(false);
    tauri();
    expect(
      canChooseFiles({ stagedDropLimit: 250e6 } as unknown as FriendsBridge),
    ).toBe(false);
  });

  it("the composer shows the paperclip, named Attach files, where the shell has a picker", async () => {
    const frame = json("snapshots/conversation-mei.json");
    const setup = pageFor("conversation-mei.json", frame)!;
    const picker = { chooseFiles: async () => null };
    const shown = await render(setup.byView, setup.holds, setup.page, {
      bridge: picker,
    });
    expect(shown.html).toContain('class="szf-attach"');
    expect(shown.html).toContain('aria-label="Attach files"');
    expect(shown.html).toContain('title="Attach files"');
    // Before the field, so the field keeps its width beside Send.
    expect(shown.html.indexOf("szf-attach")).toBeLessThan(
      shown.html.indexOf("szf-editor"),
    );
    // No picker in this shell (the web build): no paperclip.
    const none = await render(setup.byView, setup.holds, setup.page);
    expect(none.html).not.toContain("szf-attach");
    // A helper too old to name it: no unnamed button.
    const older = await render(setup.byView, setup.holds, setup.page, {
      bridge: picker,
      status: {
        ...status,
        strings: { ...status.strings, attach_files: undefined },
      },
    });
    expect(older.html).not.toContain("szf-attach");
  });
});
