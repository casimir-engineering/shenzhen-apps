// window.shenzhenUpdates on Windows, Linux and iOS: the Updates dialog's bridge, answered by the app's own updater
// (src-tauri/src/app_updates.rs) through the app_updates command. The app marks the page with
// __SHENZHEN_NATIVE_UPDATES__ before it loads, so the footer can offer Updates from the first render. Each call
// answers with the state at once; checks and downloads report on a channel as they go.
import type { UpdateBridge, UpdateState } from "./updates";

type Invoke = <T>(
  command: string,
  args?: Record<string, unknown>,
) => Promise<T>;

export function nativeUpdatesPlatform(): string | undefined {
  const marked = (
    window as unknown as { __SHENZHEN_NATIVE_UPDATES__?: unknown }
  ).__SHENZHEN_NATIVE_UPDATES__;
  return typeof marked === "string" ? marked : undefined;
}

export function installNativeUpdates(
  load: () => Promise<{
    invoke: Invoke;
    Channel: new <T>() => { onmessage: (message: T) => void };
  }> = () =>
    import("@tauri-apps/api/core") as unknown as ReturnType<typeof load>,
) {
  if (window.shenzhenUpdates || !nativeUpdatesPlatform()) return;
  const listeners = new Set<(state: UpdateState) => void>();
  let latest: UpdateState | undefined;
  const publish = (state: UpdateState) => {
    latest = state;
    for (const listener of listeners) listener(state);
    return state;
  };
  let core: ReturnType<typeof load> | undefined;
  const api = () => (core ??= load());
  const call = async (action: string, args?: Record<string, unknown>) => {
    const { invoke } = await api();
    return publish(
      await invoke<UpdateState>("app_updates", { action, args: args ?? null }),
    );
  };
  let subscribed: Promise<void> | undefined;
  const subscribe = () =>
    (subscribed ??= api().then(async ({ Channel, invoke }) => {
      const channel = new Channel<UpdateState>();
      channel.onmessage = publish;
      publish(await invoke<UpdateState>("app_updates_subscribe", { channel }));
    }));
  const current = async (): Promise<UpdateState> => latest ?? call("getState");
  const bridge: UpdateBridge = {
    getState: () => call("getState"),
    check: () => call("check"),
    download: () => call("download"),
    install: () => call("install"),
    configure: (value) => call("configure", { automatic: value.automatic }),
    // Public releases: nothing to connect.
    connect: current,
    disconnect: current,
    useGitHubCLI: current,
    subscribe(listener) {
      listeners.add(listener);
      void subscribe().catch(() => {
        subscribed = undefined;
      });
      if (latest) listener(latest);
      return () => {
        listeners.delete(listener);
      };
    },
  };
  window.shenzhenUpdates = bridge;
}
