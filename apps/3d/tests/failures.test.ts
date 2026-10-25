import { afterEach, describe, expect, it, vi } from "vitest";
import { isForPeople, shownFailure } from "../src/core/failures";

describe("what a failure shows", () => {
  afterEach(() => vi.restoreAllMocks());

  it("never shows a native refusal; logs it and shows the plain sentence", () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    // What Tauri rejects with when it refuses a call: a plain string.
    const refusal = "Command plugin:event|listen not allowed by ACL";
    const shown = shownFailure(
      "waiting for files",
      refusal,
      "Files couldn’t be opened. Try again.",
    );
    expect(shown).toBe("Files couldn’t be opened. Try again.");
    expect(shown).not.toMatch(/plugin:|ACL|Command/);
    expect(log).toHaveBeenCalledWith(
      "[Shenzhen 3D] waiting for files:",
      refusal,
    );
  });

  it("replaces the browser's own errors", () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    for (const failure of [
      new TypeError("Failed to fetch"),
      new DOMException("The object can not be found here.", "NotFoundError"),
      { code: 3 },
      undefined,
    ])
      expect(shownFailure("save", failure, "Couldn’t save.")).toBe(
        "Couldn’t save.",
      );
  });

  it("keeps the app's own messages, written for the person", () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    class ImportFailure extends Error {}
    expect(
      shownFailure("open", new Error("This file has no geometry."), "x"),
    ).toBe("This file has no geometry.");
    expect(isForPeople(new ImportFailure("Unsupported file."))).toBe(true);
    expect(log).not.toHaveBeenCalled();
  });
});
