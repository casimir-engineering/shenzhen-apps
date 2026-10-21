// window.shenzhenUpdates on Windows, Linux and iOS (src/core/native-updates.ts): offered only where the app marked
// the page, each action is the app_updates command, and states the app sends later reach every listener.
import { afterEach, describe, expect, it } from "vitest";
import { installNativeUpdates } from "../src/core/native-updates";
import type { UpdateState } from "../src/core/updates";

const state = (
  status: UpdateState["status"],
  extra: Partial<UpdateState> = {},
): UpdateState => ({
  supported: true,
  version: "0.2.2",
  status,
  automatic: true,
  repository: "casimir-engineering",
  access: "public",
  prereleases: true,
  connected: false,
  message: "",
  platform: "windows",
  downloadOnly: false,
  ...extra,
});

function fakeCore() {
  const calls: { command: string; args?: Record<string, unknown> }[] = [];
  const channels: { onmessage: (message: UpdateState) => void }[] = [];
  class Channel<T> {
    onmessage: (message: T) => void = () => {};
    constructor() {
      channels.push(
        this as unknown as { onmessage: (message: UpdateState) => void },
      );
    }
  }
  const invoke = async <T>(command: string, args?: Record<string, unknown>) => {
    calls.push({ command, args });
    if (command === "app_updates_subscribe") return state("idle") as T;
    const action = args?.action;
    return (action === "check" ? state("checking") : state("idle")) as T;
  };
  return { calls, channels, load: async () => ({ invoke, Channel }) };
}

const globals = globalThis as unknown as { window?: Record<string, unknown> };
afterEach(() => {
  delete globals.window;
});

describe("native updates bridge", () => {
  it("is not offered where the app did not mark the page", () => {
    globals.window = {};
    installNativeUpdates(fakeCore().load as never);
    expect(globals.window.shenzhenUpdates).toBeUndefined();
  });

  it("sends each action to app_updates and passes on what the app reports later", async () => {
    globals.window = { __SHENZHEN_NATIVE_UPDATES__: "linux" };
    const core = fakeCore();
    installNativeUpdates(core.load as never);
    const bridge = (globals.window as unknown as Window).shenzhenUpdates!;
    expect(bridge).toBeDefined();
    const seen: string[] = [];
    bridge.subscribe((s) => seen.push(s.status));
    expect((await bridge.check()).status).toBe("checking");
    await bridge.configure({ automatic: false, prereleases: false });
    await bridge.download();
    await bridge.install();
    // The app's later states arrive on the subscribed channel.
    await new Promise((resolve) => setTimeout(resolve, 0));
    core.channels[0].onmessage(
      state("available", { availableVersion: "0.2.9" }),
    );
    core.channels[0].onmessage(state("downloading", { progress: 40 }));
    expect(core.calls.map((c) => c.args?.action ?? c.command)).toEqual([
      "app_updates_subscribe",
      "check",
      "configure",
      "download",
      "install",
    ]);
    // Only "Check daily" is a setting here; the channel is fixed.
    expect(
      core.calls.find((c) => c.args?.action === "configure")?.args?.args,
    ).toEqual({ automatic: false });
    expect(seen).toContain("available");
    expect(seen.at(-1)).toBe("downloading");
    // Nothing to connect: public releases.
    expect((await bridge.connect("token")).status).toBe("downloading");
  });
});
