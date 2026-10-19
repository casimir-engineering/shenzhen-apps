// Files dropped on Friends: paths on desktops (Electron's, or the ones Tauri's system reported), the files' bytes
// staged privately on phones when each fits, and the helper's words for anything that is not a regular file.
import { describe, expect, it } from "vitest";
import type { FriendsBridge, PathKind } from "../src/friends/bridge";
import { filesFromDrop, tooLargeToStage } from "../src/friends/drops";
import type { Strings } from "../src/friends/protocol";

const strings = {
  drop_not_a_file: "Only files can be sent.",
  drop_folders_refused: "Folders can't be sent. Send the files inside instead.",
} as unknown as Strings;

const PHONE = 250_000_000;

function bridge(
  paths: (string | null)[],
  kinds: PathKind[] = [],
  stage = true,
  stagedDropLimit?: number,
) {
  const staged: { name: string; size: number }[] = [];
  const fake = {
    stagedDropLimit,
    // Tauri answers once the system has reported the drop.
    pathsForFiles: async (files: ArrayLike<File>) =>
      Array.from(files, (_file, index) => paths[index] ?? null),
    classify: async () => kinds,
    stage: async (name: string, bytes: Uint8Array) => {
      if (!stage) throw Error("Invalid project name");
      staged.push({ name, size: bytes.length });
      return `/private/outgoing/${name}`;
    },
  } as unknown as FriendsBridge;
  return { fake, staged };
}

const file = (name: string, text: string) => new File([text], name);

describe("files dropped on Friends", () => {
  it("sends regular files by their paths when the shell gives them", async () => {
    const { fake, staged } = bridge(["/Users/mei/Gearbox.stl"], ["file"]);
    const result = await filesFromDrop(fake, strings, [
      file("Gearbox.stl", "solid"),
    ]);
    expect(result).toEqual({
      files: [{ path: "/Users/mei/Gearbox.stl", display_name: "Gearbox.stl" }],
      refusal: null,
    });
    expect(staged).toEqual([]);
  });

  it("refuses folders and other kinds in the helper's words", async () => {
    const folder = await filesFromDrop(
      bridge(["/a"], ["folder"]).fake,
      strings,
      [file("a", "")],
    );
    expect(folder.refusal).toBe(strings.drop_folders_refused);
    const other = await filesFromDrop(bridge(["/b"], ["other"]).fake, strings, [
      file("b", ""),
    ]);
    expect(other.refusal).toBe(strings.drop_not_a_file);
  });

  it("on a phone, stages the bytes under the names the friend will see", async () => {
    const { fake, staged } = bridge([null, null], [], true, PHONE);
    const result = await filesFromDrop(fake, strings, [
      file("Gearbox.stl", "solid"),
      file("Notes.txt", "hi"),
    ]);
    expect(staged).toEqual([
      { name: "Gearbox.stl", size: 5 },
      { name: "Notes.txt", size: 2 },
    ]);
    expect(result.files.map((f) => f.display_name)).toEqual([
      "Gearbox.stl",
      "Notes.txt",
    ]);
    expect(result.refusal).toBeNull();
  });

  it("on a phone, refuses a dropped folder in the helper's words", async () => {
    const folder = file("Parts", "");
    Object.defineProperty(folder, "arrayBuffer", {
      value: () =>
        Promise.reject(new DOMException("not readable", "NotReadableError")),
    });
    const result = await filesFromDrop(
      bridge([null], [], true, PHONE).fake,
      strings,
      [folder],
    );
    expect(result).toEqual({
      files: [],
      refusal: strings.drop_folders_refused,
    });
  });

  it("on a phone, says only files can be sent when the bytes cannot be staged", async () => {
    const result = await filesFromDrop(
      bridge([null], [], false, PHONE).fake,
      strings,
      [file("x", "1")],
    );
    expect(result).toEqual({ files: [], refusal: strings.drop_not_a_file });
  });

  it("on a phone, refuses a file over the limit before reading any of it", async () => {
    const { fake, staged } = bridge([null, null], [], true, PHONE);
    const big = file("Plant.step", "x");
    Object.defineProperty(big, "size", { value: PHONE + 1 });
    Object.defineProperty(big, "arrayBuffer", {
      value: () => {
        throw Error("read");
      },
    });
    const result = await filesFromDrop(fake, strings, [
      file("Notes.txt", "hi"),
      big,
    ]);
    expect(result).toEqual({
      files: [],
      refusal:
        "Plant.step is too large to send from this device. Files you drop here can be up to 250 MB.",
    });
    expect(result.refusal).toBe(tooLargeToStage("Plant.step", PHONE));
    expect(staged).toEqual([]);
  });

  it("on a desktop, stages nothing: a drop without paths is refused in the helper's words", async () => {
    const { fake, staged } = bridge([null]);
    const result = await filesFromDrop(fake, strings, [file("photo.png", "x")]);
    expect(result).toEqual({ files: [], refusal: strings.drop_not_a_file });
    const folder = file("Parts", "");
    Object.defineProperty(folder, "slice", {
      value: () => ({
        arrayBuffer: () =>
          Promise.reject(new DOMException("not readable", "NotReadableError")),
      }),
    });
    const folders = await filesFromDrop(fake, strings, [folder]);
    expect(folders).toEqual({
      files: [],
      refusal: strings.drop_folders_refused,
    });
    expect(staged).toEqual([]);
  });
});
