// window.shenzhenUpdates on Android: the Updates dialog's bridge, answered by the app's UpdatePlugin
// (src-tauri/gen/android/…/UpdatePlugin.kt) through the android_updates command. Each call answers with the state at
// once; checks, downloads and installs report on a channel as they go.
import type { UpdateBridge, UpdateState } from "./updates";

type Invoke = <T>(
  command: string,
  args?: Record<string, unknown>,
) => Promise<T>;

function isTauriAndroid() {
  return (
    Boolean(
      (window as unknown as { __TAURI_INTERNALS__?: unknown })
        .__TAURI_INTERNALS__,
    ) && /Android/i.test(navigator.userAgent)
  );
}

export function installAndroidUpdates() {
  if (window.shenzhenUpdates || !isTauriAndroid()) return;
  const listeners = new Set<(state: UpdateState) => void>();
  let latest: UpdateState | undefined;
  const publish = (state: UpdateState) => {
    latest = state;
    for (const listener of listeners) listener(state);
    return state;
  };
  let core: Promise<typeof import("@tauri-apps/api/core")> | undefined;
  const api = () => (core ??= import("@tauri-apps/api/core"));
  const call = async (action: string, args?: Record<string, unknown>) => {
    const { invoke } = await api();
    return publish(
      await (invoke as Invoke)<UpdateState>("android_updates", {
        action,
        args: args ?? null,
      }),
    );
  };
  let subscribed: Promise<void> | undefined;
  const subscribe = () =>
    (subscribed ??= api().then(async ({ Channel, invoke }) => {
      const channel = new Channel<UpdateState>();
      channel.onmessage = publish;
      publish(
        await (invoke as Invoke)<UpdateState>("android_updates_subscribe", {
          channel,
        }),
      );
    }));
  const unsupported = async (): Promise<UpdateState> =>
    latest ?? call("getState");
  const bridge: UpdateBridge = {
    getState: () => call("getState"),
    check: () => call("check"),
    download: () => call("download"),
    install: () => call("install"),
    configure: (value) => call("configure", { automatic: value.automatic }),
    // Public releases: nothing to connect.
    connect: unsupported,
    disconnect: unsupported,
    useGitHubCLI: unsupported,
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
