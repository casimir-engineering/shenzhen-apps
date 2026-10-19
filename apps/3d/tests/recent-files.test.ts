import { afterEach, describe, expect, it, vi } from "vitest";
import { adoptNativeFiles, rememberRecent } from "../src/core/recent-files";
afterEach(() => vi.unstubAllGlobals());
describe("native recent File grant adoption", () => {
  it("touches an adopted complete batch without copying large native files into IndexedDB", async () => {
    const files = [
      new File(["model"], "part.step"),
      new File(["companion"], "paint.mtl"),
    ];
    Object.defineProperty(files[0], "size", { value: 512 * 1024 ** 2 });
    const id = "12345678-1234-1234-1234-123456789abc";
    const entry = { id, name: "part.step", format: "step", storage: "native" };
    const touch = vi.fn(async () => entry),
      remember = vi.fn();
    vi.stubGlobal("window", { shenzhenRecentFiles: { touch, remember } });
    adoptNativeFiles(files, id);
    expect(await rememberRecent([...files], "part.step", "step")).toBe(entry);
    expect(touch).toHaveBeenCalledWith(id);
    expect(remember).not.toHaveBeenCalled();
  });
  it("does not reuse a native grant for a subset, reordered batch or different File object", async () => {
    const files = [
      new File(["model"], "part.obj"),
      new File(["paint"], "paint.mtl"),
    ];
    const touch = vi.fn(),
      remember = vi.fn(async () => {
        throw Error("not a granted batch");
      });
    vi.stubGlobal("window", { shenzhenRecentFiles: { touch, remember } });
    adoptNativeFiles(files, "12345678-1234-1234-1234-123456789abc");
    for (const batch of [
      [files[0]],
      [...files].reverse(),
      [new File(["model"], "part.obj"), files[1]],
    ])
      await expect(rememberRecent(batch, "part.obj", "obj")).rejects.toThrow(
        "not a granted batch",
      );
    expect(touch).not.toHaveBeenCalled();
  });
});
