// Files dropped on Friends: only regular files go (the helper sends nothing else), so folders and links or special
// files are refused with the helper's own words before any intent (PROTOCOL.md § Static strings). Desktops send
// each file from its path (Electron's, or the one Tauri's system reported); phones stage the bytes of what fits.
import type { FriendsBridge } from "./bridge";
import type { Strings } from "./protocol";

export type OutgoingFile = { path: string; display_name: string };
export type DropResult =
  | { files: OutgoingFile[]; refusal: null }
  | { files: []; refusal: string | null };

/** A `#` item that could not be attached, with the sentence the composer shows in its place. */
export class AttachRefused extends Error {}

/** Whether a drag carries files at all; their kinds are known only once dropped. */
export const dragHasFiles = (transfer: DataTransfer | null) =>
  Boolean(transfer && Array.from(transfer.types ?? []).includes("Files"));

export async function filesFromDrop(
  bridge: FriendsBridge,
  strings: Strings,
  files: ArrayLike<File>,
): Promise<DropResult> {
  const list = Array.from(files);
  if (!list.length) return { files: [], refusal: null };
  const paths = await bridge.pathsForFiles(list);
  if (paths.some((path) => !path)) {
    const limit = bridge.stagedDropLimit;
    // A desktop sends files from where they are, so a drop the system names no file for (a folder, or something
    // dragged out of another app) is refused in the helper's words.
    if (!limit) {
      const folder = await someFolder(
        list.filter((_file, index) => !paths[index]),
      );
      return {
        files: [],
        refusal:
          (folder ? strings.drop_folders_refused : strings.drop_not_a_file) ??
          null,
      };
    }
    // A phone gives no paths: the files' bytes go instead, as a private copy the app keeps for sending, read only
    // when each fits.
    const large = list.find((file) => file.size > limit);
    if (large)
      return { files: [], refusal: tooLargeToStage(large.name, limit) };
    const staged = await stageFiles(bridge, list);
    if (Array.isArray(staged)) return { files: staged, refusal: null };
    return {
      files: [],
      refusal:
        (staged === "folder"
          ? strings.drop_folders_refused
          : strings.drop_not_a_file) ?? null,
    };
  }
  const kinds = await bridge.classify(paths as string[]);
  if (kinds.includes("folder"))
    return { files: [], refusal: strings.drop_folders_refused ?? null };
  if (kinds.some((kind) => kind !== "file"))
    return { files: [], refusal: strings.drop_not_a_file ?? null };
  return {
    files: list.map((file, index) => ({
      path: paths[index]!,
      display_name: file.name,
    })),
    refusal: null,
  };
}

/** Shown on a phone when a dropped file is larger than the app can stage. */
export const tooLargeToStage = (name: string, limit: number) =>
  `${name} is too large to send from this device. Files you drop here can be up to ${Math.floor(limit / 1e6)} MB.`;

/** A dropped folder reaches the page as an empty, typeless entry that cannot be read; reading one byte tells. */
async function someFolder(files: File[]): Promise<boolean> {
  for (const file of files) {
    if (file.size > 0 || file.type) continue;
    try {
      await file.slice(0, 1).arrayBuffer();
    } catch {
      return true;
    }
  }
  return false;
}

/** Each file's bytes as a private copy the app keeps for sending (phones' drops, and `#` items without a path). */
export async function stageFiles(
  bridge: Pick<FriendsBridge, "stage">,
  files: File[],
): Promise<OutgoingFile[] | "folder" | "other"> {
  const staged: OutgoingFile[] = [];
  for (const file of files) {
    let bytes: Uint8Array;
    try {
      bytes = new Uint8Array(await file.arrayBuffer());
    } catch {
      // A dropped folder reaches the page as an empty, typeless entry that cannot be read.
      return file.size === 0 && !file.type ? "folder" : "other";
    }
    try {
      staged.push({
        path: await bridge.stage(file.name, bytes),
        display_name: file.name,
      });
    } catch {
      return "other";
    }
  }
  return staged;
}

/** send_files to one conversation with a fresh client token (one per press, PROTOCOL.md § Intents). */
export async function sendFiles(
  bridge: FriendsBridge,
  conversationId: string,
  files: OutgoingFile[],
) {
  const token = await bridge.token();
  return (
    await bridge.send("send_files", {
      conversation_id: conversationId,
      files,
      client_token: token,
    })
  ).reply;
}
