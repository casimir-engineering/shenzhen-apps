import { afterEach, describe, expect, it, vi } from "vitest";
vi.mock("../src/core/files", () => ({ isNative: () => false }));
vi.mock("../src/core/recent-files", () => ({ adoptNativeFiles: vi.fn() }));
import { subscribeNativeFiles } from "../src/core/native-file-open";
import { adoptNativeFiles } from "../src/core/recent-files";
const payload = (name: string) => ({
  name,
  lastModified: 1234,
  bytes: new TextEncoder().encode(name),
  recentId: "grant",
});
afterEach(() => {
  vi.unstubAllGlobals();
  vi.clearAllMocks();
});
describe("native file delivery", () => {
  it("subscribes before draining cold-start files and retains the native grant", async () => {
    const order: string[] = [];
    const stop = vi.fn();
    vi.stubGlobal("window", {
      shenzhenFiles: {
        subscribeOpen: () => {
          order.push("subscribe");
          return stop;
        },
        takeOpen: async () => {
          order.push("take");
          return [[payload("model.step")]];
        },
      },
    });
    const opened: File[][] = [];
    const unsubscribe = await subscribeNativeFiles(async (files) => {
      opened.push(files);
    }, vi.fn());
    await vi.waitFor(() => expect(opened).toHaveLength(1));
    expect(order).toEqual(["subscribe", "take"]);
    expect(opened[0][0].name).toBe("model.step");
    expect(await opened[0][0].text()).toBe("model.step");
    expect(adoptNativeFiles).toHaveBeenCalledWith(opened[0], "grant");
    unsubscribe();
    expect(stop).toHaveBeenCalledOnce();
  });
  it("serializes deliveries that arrive during import without losing a batch", async () => {
    let signal = () => {};
    let release = () => {};
    let calls = 0;
    const opened: string[] = [];
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    vi.stubGlobal("window", {
      shenzhenFiles: {
        subscribeOpen: (listener: () => void) => {
          signal = listener;
          return () => {};
        },
        takeOpen: async () => [
          [payload(++calls === 1 ? "first.step" : "second.dxf")],
        ],
      },
    });
    const stop = await subscribeNativeFiles(async (files) => {
      opened.push(files[0].name);
      if (opened.length === 1) await gate;
    }, vi.fn());
    await vi.waitFor(() => expect(opened).toEqual(["first.step"]));
    signal();
    signal();
    expect(calls).toBe(1);
    release();
    await vi.waitFor(() =>
      expect(opened).toEqual(["first.step", "second.dxf"]),
    );
    expect(calls).toBe(2);
    stop();
  });
  it("reports a missing native file without opening a generic picker", async () => {
    const failure = Error("File moved");
    const onFiles = vi.fn(),
      onError = vi.fn();
    vi.stubGlobal("window", {
      shenzhenFiles: {
        subscribeOpen: () => () => {},
        takeOpen: async () => {
          throw failure;
        },
      },
    });
    const stop = await subscribeNativeFiles(onFiles, onError);
    await vi.waitFor(() => expect(onError).toHaveBeenCalledWith(failure));
    expect(onFiles).not.toHaveBeenCalled();
    stop();
  });
});
