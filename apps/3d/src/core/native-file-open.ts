import { isNative } from "./files";
import { adoptNativeFiles } from "./recent-files";
interface NativeFilePayload {
  name: string;
  lastModified: number;
  bytes: Uint8Array;
  recentId: string;
}
declare global {
  interface Window {
    shenzhenFiles?: {
      takeOpen(): Promise<NativeFilePayload[][]>;
      subscribeOpen(listener: () => void): () => void;
    };
  }
}

/** Subscribe before draining so files delivered during startup cannot be missed. */
export async function subscribeNativeFiles(
  onFiles: (files: File[]) => Promise<void>,
  onError: (error: unknown) => void,
): Promise<() => void> {
  let active = true,
    running = false,
    pending = false;
  let take: () => Promise<File[][]>;
  let unsubscribe: () => void;
  const drain = async () => {
    pending = true;
    if (running || !active) return;
    running = true;
    try {
      while (active && pending) {
        pending = false;
        for (const files of await take()) {
          if (!active) break;
          if (files.length) await onFiles(files);
        }
      }
    } catch (error) {
      if (active) onError(error);
    } finally {
      running = false;
      if (active && pending) void drain();
    }
  };
  if (window.shenzhenFiles) {
    const bridge = window.shenzhenFiles;
    take = async () =>
      (await bridge.takeOpen()).map((batch) => {
        const files = batch.map(
          (file) =>
            new File([new Uint8Array(file.bytes)], file.name, {
              lastModified: file.lastModified,
            }),
        );
        if (
          batch.length &&
          batch.every((file) => file.recentId === batch[0].recentId)
        )
          adoptNativeFiles(files, batch[0].recentId);
        return files;
      });
    unsubscribe = bridge.subscribeOpen(() => void drain());
  } else if (isNative()) {
    const [{ invoke }, { listen }, { readFile }] = await Promise.all([
      import("@tauri-apps/api/core"),
      import("@tauri-apps/api/event"),
      import("@tauri-apps/plugin-fs"),
    ]);
    take = async () => {
      const batches = await invoke<string[][]>("take_native_open_files");
      return Promise.all(
        batches.map((batch) =>
          Promise.all(
            batch.map(
              async (path) =>
                new File(
                  [await readFile(path)],
                  path.split(/[\\/]/).pop() || "model",
                ),
            ),
          ),
        ),
      );
    };
    unsubscribe = await listen("native-open-files", () => void drain());
  } else return () => {};
  void drain();
  return () => {
    active = false;
    unsubscribe();
  };
}
