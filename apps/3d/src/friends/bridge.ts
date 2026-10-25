// The Friends bridge: the Electron preload's in the Mac app (electron/preload.cjs), and tauri-plugin-szfriends' in a
// Tauri build made with the `friends` feature (docs/FRIENDS.md § Tauri), the same methods either way. The web and
// PWA builds, and Tauri builds without the feature, have no `window.shenzhenFriends`, so they show nothing of
// Friends.
import type { OutgoingFile } from "./drops";
import type { BadgeData, FriendsStatus, Reply, Snapshot } from "./protocol";

export type FriendsEvent =
  | { kind: "status"; status: FriendsStatus }
  | { kind: "snapshot"; frame: Snapshot }
  | { kind: "badge"; data: BadgeData | null }
  | { kind: "link"; payload: string }
  // A notification's URL opened in the app: the dropdown on that conversation, or on the list (null).
  | { kind: "open"; conversation_id: string | null }
  // File ▸ Copy Download Link in the app's menu, chosen while this window has a model open.
  | { kind: "copy_download_link"; days: number }
  // View ▸ Friends in the app's menu: open or close the dropdown, as Cmd+J does.
  | { kind: "toggle" };

export type HelperImage = {
  type: string;
  width: number;
  height: number;
  bytes: Uint8Array;
};
export type Animal = { svg: string; color: string; name: string };
export type AnimalList = {
  set: number;
  animals: { index: number; name: string; color: string }[];
};
export type PathKind = "file" | "folder" | "other" | "missing";

export interface FriendsBridge {
  join(): Promise<FriendsStatus>;
  status(): Promise<FriendsStatus>;
  subscribe(listener: (event: FriendsEvent) => void): () => void;
  send(
    type: string,
    fields?: Record<string, unknown>,
  ): Promise<{ reply: Reply; snapshot?: Snapshot }>;
  setEnabled(enabled: boolean): Promise<FriendsStatus>;
  image(
    kind: "thumbnail" | "picture",
    path: string,
    width?: number,
    height?: number,
  ): Promise<HelperImage | null>;
  animal(set: number, index: number): Promise<Animal | null>;
  animals(): Promise<AnimalList | null>;
  /** Dropped files' paths, all or none: Electron's at once, Tauri's once the system has reported the drop. */
  pathsForFiles(
    files: ArrayLike<File>,
  ): (string | null)[] | Promise<(string | null)[]>;
  /** Phones only: the most the panel stages of one dropped file, which comes without a path there. */
  stagedDropLimit?: number;
  classify(paths: string[]): Promise<PathKind[]>;
  stage(name: string, bytes: Uint8Array): Promise<string>;
  token(): Promise<string>;
  openFile(path: string): Promise<boolean>;
  showFile(path: string): Promise<boolean>;
  /** The system's folder picker, starting at `start`; the folder chosen, or null. Electron's; Tauri builds use the
   * dialog plugin instead (chooseFolder below). */
  chooseFolder?(start?: string | null): Promise<string | null>;
  /** The system's file picker for any files, several at once (the composer's Attach files): the regular files
   * chosen, or null when cancelled. Electron's (paths), and on phones the plugin's, which copies each file for
   * sending as it reads it, never whole into memory. Tauri desktops use the dialog plugin (drops.ts chooseFiles). */
  chooseFiles?(): Promise<OutgoingFile[] | null>;
  /** Phones: files another app shared with this one through the system's share sheet, copied for sending; each
   * share is handed over once. */
  sharedFiles?(): Promise<OutgoingFile[]>;
  openSettings(target: string): Promise<boolean>;
  openURL(url: string): Promise<boolean>;
  /** Whether this window has a model open, for File ▸ Copy Download Link. */
  shareable(value: boolean): Promise<void>;
}

declare global {
  interface Window {
    shenzhenFriends?: FriendsBridge;
  }
}

export const friendsBridge = (): FriendsBridge | undefined =>
  typeof window === "undefined" ? undefined : window.shenzhenFriends;

/** A folder the person picks, starting at `start`: the bridge's picker (Electron), else Tauri's dialog plugin. */
export async function chooseFolder(
  bridge: FriendsBridge,
  start?: string | null,
): Promise<string | null> {
  if (bridge.chooseFolder) return bridge.chooseFolder(start ?? null);
  if (
    typeof window === "undefined" ||
    !(window as unknown as { __TAURI_INTERNALS__?: unknown })
      .__TAURI_INTERNALS__
  )
    return null;
  const { open } = await import("@tauri-apps/plugin-dialog");
  const folder = await open({
    directory: true,
    multiple: false,
    ...(start ? { defaultPath: start } : {}),
  });
  return typeof folder === "string" ? folder : null;
}
